"""Camada de acesso ao Supabase (service_role — ignora RLS)."""
from typing import Optional, List, Dict, Any, Tuple
from datetime import datetime, timezone
from supabase import create_client, Client

from config import (
    SUPABASE_URL, SUPABASE_SERVICE_KEY, BUCKET_CURRICULOS,
    MODO_SIMULACAO, log,
)
from utils import normalizar_texto

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
        v["diferenciais"] = [r for r in todos if r["tipo"] == "diferencial"]
        v["setor_nome"]   = (v.get("setores") or {}).get("nome", "")
    return vagas


def listar_areas() -> List[str]:
    """Nomes dos setores ativos: o vocabulário de "área" da análise da IA (Logística, Vendas…)."""
    r = conectar().table("setores").select("nome").eq("ativo", True).order("ordem").execute()
    return [x["nome"] for x in (r.data or [])]


_vocabulario_cache: Dict = {"quando": 0.0, "dados": None}


def carregar_vocabulario_qualificacao() -> Dict:
    """
    Valores que a IA pode escolher ao qualificar um currículo, além dos setores (listar_areas):
      {"funcoes": {setor: [função, ...]}, "niveis": [{"codigo", "nome", "descricao"}, ...],
       "iniciantes": {setor: [função que aceita jovem_aprendiz e trainee, ...]}}
    Só o que está ativo, na ordem do cadastro. Guardado na memória por 10 minutos (as tabelas quase não mudam e o
    serviço web consultaria a cada currículo). Sem as tabelas (migração 031 ainda não aplicada) levanta erro: quem
    chama adia a análise em vez de qualificar sem lista.
    """
    import time
    if _vocabulario_cache["dados"] is not None and time.time() - _vocabulario_cache["quando"] < 600:
        return _vocabulario_cache["dados"]
    db = conectar()
    setores = db.table("setores").select("id,nome").eq("ativo", True).order("ordem").execute().data or []
    linhas = db.table("funcoes_setor").select("setor_id,nome,aceita_iniciante").eq("ativo", True).order("nome").execute().data or []
    funcoes: Dict[str, List[str]] = {}
    iniciantes: Dict[str, List[str]] = {}      # cargos que aceitam jovem_aprendiz e trainee
    for setor in setores:
        do_setor = [f for f in linhas if f["setor_id"] == setor["id"]]
        if do_setor:
            funcoes[setor["nome"]] = [f["nome"] for f in do_setor]
            if any(f.get("aceita_iniciante") for f in do_setor):
                iniciantes[setor["nome"]] = [f["nome"] for f in do_setor if f.get("aceita_iniciante")]
    niveis = db.table("niveis_funcao").select("codigo,nome,descricao").eq("ativo", True).order("ordem").execute().data or []
    _vocabulario_cache.update(quando=time.time(), dados={"funcoes": funcoes, "niveis": niveis, "iniciantes": iniciantes})
    return _vocabulario_cache["dados"]


_regioes_cache: Dict = {"quando": 0.0, "dados": []}


def listar_regioes() -> List[Dict]:
    """
    Regiões do DF e entorno (regioes_df) com os apelidos: o vocabulário de "onde mora" da identificação e do casamento
    local do texto. Guardada na memória por 10 minutos: a tabela quase não muda e o serviço web ficaria consultando
    a cada currículo.
    """
    import time
    if time.time() - _regioes_cache["quando"] < 600 and _regioes_cache["dados"]:
        return _regioes_cache["dados"]
    r = conectar().table("regioes_df").select("id,nome,apelidos").order("nome").execute()
    _regioes_cache.update(quando=time.time(), dados=r.data or [])
    return _regioes_cache["dados"]


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
def curriculo_existe_para_mensagem(message_id: str) -> bool:
    """Só currículos — diferente de email_ja_processado(), que também conta exceção
    (por isso não serve aqui: a exceção que estamos reprocessando sempre existe)."""
    if not message_id:
        return False
    return bool(conectar().table("curriculos").select("id")
                  .eq("email_message_id", message_id).limit(1).execute().data)


def email_ja_processado(message_id: str) -> bool:
    """Evita reprocessar o mesmo e-mail em execuções futuras."""
    if not message_id:
        return False
    db = conectar()
    if db.table("curriculos").select("id")\
         .eq("email_message_id", message_id).limit(1).execute().data:
        return True
    return bool(db.table("excecoes").select("id")
                  .eq("email_message_id", message_id).limit(1).execute().data)


# ─────────────────────────────────────────────
# BANCO DE TALENTOS — candidatos, currículos e análises
# ─────────────────────────────────────────────
CAMPOS_CANDIDATO = ("id,nome,sexo,data_nascimento,idade_informada,cidade,uf,telefone,telefone_e164,email,"
                    "escolaridade,anos_experiencia,cnh,status_banco,retencao_permanente,lista_negra,"
                    "regiao_id,regiao_origem,analise_atual_id,reanalise_solicitada_em")


def buscar_candidato_existente(hash_identidade: Optional[str], email: Optional[str],
                               nome: Optional[str]) -> Optional[Dict]:
    """
    A mesma pessoa já está no banco? Duas chaves, da mais forte para a mais fraca:
      1. hash de identidade (nome + telefone) — o chamador só passa o hash quando tem os dois
      2. mesmo e-mail E mesmo nome (só e-mail não basta: agência ou família dividem o endereço)
    Inclui candidatos expurgados: o hash sobrevive à exclusão e o reenvio reaproveita o cadastro.
    """
    db = conectar()
    if hash_identidade:
        r = db.table("candidatos").select(CAMPOS_CANDIDATO).eq("hash_identidade", hash_identidade)\
              .order("data_entrada").limit(1).execute()
        if r.data:
            return r.data[0]
    if email and nome:
        r = db.table("candidatos").select(CAMPOS_CANDIDATO).eq("email", email.lower())\
              .eq("nome_norm", normalizar_texto(nome)).neq("status_banco", "expurgado")\
              .order("data_entrada").limit(1).execute()
        if r.data:
            return r.data[0]
    return None


def buscar_candidato_por_arquivo(arquivo_hash: Optional[str]) -> Optional[Dict]:
    """
    O candidato dono de um currículo com este arquivo (mesma impressão digital), ou None. Serve para NÃO ler de
    novo o mesmo arquivo: vale para quem já foi sanitizado também (o hash sobrevive à exclusão dos dados).
    """
    if not arquivo_hash:
        return None
    db = conectar()
    r = db.table("curriculos").select("candidato_id").eq("arquivo_hash", arquivo_hash).limit(1).execute().data
    if not r:
        return None
    return obter_candidato(r[0]["candidato_id"])


def ultima_importacao(candidato_id: str) -> Optional[datetime]:
    """Quando o último currículo deste candidato foi importado (None se ele não tem nenhum registro)."""
    r = conectar().table("curriculos").select("created_at").eq("candidato_id", candidato_id)\
        .order("created_at", desc=True).limit(1).execute().data
    if not r or not r[0].get("created_at"):
        return None
    return datetime.fromisoformat(r[0]["created_at"].replace("Z", "+00:00"))


def atualizar_curriculo(curriculo_id: str, dados: Dict) -> None:
    if MODO_SIMULACAO or not dados:
        return
    conectar().table("curriculos").update(dados).eq("id", curriculo_id).execute()


def criar_candidato(dados: Dict) -> Optional[Dict]:
    if MODO_SIMULACAO:
        log.info("  [simulação] candidato não gravado")
        return {"id": "simulado", "status_banco": "ativo"}
    r = conectar().table("candidatos").insert(dados).execute()
    return r.data[0] if r.data else None


def atualizar_candidato(candidato_id: str, dados: Dict) -> None:
    if MODO_SIMULACAO or not dados:
        return
    conectar().table("candidatos").update(dados).eq("id", candidato_id).execute()


def obter_candidato(candidato_id: str) -> Optional[Dict]:
    r = conectar().table("candidatos").select(CAMPOS_CANDIDATO).eq("id", candidato_id).limit(1).execute()
    return r.data[0] if r.data else None


def obter_curriculo_atual(candidato_id: str) -> Optional[Dict]:
    """Currículo vigente do candidato (id, texto, arquivo). None se não houver (ex.: dados já expurgados)."""
    r = conectar().table("curriculos").select("id,texto_extraido,storage_path,nome_arquivo,tipo_mime,arquivo_hash")\
        .eq("candidato_id", candidato_id).eq("atual", True).limit(1).execute().data
    return r[0] if r else None


def salvar_curriculo(dados: Dict) -> Optional[Dict]:
    if MODO_SIMULACAO:
        return {"id": "simulado"}
    r = conectar().table("curriculos").insert(dados).execute()
    return r.data[0] if r.data else None


def proxima_sequencia_analise(candidato_id: str) -> int:
    """Sequência da próxima análise do candidato, acima de todas as anteriores (a mais nova é a vigente)."""
    r = conectar().table("analises_ia").select("sequencia")\
        .eq("candidato_id", candidato_id).order("sequencia", desc=True).limit(1).execute().data
    return r[0]["sequencia"] + 1 if r else 1


def obter_qualificacao_da_vaga(vaga_id: str) -> Optional[Dict]:
    """
    Setor, função e nível que a vaga pede: valem para o currículo enviado à mão a partir dela (o RH já decidiu que ele
    serve). Vaga antiga sem função ou nível devolve None nesses campos: a IA classifica o que faltar.
    """
    db = conectar()
    v = db.table("vagas").select("setor_id,funcao_setor,nivel_funcao").eq("id", vaga_id).limit(1).execute().data
    if not v:
        return None
    setor = db.table("setores").select("nome").eq("id", v[0]["setor_id"]).limit(1).execute().data
    return {"setor": setor[0]["nome"] if setor else None, "funcao": v[0].get("funcao_setor"),
            "nivel": v[0].get("nivel_funcao")}


def salvar_analise(dados: Dict) -> Optional[Dict]:
    """Grava a análise; o gatilho do banco copia a sugestão para o candidato e limpa o pedido de reanálise."""
    if MODO_SIMULACAO:
        return {"id": "simulado"}
    r = conectar().table("analises_ia").insert(dados).execute()
    return r.data[0] if r.data else None


def listar_reanalises(limite: int = 0) -> List[Dict]:
    """Candidatos com (re)análise da IA pedida: recém-migrados, currículo reenviado, botão do painel, ou falha anterior."""
    q = conectar().table("candidatos")\
        .select("id,nome,escolaridade,anos_experiencia,cnh,sexo,data_nascimento,idade_informada,status_banco,"
                "regiao_id,regiao_origem")\
        .not_.is_("reanalise_solicitada_em", "null").neq("status_banco", "expurgado")\
        .order("reanalise_solicitada_em")
    if limite:
        q = q.limit(limite)
    return q.execute().data or []


# ─────────────────────────────────────────────
# CANDIDATURAS (vínculo candidato ↔ vaga, sempre por atribuição do RH)
# ─────────────────────────────────────────────
def atualizar_candidatura(cand_id: str, dados: Dict) -> None:
    if MODO_SIMULACAO:
        return
    conectar().table("candidaturas").update(dados).eq("id", cand_id).execute()


def atribuir_candidato_vaga(candidato_id: str, vaga_id: str, usuario_id: str) -> Optional[str]:
    """Atribui o candidato à vaga em nome de um usuário do RH (upload manual que já escolhe a vaga).
    Levanta erro (mensagem em português) se o candidato já está em processo ou a vaga fechou."""
    if MODO_SIMULACAO:
        log.info("  [simulação] atribuição não gravada")
        return "simulado"
    r = conectar().rpc("fn_atribuir_candidato_vaga", {
        "p_candidato_id": candidato_id, "p_vaga_id": vaga_id, "p_usuario_id": usuario_id,
    }).execute()
    return r.data


def salvar_avaliacao(dados: Dict) -> Optional[Dict]:
    if MODO_SIMULACAO:
        return {"id": "simulado"}
    r = conectar().table("avaliacoes").insert(dados).execute()
    return r.data[0] if r.data else None


# ─────────────────────────────────────────────
# AVALIAÇÃO PARA A VAGA (depois que o RH atribui o candidato a ela)
# ─────────────────────────────────────────────
def listar_reavaliacoes() -> List[Dict]:
    """Candidaturas abertas à espera da nota da IA para a vaga (o painel marca ao atribuir)."""
    return conectar().table("candidaturas").select("id,vaga_id,candidato_id")\
        .eq("avaliacao_pendente", True).is_("encerrada_em", "null")\
        .order("updated_at").execute().data or []


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


def remover_arquivos(caminhos: List[str]) -> bool:
    """Remove do Storage (exclusão de dados/sanitização). True = todos os lotes foram aceitos."""
    if not caminhos or MODO_SIMULACAO:
        return True
    try:
        for i in range(0, len(caminhos), 100):
            conectar().storage.from_(BUCKET_CURRICULOS).remove(caminhos[i:i + 100])
        log.info(f"  {len(caminhos)} arquivo(s) removido(s) do Storage")
        return True
    except Exception as e:
        log.error(f"  Falha ao remover arquivos: {e}")
        return False


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
# MANUTENÇÃO E SANITIZAÇÃO
# ─────────────────────────────────────────────
def executar_manutencao() -> Dict:
    """
    Manutenção diária do banco (partições da auditoria) + remoção dos arquivos de currículo cujos dados
    já foram excluídos. NÃO inativa nem expurga candidatos sozinha: isso é decisão do RH na sanitização.
    """
    if MODO_SIMULACAO:
        return {"arquivos_removidos": 0, "sanitizacao_pendentes": 0}
    r = conectar().rpc("fn_manutencao_diaria").execute()
    resultado = r.data or {}
    arquivos = resultado.get("arquivos_para_remover") or []
    resultado["arquivos_removidos"] = 0
    if arquivos and remover_arquivos(arquivos):
        conectar().rpc("fn_marcar_arquivos_removidos", {"p_caminhos": arquivos}).execute()
        resultado["arquivos_removidos"] = len(arquivos)
    return resultado


def gerar_sugestoes_sanitizacao(origem: str = "job", forcar: bool = False) -> Dict:
    """
    Pede ao banco a lista de sugestões de sanitização. Sem `forcar`, o banco só gera quando o intervalo
    configurado (sanitizacao_intervalo_meses) venceu; senão devolve {"gerada": False, "proxima_em": ...}.
    """
    r = conectar().rpc("fn_gerar_sugestoes_sanitizacao", {"p_origem": origem, "p_forcar": forcar}).execute()
    return r.data or {}


def contar_sugestoes_pendentes() -> Dict[str, int]:
    """{"total": N, "alta": n, "media": n, "baixa": n} das sugestões ainda sem decisão do RH."""
    linhas = conectar().table("sanitizacao_sugestoes").select("prioridade").eq("status", "pendente").execute().data or []
    contagem = {"total": len(linhas), "alta": 0, "media": 0, "baixa": 0}
    for linha in linhas:
        contagem[linha["prioridade"]] += 1
    return contagem


def marcar_ciclo_notificado(ciclo_id: str) -> None:
    if MODO_SIMULACAO:
        return
    conectar().table("sanitizacao_ciclos").update({"notificada_em": agora()}).eq("id", ciclo_id).execute()
