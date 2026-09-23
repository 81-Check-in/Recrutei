"""
Servidor HTTP — só a rota de avaliação imediata do currículo enviado manualmente.

Roda como um SEGUNDO serviço no Railway (Custom Start Command
"uvicorn api:app --host 0.0.0.0 --port $PORT"), separado do worker que lê e-mail
(Procfile "worker: python main.py", que continua rodando pelo Cron Schedule).
Ver backend/README.md — "Enviar currículo manualmente".

Não existe segredo fixo embutido no painel: cada chamada leva o token de sessão
do usuário do RH já logado (o mesmo do supabase-js), e este servidor confirma
com o próprio Supabase Auth que a sessão é válida e que o usuário está ativo —
igual à política de banco fn_usuario_ativo() que protege as tabelas.
"""
from typing import Optional

import requests
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware

import database as bd
import pipeline
from config import SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, CORS_ORIGENS, log

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
        return {
            "status": item["status"],
            "detalhe_erro": item.get("detalhe_erro"),
            "candidatura_gerada_id": item.get("candidatura_gerada_id"),
        }

    log.info(f"► avaliação imediata — upload {upload_id[:8]} (pedida por usuário {usuario_id[:8]})")
    cfg = bd.carregar_configuracoes()
    vagas = bd.listar_vagas_abertas()
    stats = pipeline.Estatisticas()
    pipeline.processar_upload_manual(item, vagas, cfg, stats)

    atualizado = bd.obter_upload_manual(upload_id)
    return {
        "status": atualizado["status"],
        "detalhe_erro": atualizado.get("detalhe_erro"),
        "candidatura_gerada_id": atualizado.get("candidatura_gerada_id"),
    }


@app.get("/saude")
def saude():
    return {"ok": True}
