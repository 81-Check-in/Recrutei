"""
Servidor HTTP — pedidos imediatos do painel que precisam da IA: envio manual de currículo, "Reanalisar" e o
assistente que escreve o rascunho de uma vaga.

Roda como um SEGUNDO serviço no Railway (Custom Start Command
"uvicorn api:app --host 0.0.0.0 --port $PORT"), separado do worker que lê e-mail
(Procfile "worker: python main.py", que continua rodando pelo Cron Schedule).
Ver backend/README.md — "Enviar currículo manualmente".

Não existe segredo fixo embutido no painel: cada chamada leva o token de sessão
do usuário do RH já logado (o mesmo do supabase-js), e este servidor confirma
com o próprio Supabase Auth que a sessão é válida e que o usuário está ativo —
igual à política de banco fn_usuario_ativo() que protege as tabelas.
"""
import time
from collections import defaultdict, deque
from typing import Optional

import requests
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

import database as bd
import ia
import pipeline
from config import (
    SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, CORS_ORIGENS, MODELO_AVALIACAO_PADRAO, log,
)

app = FastAPI(title="Recrutei — API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGENS or ["*"],
    allow_methods=["POST"],
    allow_headers=["Authorization", "Content-Type"],
)


def _usuario_autenticado(authorization: Optional[str]) -> str:
    """Valida o token contra o Supabase Auth e confirma que o usuário está ativo.
    Levanta HTTPException se não. Retorna o id do usuário."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Sem token de autenticação")
    token = authorization.split(" ", 1)[1].strip()

    try:
        r = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers={"Authorization": f"Bearer {token}", "apikey": SUPABASE_PUBLISHABLE_KEY},
            timeout=10,
        )
    except requests.RequestException as e:
        raise HTTPException(502, f"Falha ao validar sessão: {e}")

    if r.status_code != 200:
        raise HTTPException(401, "Sessão inválida ou expirada")

    usuario_id = (r.json() or {}).get("id")
    if not usuario_id or not bd.usuario_ativo(usuario_id):
        raise HTTPException(403, "Usuário inativo")
    return usuario_id


@app.post("/uploads-manuais/{upload_id}/avaliar")
def avaliar_upload(upload_id: str, authorization: Optional[str] = Header(None)):
    usuario_id = _usuario_autenticado(authorization)

    item = bd.obter_upload_manual(upload_id)
    if not item:
        raise HTTPException(404, "Upload não encontrado")

    # Já processado (ex.: o pipeline agendado pegou primeiro) — só devolve o resultado.
    if item["status"] != "pendente":
        return _resposta_upload(item)

    log.info(f"► avaliação imediata — upload {upload_id[:8]} (pedida por usuário {usuario_id[:8]})")
    cfg = bd.carregar_configuracoes()
    stats = pipeline.Estatisticas()
    pipeline.processar_upload_manual(item, cfg, bd.listar_areas(), stats)

    return _resposta_upload(bd.obter_upload_manual(upload_id))


def _resposta_upload(item: dict) -> dict:
    """Resultado do upload + a análise da IA do candidato gerado (área/cargo/nível), para o painel mostrar."""
    candidato = bd.obter_candidato(item["candidato_gerado_id"]) if item.get("candidato_gerado_id") else None
    return {
        "status": item["status"],
        "detalhe_erro": item.get("detalhe_erro"),
        "candidato_gerado_id": item.get("candidato_gerado_id"),
        "candidatura_gerada_id": item.get("candidatura_gerada_id"),
        "nome": (candidato or {}).get("nome"),
    }


@app.post("/candidatos/{candidato_id}/analisar")
def analisar_candidato(candidato_id: str, authorization: Optional[str] = Header(None)):
    """Botão "Reanalisar" do Banco de Talentos: refaz a análise da IA na hora, sem esperar a rotina."""
    usuario_id = _usuario_autenticado(authorization)

    candidato = bd.obter_candidato(candidato_id)
    if not candidato or candidato["status_banco"] == "expurgado":
        raise HTTPException(404, "Candidato não encontrado")

    log.info(f"► reanálise imediata — candidato {candidato_id[:8]} (pedida por usuário {usuario_id[:8]})")
    stats = pipeline.Estatisticas()
    analise = pipeline.reanalisar_candidato(candidato, bd.carregar_configuracoes(), bd.listar_areas(), stats)
    if not analise:
        raise HTTPException(422, "Não foi possível analisar o currículo agora (a rotina tenta de novo)")
    return {
        "area_sugerida": analise["area_sugerida"],
        "cargo_sugerido": analise["cargo_sugerido"],
        "nivel_sugerido": analise["nivel_sugerido"],
        "confianca": analise["confianca"],
        "revisao_manual": analise["revisao_manual"],
    }


# ── Rascunho de vaga por IA ──
# Cada pedido custa uma chamada ao modelo: o limite por usuário evita que um laço no navegador (ou uso indevido de uma
# sessão) gaste à toa. Fica na memória do serviço — simples e suficiente para poucos usuários de RH.
RASCUNHOS_POR_HORA = 20
_rascunhos_recentes: dict = defaultdict(deque)      # id do usuário → instantes (segundos) dos pedidos da última hora


def _dentro_do_limite(usuario_id: str, agora: Optional[float] = None) -> bool:
    agora = time.time() if agora is None else agora
    fila = _rascunhos_recentes[usuario_id]
    while fila and agora - fila[0] > 3600:
        fila.popleft()
    if len(fila) >= RASCUNHOS_POR_HORA:
        return False
    fila.append(agora)
    return True


class PedidoRascunho(BaseModel):
    pedido: str = Field(min_length=10, max_length=1500)
    titulo: Optional[str] = Field(default=None, max_length=120)
    setor: Optional[str] = Field(default=None, max_length=80)


@app.post("/vagas/rascunho")
def rascunho_de_vaga(corpo: PedidoRascunho, authorization: Optional[str] = Header(None)):
    """
    Formulário de vaga: o RH descreve o que quer e a IA devolve descrição, perfil comportamental e requisitos
    (Obrigatório / Desejável / Diferencial). É só um rascunho para o RH revisar; nada é gravado aqui.
    """
    usuario_id = _usuario_autenticado(authorization)
    if not _dentro_do_limite(usuario_id):
        raise HTTPException(429, "Muitos pedidos seguidos. Tente de novo em alguns minutos")

    log.info(f"► rascunho de vaga por IA (pedido do usuário {usuario_id[:8]})")   # o texto do pedido não vai para o log
    modelo = pipeline.modelo_configurado(bd.carregar_configuracoes(), "modelo_ia_avaliacao", MODELO_AVALIACAO_PADRAO)
    try:
        rascunho, _ = ia.rascunhar_vaga(corpo.pedido, modelo, corpo.titulo, corpo.setor)
    except Exception as e:
        log.error(f"  Falha ao gerar o rascunho da vaga: {type(e).__name__}")
        raise HTTPException(502, "A IA não respondeu agora. Tente de novo em instantes")
    if not rascunho:
        raise HTTPException(422, "A IA não conseguiu montar a vaga com esse texto. Descreva com mais detalhes")
    return rascunho


@app.get("/saude")
def saude():
    return {"ok": True}
