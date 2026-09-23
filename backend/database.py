"""Camada de acesso ao Supabase (service_role — ignora RLS)."""
from typing import Optional, List, Dict, Any, Tuple
from datetime import datetime, timezone
from supabase import create_client, Client

from config import (
    SUPABASE_URL, SUPABASE_SERVICE_KEY, BUCKET_CURRICULOS,
    MODO_SIMULACAO, log,
)

_cliente: Optional[Client] = None


def conectar() -> Client:
    global _cliente
    if _cliente is None:
        _cliente = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)
        log.info("Conectado ao Supabase")
    return _cliente


def agora() -> str:
    return datetime.now(timezone.utc).isoformat()


# ─────────────────────────────────────────────
# CONFIGURAÇÕES
# ─────────────────────────────────────────────
def carregar_configuracoes() -> Dict[str, Any]:
    r = conectar().table("configuracoes").select("chave,valor").execute()
    return {c["chave"]: c["valor"] for c in r.data}


# Marcador de progresso da caixa de e-mail. E-mails de outros setores continuam
# não lidos; o marcador impede que o pipeline os releia a cada execução.
CHAVE_CURSOR_UID = "imap_ultimo_uid"
CHAVE_CURSOR_VALIDADE = "imap_uidvalidity"


def obter_cursor_imap() -> Tuple[int, int]:
    """(último UID já analisado, UIDVALIDITY da caixa). (0, 0) se ainda não existe."""
    r = conectar().table("configuracoes").select("chave,valor")\
        .in_("chave", [CHAVE_CURSOR_UID, CHAVE_CURSOR_VALIDADE]).execute()
    v = {c["chave"]: c["valor"] for c in r.data}
    return int(v.get(CHAVE_CURSOR_UID) or 0), int(v.get(CHAVE_CURSOR_VALIDADE) or 0)


def salvar_cursor_imap(ultimo_uid: int, uidvalidity: int) -> None:
    if MODO_SIMULACAO:
        return
    db = conectar()
    for chave, valor, descricao in (
        (CHAVE_CURSOR_UID, ultimo_uid,
         "Controle interno: último UID da caixa já analisado pelo pipeline. Não editar."),
        (CHAVE_CURSOR_VALIDADE, uidvalidity,
         "Controle interno: UIDVALIDITY da caixa de e-mail. Não editar."),
    ):
        if db.table("configuracoes").select("chave").eq("chave", chave).execute().data:
            db.table("configuracoes").update({"valor": valor}).eq("chave", chave).execute()
        else:
            db.table("configuracoes").insert(
                {"chave": chave, "valor": valor, "descricao": descricao}).execute()


# ─────────────────────────────────────────────
# VAGAS
# ─────────────────────────────────────────────
def listar_vagas_abertas() -> List[Dict]:
    """Vagas ativas com seus requisitos, para o classificador e o avaliador."""
    db = conectar()
    vagas = db.table("vagas").select(
        "id,titulo,descricao,perfil_comportamental,versao_criterios,"
        "setor_id,setores(nome)"
    ).eq("status", "ativo").execute().data

    if not vagas:
        return []

    ids = [v["id"] for v in vagas]
    reqs = db.table("requisitos").select("*").in_("vaga_id", ids)\
             .order("ordem").execute().data

    por_vaga: Dict[str, List[Dict]] = {}
    for r in reqs:
        por_vaga.setdefault(r["vaga_id"], []).append(r)

    for v in vagas:
        todos = por_vaga.get(v["id"], [])
        v["obrigatorios"] = [r for r in todos if r["tipo"] == "obrigatorio"]
        v["desejaveis"]   = [r for r in todos if r["tipo"] == "desejavel"]
        v["setor_nome"]   = (v.get("setores") or {}).get("nome", "")
    return vagas


# ─────────────────────────────────────────────
# REMETENTES
# ─────────────────────────────────────────────
def obter_ou_criar_remetente(email: str) -> Dict:
    db = conectar()
    r = db.table("remetentes").select("*").eq("email", email).execute()
    if r.data:
        return r.data[0]
    if MODO_SIMULACAO:
        return {"id": "simulado", "email": email, "bloqueado": False, "total_envios": 0}
    novo = db.table("remetentes").insert({"email": email}).execute()
    return novo.data[0]


def remetente_bloqueado(email: str) -> bool:
    r = conectar().table("remetentes").select("bloqueado")\
        .eq("email", email).execute()
    return bool(r.data and r.data[0]["bloqueado"])


# ─────────────────────────────────────────────
# IDEMPOTÊNCIA
# ─────────────────────────────────────────────
def candidatura_existe_para_mensagem(message_id: str) -> bool:
    """Só candidaturas — diferente de email_ja_processado(), que também conta exceção
    (por isso não serve aqui: a exceção que estamos reprocessando sempre existe)."""
    if not message_id:
        return False
    return bool(conectar().table("candidaturas").select("id")
                  .eq("email_message_id", message_id).limit(1).execute().data)


def email_ja_processado(message_id: str) -> bool:
    """Evita reprocessar o mesmo e-mail em execuções futuras."""
    if not message_id:
        return False
    db = conectar()
    if db.table("candidaturas").select("id")\
         .eq("email_message_id", message_id).limit(1).execute().data:
        return True
    return bool(db.table("excecoes").select("id")
                  .eq("email_message_id", message_id).limit(1).execute().data)


def buscar_duplicata(hash_identidade: str, vaga_id: str,
                     dias_carencia: int = 90) -> Optional[Dict]:
    """Mesma pessoa, mesma vaga, dentro do prazo de carência."""
    if not hash_identidade or not vaga_id:
        return None
    from datetime import timedelta
    limite = (datetime.now(timezone.utc) - timedelta(days=dias_carencia)).isoformat()
    r = conectar().table("candidaturas").select("id,recebido_em,status")\
        .eq("hash_identidade", hash_identidade)\
        .eq("vaga_id", vaga_id)\
        .gte("recebido_em", limite)\
        .limit(1).execute()
    return r.data[0] if r.data else None


# ─────────────────────────────────────────────
# CANDIDATURAS
# ─────────────────────────────────────────────
def criar_candidatura(dados: Dict) -> Optional[Dict]:
    if MODO_SIMULACAO:
        log.info("  [simulação] candidatura não gravada")
        return {"id": "simulado"}
    r = conectar().table("candidaturas").insert(dados).execute()
    return r.data[0] if r.data else None


def salvar_curriculo(dados: Dict) -> Optional[Dict]:
    if MODO_SIMULACAO:
        return {"id": "simulado"}
    r = conectar().table("curriculos").insert(dados).execute()
    return r.data[0] if r.data else None


def salvar_avaliacao(dados: Dict) -> Optional[Dict]:
    if MODO_SIMULACAO:
        return {"id": "simulado"}
    r = conectar().table("avaliacoes").insert(dados).execute()
    return r.data[0] if r.data else None


def atualizar_candidatura(cand_id: str, dados: Dict) -> None:
    if MODO_SIMULACAO:
        return
    conectar().table("candidaturas").update(dados).eq("id", cand_id).execute()


def listar_sem_perfil(limite: int = 0) -> List[Dict]:
    """
    Candidaturas ativas cujo perfil de busca (idade, escolaridade, experiência, CNH)
    ainda não foi extraído: as que chegaram antes dos filtros avançados.
    """
    q = conectar().table("candidaturas").select("id,dados_pessoais")\
        .eq("status_registro", "ativo").is_("dados_pessoais->>perfil_v", "null")\
        .order("recebido_em")
    if limite:
        q = q.limit(limite)
    return q.execute().data or []


# ─────────────────────────────────────────────
# REAVALIAÇÃO (o RH trocou a vaga no painel)
# ─────────────────────────────────────────────
def listar_reavaliacoes() -> List[Dict]:
    """Candidaturas que o painel deixou em análise: a IA ainda vai (re)avaliar."""
    return conectar().table("candidaturas").select("id,vaga_id,dados_pessoais")\
        .eq("status", "em_analise").order("updated_at").execute().data or []


def obter_texto_curriculo(cand_id: str) -> Optional[str]:
    """Texto extraído do currículo; None se não houver (ex.: dados já expurgados)."""
    r = conectar().table("curriculos").select("texto_extraido")\
        .eq("candidatura_id", cand_id).limit(1).execute().data
    return (r[0].get("texto_extraido") or None) if r else None


def proxima_sequencia(cand_id: str) -> int:
    """
    Sequência da próxima avaliação da candidatura, acima de todas as anteriores:
    assim a mais nova é a que o painel mostra e o histórico continua guardado.
    """
    r = conectar().table("avaliacoes").select("sequencia")\
        .eq("candidatura_id", cand_id).order("sequencia", desc=True).limit(1).execute().data
    return r[0]["sequencia"] + 1 if r else 1


# ─────────────────────────────────────────────
# EXCEÇÕES
# ─────────────────────────────────────────────
def registrar_excecao(dados: Dict) -> None:
    if MODO_SIMULACAO:
        log.info(f"  [simulação] exceção: {dados.get('tipo')}")
        return
    conectar().table("excecoes").insert(dados).execute()


def atualizar_excecao(excecao_id: str, dados: Dict) -> None:
    if MODO_SIMULACAO:
        log.info(f"  [simulação] atualizaria exceção {excecao_id[:8]}: {dados.get('tipo') or dados}")
        return
    conectar().table("excecoes").update(dados).eq("id", excecao_id).execute()


def listar_excecoes_para_reprocessar() -> List[Dict]:
    """Exceções que o RH marcou para tentar de novo no painel (fila de exceções)."""
    return conectar().table("excecoes").select("id,email_remetente,email_message_id")\
        .not_.is_("reprocessar_solicitado_em", "null")\
        .order("reprocessar_solicitado_em").execute().data or []


# ─────────────────────────────────────────────
# UPLOADS MANUAIS (currículo enviado direto no painel, sem e-mail)
# ─────────────────────────────────────────────
def listar_uploads_manuais_pendentes() -> List[Dict]:
    """Currículos que o RH enviou pelo painel (botão "Enviar currículo"), ainda não processados."""
    return conectar().table("uploads_manuais").select("*")\
        .eq("status", "pendente").order("enviado_em").execute().data or []


def atualizar_upload_manual(upload_id: str, dados: Dict) -> None:
    if MODO_SIMULACAO:
        log.info(f"  [simulação] atualizaria upload manual {upload_id[:8]}: {dados.get('status') or dados}")
        return
    conectar().table("uploads_manuais").update(dados).eq("id", upload_id).execute()


def obter_upload_manual(upload_id: str) -> Optional[Dict]:
    r = conectar().table("uploads_manuais").select("*").eq("id", upload_id).limit(1).execute()
    return r.data[0] if r.data else None


def usuario_ativo(usuario_id: str) -> bool:
    """Mesma regra da política de banco fn_usuario_ativo() — usada pelo servidor HTTP (api.py)."""
    r = conectar().table("usuarios").select("ativo").eq("id", usuario_id).limit(1).execute()
    return bool(r.data and r.data[0]["ativo"])


# ─────────────────────────────────────────────
# STORAGE
# ─────────────────────────────────────────────
def enviar_arquivo(caminho: str, conteudo: bytes, tipo_mime: str) -> Optional[str]:
    if MODO_SIMULACAO:
        return caminho
    try:
        conectar().storage.from_(BUCKET_CURRICULOS).upload(
            caminho, conteudo,
            {"content-type": tipo_mime, "upsert": "false"},
        )
        return caminho
    except Exception as e:
        log.error(f"  Falha ao enviar arquivo: {e}")
        return None


def baixar_arquivo(caminho: str) -> Optional[bytes]:
    if MODO_SIMULACAO:
        return None
    try:
        return conectar().storage.from_(BUCKET_CURRICULOS).download(caminho)
    except Exception as e:
        log.error(f"  Falha ao baixar arquivo do Storage: {e}")
        return None


def remover_arquivos(caminhos: List[str]) -> None:
    """Usado pelo expurgo LGPD."""
    if not caminhos or MODO_SIMULACAO:
        return
    try:
        conectar().storage.from_(BUCKET_CURRICULOS).remove(caminhos)
        log.info(f"  {len(caminhos)} arquivo(s) removido(s) do Storage")
    except Exception as e:
        log.error(f"  Falha ao remover arquivos: {e}")


# ─────────────────────────────────────────────
# EXECUÇÕES DO PIPELINE
# ─────────────────────────────────────────────
def iniciar_execucao() -> Optional[str]:
    if MODO_SIMULACAO:
        return None
    r = conectar().table("execucoes_pipeline").insert({}).execute()
    return r.data[0]["id"] if r.data else None


def finalizar_execucao(exec_id: Optional[str], stats: Dict,
                       sucesso: bool = True, erro: str = None) -> None:
    if not exec_id or MODO_SIMULACAO:
        return
    conectar().table("execucoes_pipeline").update({
        "finalizado_em": agora(),
        "sucesso": sucesso,
        "erro_mensagem": erro,
        **stats,
    }).eq("id", exec_id).execute()


# ─────────────────────────────────────────────
# MANUTENÇÃO (retenção e expurgo)
# ─────────────────────────────────────────────
def executar_manutencao() -> Dict:
    """Chama a rotina do banco e remove os arquivos expurgados."""
    if MODO_SIMULACAO:
        return {"inativadas": 0, "expurgadas": 0}
    r = conectar().rpc("fn_manutencao_diaria").execute()
    resultado = r.data or {}
    arquivos = resultado.get("arquivos_para_remover") or []
    if arquivos:
        remover_arquivos(arquivos)
    return resultado
