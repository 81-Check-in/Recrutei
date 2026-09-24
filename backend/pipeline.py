"""Orquestração: e-mail → extração → identificação → Banco de Talentos → análise da IA.

Todo currículo entra PRIMEIRO no Banco de Talentos, independente de vaga, já qualificado pela IA (setor, função, nível
e nota). Na vaga não há IA escolhendo currículo: o RH pede "Selecionar CVs" e o banco filtra, por SQL, os currículos com o
setor, a função e o nível da vaga. A única exceção é o currículo enviado à mão a partir de uma vaga: setor, função e nível
são os da vaga (um humano já decidiu a compatibilidade); o resto da qualificação é o de sempre.
"""
from datetime import date, datetime, timezone
from typing import Dict, List, Optional, Tuple
import os
import uuid

import database as bd
import leitor_email as mail
import extrator
import ia
import sanitizacao
from config import (
    FORMATOS_ACEITOS, TAMANHO_MINIMO_ANEXO, TAMANHO_MINIMO_DOCUMENTO, LIMITE_EMAILS, REENVIO_DIAS_MINIMO,
    MODO_SIMULACAO, MODELO_CLASSIFICACAO_PADRAO, MODELO_AVALIACAO_PADRAO,
    CONFIANCA_MINIMA_PADRAO, VERSAO_PROMPT_ANALISE, log,
)
from utils import (
    extrair_telefone, extrair_email, gerar_hash_identidade, gerar_hash_arquivo,
    detectar_link_google_docs, limpar_texto, extrair_idade, extrair_nascimento, separar_cidade_uf,
    detectar_regiao, normalizar_texto,
)


class Estatisticas:
    def __init__(self):
        self.emails_lidos = 0
        self.curriculos_processados = 0
        self.excecoes_geradas = 0
        self.avaliacoes_realizadas = 0      # análises do candidato + avaliações para vaga
        self.duplicados_detectados = 0      # currículo de quem já estava no banco
        self.bloqueados = 0

    def como_dict(self) -> Dict:
        return {
            "emails_lidos": self.emails_lidos,
            "curriculos_processados": self.curriculos_processados,
            "excecoes_geradas": self.excecoes_geradas,
            "avaliacoes_realizadas": self.avaliacoes_realizadas,
            "duplicados_detectados": self.duplicados_detectados,
            "custo_estimado_usd": round(ia.custo_total["usd"], 4),
        }


def _registrar_excecao(msg: Dict, tipo: str, detalhe: str,
                       stats: Estatisticas, nome_arquivo: str = None,
                       excecao_id: str = None, texto: str = None) -> None:
    """
    excecao_id: veio de reprocessar_excecoes() (a mensagem já tinha uma exceção
    registrada) — atualiza a linha existente em vez de criar outra. Sem isso,
    cada tentativa de reprocessar geraria uma exceção nova, duplicando a fila.

    texto: o que foi extraído do anexo/link antes da IA decidir a exceção (só
    existe quando a extração deu certo — "não é currículo").
    Guardado para o RH poder ler exatamente o que a IA viu, no botão "Ver e-mail".
    O corpo do e-mail (msg["corpo"]) é sempre guardado, mesmo sem extração.
    """
    # O detalhe pode conter nome de arquivo/candidato: fica só no banco, não no log
    log.warning(f"  Exceção [{tipo}]{' (reprocessamento)' if excecao_id else ''}")
    if excecao_id:
        bd.atualizar_excecao(excecao_id, {
            "tipo": tipo,
            "detalhe_erro": detalhe,
            "nome_arquivo": nome_arquivo,
            "email_corpo": msg.get("corpo"),
            "texto_extraido": texto,
            "reprocessar_solicitado_em": None,   # a tentativa terminou; não reentra sozinha
        })
        return
    remetente = bd.obter_ou_criar_remetente(msg["remetente"])
    bd.registrar_excecao({
        "remetente_id": remetente["id"] if remetente["id"] != "simulado" else None,
        "email_remetente": msg["remetente"],
        "email_message_id": msg.get("message_id"),
        "email_assunto": msg.get("assunto"),
        "email_corpo": msg.get("corpo"),
        "texto_extraido": texto,
        "tipo": tipo,
        "detalhe_erro": detalhe,
        "nome_arquivo": nome_arquivo,
        "recebido_em": msg.get("recebido_em") or bd.agora(),
    })
    stats.excecoes_geradas += 1


def _tamanho_minimo(anexo: Dict) -> int:
    """Imagem pequena é logotipo/ícone de assinatura de e-mail; documento pequeno pode ser um currículo simples (ver config.py)."""
    return TAMANHO_MINIMO_ANEXO if anexo["tipo_mime"].startswith("image/") else TAMANHO_MINIMO_DOCUMENTO


def _anexos_validos(msg: Dict) -> List[Dict]:
    """Os anexos que podem ser um currículo: assinatura do arquivo confere com o tipo e tamanho acima do piso do tipo. PDF antes dos demais."""
    validos = [a for a in msg["anexos"] if a["tamanho"] >= _tamanho_minimo(a) and a.get("assinatura_ok")]
    validos.sort(key=lambda a: 0 if a["tipo_mime"] == "application/pdf" else 1)
    return validos


def _escolher_anexo(msg: Dict) -> Optional[Dict]:
    """O primeiro anexo que será tentado como currículo (o hash prévio, para não reler o mesmo arquivo, sai dele). None se não houver."""
    validos = _anexos_validos(msg)
    return validos[0] if validos else None


def _obter_texto(msg: Dict) -> tuple:
    """
    Busca o currículo no anexo ou em link do Google Docs.
    Retorna (texto, ocr_aplicado, anexo, origem, erro)
    """
    # 1. Anexo válido. Com mais de um (ex.: um PDF sem texto e um DOCX), vale o primeiro que tiver texto legível; só se NENHUM
    #    tiver é que vira exceção, com o motivo do primeiro tentado.
    primeira_falha = None
    for anexo in _anexos_validos(msg):
        texto, ocr = extrator.extrair(anexo["conteudo"], anexo["tipo_mime"])
        if texto and len(texto.strip()) >= 100:
            origem = {
                "application/pdf": "anexo_pdf",
                "application/msword": "anexo_doc",
            }.get(anexo["tipo_mime"], "anexo_docx")
            if anexo["tipo_mime"].startswith("image/"):
                origem = "anexo_pdf"
            return texto, ocr, anexo, origem, None
        if primeira_falha is None:
            primeira_falha = (anexo, ocr)
    if primeira_falha:
        anexo, ocr = primeira_falha
        tipo_erro = "ocr_falhou" if ocr else "arquivo_corrompido"
        return None, False, anexo, None, (tipo_erro, f"Arquivo '{anexo['nome']}' sem texto legível")

    # 2. Link de Google Docs no corpo. O texto vem do link; o ARQUIVO também é baixado e devolvido como o anexo, para ser
    #    guardado no Storage (sem ele o painel não tem o que abrir). Se o arquivo não puder ser baixado, o currículo entra sem ele.
    link = detectar_link_google_docs(msg.get("corpo", ""))
    if link:
        texto, ocr = extrator.extrair_google_docs(link)
        if texto and len(texto.strip()) >= 100:
            return texto, ocr, extrator.arquivo_do_google_docs(link), "google_docs", None
        return None, False, None, None, (
            "docs_privado", "Link do Google Docs/Drive privado, quebrado ou sem texto legível")

    # 3. Anexo inutilizável: conteúdo diferente do tipo declarado, ou pequeno demais
    if msg["anexos"]:
        if any(not a.get("assinatura_ok") for a in msg["anexos"]):
            return None, False, None, None, (
                "formato_invalido",
                "Anexo com conteúdo diferente do formato declarado"
            )
        return None, False, None, None, (
            "formato_invalido",
            f"Anexo muito pequeno ({msg['anexos'][0]['tamanho']} bytes)"
        )

    return None, False, None, None, ("sem_anexo", "E-mail sem anexo nem link de currículo")


def modelo_configurado(cfg: Dict, chave: str, padrao: str) -> str:
    """Modelo escolhido em Configurações; ausente ou vazio usa o padrão."""
    valor = cfg.get(chave)
    return valor.strip() if isinstance(valor, str) and valor.strip() else padrao


def faixa_segunda_avaliacao(cfg: Dict) -> Optional[Tuple[int, int]]:
    """
    Faixa de notas que dispara a segunda avaliação (avaliação para vaga); None = desativada.
    Desativa quando faixa_ambigua_min ou faixa_ambigua_max está vazia, ou quando
    DESATIVAR_SEGUNDA_AVALIACAO=true (override só para esta execução, sem mexer
    na configuração salva no banco).
    """
    if os.getenv("DESATIVAR_SEGUNDA_AVALIACAO", "").strip().lower() == "true":
        return None
    brutos = [cfg.get("faixa_ambigua_min", 60), cfg.get("faixa_ambigua_max", 75)]
    if any(v is None or str(v).strip() == "" for v in brutos):
        return None
    try:
        return int(float(brutos[0])), int(float(brutos[1]))
    except (TypeError, ValueError):
        log.warning("faixa_ambigua_min/max inválidas — usando 60 a 75")
        return 60, 75


def confianca_minima(cfg: Dict) -> int:
    """Confiança (0–100) abaixo da qual a análise vira "revisão manual necessária" (Configurações)."""
    try:
        return max(0, min(100, int(float(cfg.get("ia_confianca_minima", CONFIANCA_MINIMA_PADRAO)))))
    except (TypeError, ValueError):
        return CONFIANCA_MINIMA_PADRAO


def _perfil_do_curriculo(texto: str, cfg: Dict) -> Dict:
    """
    Dados de busca do currículo, para os filtros do Banco de Talentos:
    idade (lida do texto, sem IA), escolaridade, anos de experiência, CNH e sexo (Haiku).
    Nunca derruba o processamento: falha vira perfil parcial.
    """
    perfil: Dict = {}
    idade = extrair_idade(texto)
    if idade is not None:
        perfil["idade"] = idade
    try:
        extra, _ = ia.extrair_perfil(
            texto, modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO))
        if extra:
            perfil.update({k: v for k, v in extra.items() if v is not None})
    except Exception as e:
        log.warning(f"  Não consegui extrair o perfil de busca: {e}")
    return perfil


def _campos_de_perfil(texto: str, perfil: Dict) -> Dict:
    """Do perfil extraído aos campos de "candidatos". Data de nascimento exata vale mais que a idade."""
    campos: Dict = {}
    nascimento = extrair_nascimento(texto)
    if nascimento:
        campos["data_nascimento"] = nascimento.isoformat()
    elif perfil.get("idade") is not None:
        campos["idade_informada"] = perfil["idade"]
        campos["idade_informada_em"] = date.today().isoformat()
    for chave in ("escolaridade", "anos_experiencia", "cnh", "sexo"):
        if perfil.get(chave) is not None:
            campos[chave] = perfil[chave]
    return campos


def _marcar_lido() -> bool:
    """
    Todo e-mail que o sistema leu vira "lido" na caixa: currículo importado, exceção registrada, reenvio ignorado
    ou remetente bloqueado. Só o que falhou de vez (nem a exceção foi gravada) continua não lido, para ser tentado
    de novo. (Antes só os e-mails de uma área, SETOR_MARCAR_LIDO, eram marcados; essa regra acabou.)
    """
    return True


def _mesmo_texto(a: Optional[str], b: Optional[str]) -> bool:
    """Currículo igual ao anterior, ignorando diferenças de espaço e quebra de linha."""
    return " ".join((a or "").split()) == " ".join((b or "").split())


# ═══════════════════════════════════════════════════════════
#  ENTRADA NO BANCO DE TALENTOS + ANÁLISE DA IA
# ═══════════════════════════════════════════════════════════
def _qualificar_curriculo(curriculo_id: Optional[str], analise: Dict) -> None:
    """
    Grava no PRÓPRIO currículo o que a IA identificou: setor_adequado, funcao_setor, nivel_funcao e a nota (na análise e
    no candidato os três primeiros se chamam area/cargo/nivel_sugerido, que é o que o painel lê). É daqui que a seleção
    de currículos de uma vaga filtra e ordena. Falhar aqui não desfaz a análise, que já está salva: só fica no log.
    """
    if not curriculo_id or curriculo_id == "simulado":
        return
    try:
        bd.atualizar_curriculo(curriculo_id, {
            "setor_adequado": analise["area_sugerida"],
            "funcao_setor": analise["cargo_sugerido"],
            "nivel_funcao": analise["nivel_sugerido"],
            "nota_classificacao": analise.get("nota"),
        })
    except Exception as e:
        log.error(f"  Não consegui gravar a qualificação no currículo: {type(e).__name__}")


def _analisar_e_salvar(candidato_id: str, curriculo_id: Optional[str], texto: str,
                       nome: Optional[str], cfg: Dict, areas: List[str],
                       stats: Estatisticas, qualificacao_forcada: Optional[Dict] = None) -> Optional[Dict]:
    """
    Qualifica o currículo (sem vaga): a IA escolhe setor, função e nível entre os valores das tabelas setores,
    funcoes_setor e niveis_funcao. O resultado vai para o currículo (setor_adequado, funcao_setor, nivel_funcao) e
    para analises_ia, de onde o gatilho do banco copia a sugestão para o candidato (o painel lê de lá). Se a IA não
    classificar os três, marca "revisão manual".
    qualificacao_forcada: {"setor", "funcao", "nivel"} da vaga de onde o currículo foi enviado à mão. Esses valores
    (os que a vaga tiver) substituem os da IA: um humano já decidiu a compatibilidade. O resto, nota inclusive, é da IA.
    None = não houve análise válida (IA sem resposta ou tabelas de valores indisponíveis): o pedido de reanálise
    continua no candidato e a próxima execução tenta de novo.
    """
    try:
        vocabulario = bd.carregar_vocabulario_qualificacao()
    except Exception as e:
        log.error(f"  Tabelas de setor/função/nível indisponíveis ({type(e).__name__}): análise adiada")
        return None
    if not vocabulario.get("niveis"):
        log.error("  Nenhum nível ativo cadastrado (niveis_funcao): análise adiada")
        return None

    modelo = modelo_configurado(cfg, "modelo_ia_avaliacao", MODELO_AVALIACAO_PADRAO)
    try:
        analise, uso = ia.analisar_curriculo(texto, areas, modelo, nome_candidato=nome,
                                             funcoes=vocabulario["funcoes"], niveis=vocabulario["niveis"],
                                             iniciantes=vocabulario.get("iniciantes"))
    except Exception as e:
        log.error(f"  Falha na análise: {e}")
        return None
    if not analise:
        log.error("  Analisador não retornou resposta válida")
        return None

    if qualificacao_forcada:
        for campo, chave in (("area_sugerida", "setor"), ("cargo_sugerido", "funcao"), ("nivel_sugerido", "nivel")):
            if qualificacao_forcada.get(chave):
                analise[campo] = qualificacao_forcada[chave]

    revisao, motivo = ia.avaliar_necessidade_revisao(analise, confianca_minima(cfg))
    confianca = analise["confianca"]
    log.info(f"  Qualificação{' (setor/função/nível da vaga)' if qualificacao_forcada else ''}: "
             f"{analise['area_sugerida'] or '?'} / {analise['cargo_sugerido'] or '?'} / "
             f"{analise['nivel_sugerido'] or '?'}, nota {analise.get('nota') if analise.get('nota') is not None else '?'}"
             f"{f' (confiança {confianca}%)' if confianca is not None else ''}"
             f"{' — REVISÃO MANUAL' if revisao else ''}")
    stats.avaliacoes_realizadas += 1
    if MODO_SIMULACAO:
        return {**analise, "revisao_manual": revisao}

    bd.salvar_analise({
        "candidato_id": candidato_id,
        "curriculo_id": curriculo_id if curriculo_id and curriculo_id != "simulado" else None,
        "sequencia": bd.proxima_sequencia_analise(candidato_id),
        "pontos_positivos": analise["pontos_positivos"],
        "pontos_negativos": analise["pontos_negativos"],
        "area_sugerida": analise["area_sugerida"],
        "cargo_sugerido": analise["cargo_sugerido"],
        "nivel_sugerido": analise["nivel_sugerido"],
        "confianca": analise["confianca"],
        "revisao_manual": revisao,
        "motivo_revisao": motivo,
        "texto_resumo_ia": analise["texto_resumo_ia"],
        "palavras_chave": analise["palavras_chave"],
        "versao_modelo_ia": uso["modelo"],
        "versao_prompt": VERSAO_PROMPT_ANALISE,
        "tokens_entrada": uso["tokens_entrada"],
        "tokens_saida": uso["tokens_saida"],
        "duracao_ms": uso["duracao_ms"],
    })
    _qualificar_curriculo(curriculo_id, analise)
    return {**analise, "revisao_manual": revisao}


def _regioes() -> List[Dict]:
    """Regiões do DF e entorno. Sem a tabela (banco ainda sem a migração 030) segue sem região: nunca derruba a importação."""
    try:
        return bd.listar_regioes()
    except Exception as e:
        log.warning(f"  Regiões indisponíveis: {type(e).__name__}")
        return []


def _nomes_das_regioes() -> List[str]:
    """Vocabulário de regiões para a identificação da IA."""
    return [r["nome"] for r in _regioes()]


def _resolver_regiao(ident: Dict, texto: str, regioes: List[Dict]) -> Dict:
    """
    Região onde o candidato mora, para a distância até as lojas. Duas fontes, da mais confiável para a menos:
      1. a IA (a identificação já lê o currículo): vale se devolveu um nome EXATO da lista de regiões;
      2. o texto do currículo, casado localmente com os nomes/apelidos das regiões (pega as linhas de endereço, que a
         IA não vê porque o mascaramento as troca por [ENDEREÇO]).
    Sem nenhuma das duas, nada é gravado: o banco acha a região pela cidade cadastrada (origem "cidade").
    A correção manual do RH ("manual") nunca é sobrescrita: quem grava confere antes.
    """
    campos: Dict = {}
    if ident.get("bairro"):
        campos["bairro"] = ident["bairro"]
    if not regioes:
        return campos
    por_nome = {normalizar_texto(r["nome"]): r["id"] for r in regioes}
    id_ia = por_nome.get(normalizar_texto(ident.get("regiao") or ""))
    if id_ia:
        return {**campos, "regiao_id": id_ia, "regiao_origem": "ia"}
    id_texto = detectar_regiao(texto, regioes)
    if id_texto:
        return {**campos, "regiao_id": id_texto, "regiao_origem": "texto"}
    return campos


def _motivo_para_nao_reler(candidato: Dict) -> Optional[str]:
    """
    Regra de reincidência: o mesmo currículo não é lido de novo, seja qual for a vaga. None = pode ler; texto = por
    que não. Só volta a ser lido quando as DUAS coisas são verdade: passaram REENVIO_DIAS_MINIMO dias da importação
    anterior e o candidato foi sanitizado (inativo ou com os dados excluídos). Nunca para quem está na lista negra nem
    para quem tem retenção permanente (contratado).
    """
    if candidato.get("lista_negra"):
        return "candidato na lista negra"
    if candidato.get("retencao_permanente"):
        return "candidato com retenção permanente"
    ultima = bd.ultima_importacao(candidato["id"])
    dias = (datetime.now(timezone.utc) - ultima).days if ultima else None
    if candidato.get("status_banco") not in ("inativo", "expurgado"):
        lido = f" (lido há {dias} dia(s))" if dias is not None else ""
        return f"já está no banco{lido}; só é relido depois de sanitizado"
    if dias is not None and dias < REENVIO_DIAS_MINIMO:
        return f"lido há {dias} dia(s); só é relido depois de {REENVIO_DIAS_MINIMO} dias"
    return None


def _entrar_no_banco(texto: str, ident: Dict, cfg: Dict, areas: List[str], stats: Estatisticas, *,
                     origem_entrada: str, curriculo: Dict, arquivo: Optional[Dict] = None,
                     email_padrao: Optional[str] = None, qualificacao_forcada: Optional[Dict] = None) -> Optional[Dict]:
    """
    Coloca o currículo no Banco de Talentos e dispara a análise da IA.

      • pessoa nova            → cria o candidato ("ativo")
      • pessoa que já está lá  → NÃO é lida de novo (regra de reincidência). Só quando passaram 30 dias da importação
                                 anterior E ela foi sanitizada: o currículo vira a versão ATUAL do mesmo candidato,
                                 a análise é refeita e ele volta a "ativo"
      • e-mail na lista negra  → ignorado
    curriculo: colunas da tabela curriculos (sem candidato_id/texto). arquivo: {"conteudo","tipo_mime"} a subir
    ao Storage (e-mail); no upload manual o arquivo já está lá e curriculo traz o storage_path.
    Devolve {"candidato_id", "novo", "analise"[, "ignorado": motivo]} ou None se não conseguiu gravar o candidato.
    Com "ignorado", nada foi gravado (candidato_id é o do cadastro que já existia, ou None na lista negra).
    """
    nome = ident.get("nome_candidato")
    telefone = extrair_telefone(texto)
    email_cand = extrair_email(texto) or email_padrao
    hash_id = gerar_hash_identidade(nome, telefone)

    # Lista negra: vale também o e-mail que consta no próprio currículo (a pessoa pode escrever de outro endereço)
    if email_cand and bd.remetente_bloqueado(email_cand):
        log.info("  E-mail do currículo está na lista negra — ignorando")
        return {"candidato_id": None, "novo": False, "analise": None, "ignorado": "e-mail na lista negra"}

    # Só reconhece a pessoa pelo hash quando há nome E telefone (nome sozinho junta homônimos)
    existente = bd.buscar_candidato_existente(hash_id if (nome and telefone) else None, email_cand, nome)

    # Reincidência: quem já está no banco não é lido de novo (só depois de 30 dias E de sanitizado). Decide-se AQUI,
    # antes do perfil (outra chamada à IA), para o reenvio não custar nada.
    if existente:
        motivo = _motivo_para_nao_reler(existente)
        if motivo:
            stats.duplicados_detectados += 1
            log.info(f"  Currículo não relido: {motivo}")
            return {"candidato_id": existente["id"], "novo": False, "analise": None, "ignorado": motivo}

    cidade, uf = separar_cidade_uf(ident.get("cidade"))
    regiao = _resolver_regiao(ident, texto, _regioes())
    if existente and existente.get("regiao_origem") == "manual":      # a correção do RH vale mais que a IA
        regiao = {k: v for k, v in regiao.items() if not k.startswith("regiao")}
    dados = {"nome": nome, "telefone": telefone, "telefone_e164": telefone, "email": email_cand,
             "cidade": cidade, "uf": uf, **regiao,
             **_campos_de_perfil(texto, _perfil_do_curriculo(texto, cfg))}
    dados = {k: v for k, v in dados.items() if v is not None}

    if existente:
        candidato_id = existente["id"]
        stats.duplicados_detectados += 1
        atual = bd.obter_curriculo_atual(candidato_id)
        refazer_analise = (not existente.get("analise_atual_id")
                           or not _mesmo_texto((atual or {}).get("texto_extraido"), texto))
        campos = dict(dados)
        if existente["status_banco"] in ("inativo", "expurgado"):
            campos.update({"status_banco": "ativo", "inativado_em": None, "motivo_inativacao": None,
                           "expurgado_em": None, "retencao_permanente": False})
        if refazer_analise:
            campos["reanalise_solicitada_em"] = bd.agora()
        bd.atualizar_candidato(candidato_id, campos)
        log.info("  Candidato já está no Banco de Talentos — currículo novo vira a versão atual"
                 f"{'' if refazer_analise else ' (texto igual: análise mantida)'}")
    else:
        criado = bd.criar_candidato({
            **dados, "hash_identidade": hash_id, "status_banco": "ativo", "origem_entrada": origem_entrada,
            "reanalise_solicitada_em": bd.agora(),      # a análise limpa este pedido; se falhar, a próxima execução refaz
        })
        if not criado:
            return None
        candidato_id, refazer_analise = criado["id"], True
        log.info("  Novo candidato no Banco de Talentos")

    # ── Arquivo no Storage ──
    linha_curriculo = dict(curriculo)
    if arquivo and not MODO_SIMULACAO:
        ext = FORMATOS_ACEITOS.get(arquivo["tipo_mime"], ".bin")
        hoje = datetime.now(timezone.utc)
        caminho = f"{hoje.year}/{hoje.month:02d}/{uuid.uuid4().hex}{ext}"
        linha_curriculo["storage_path"] = bd.enviar_arquivo(caminho, arquivo["conteudo"], arquivo["tipo_mime"])

    salvo = bd.salvar_curriculo({**linha_curriculo, "candidato_id": candidato_id,
                                 "texto_extraido": texto, "atual": True})

    analise = None
    if refazer_analise:
        analise = _analisar_e_salvar(candidato_id, (salvo or {}).get("id"), texto, nome, cfg, areas, stats,
                                     qualificacao_forcada=qualificacao_forcada)
    return {"candidato_id": candidato_id, "novo": not existente, "analise": analise}


def processar_mensagem(msg: Dict, cfg: Dict, areas: List[str],
                       stats: Estatisticas, excecao_id: str = None) -> bool:
    """
    Processa um e-mail. Retorna True se ele deve ser marcado como lido.

    excecao_id: preenchido só por reprocessar_excecoes() — esta mensagem já tem
    uma exceção registrada e o RH pediu para tentar de novo. Pula a checagem de
    idempotência (que bloquearia por já existir essa mesma exceção) e, se der
    certo esta vez, atualiza a exceção em vez de criar outra.
    """
    uid = msg["uid"].decode() if isinstance(msg["uid"], bytes) else msg["uid"]
    log.info(f"► mensagem UID {uid}")

    # Idempotência (pulada no reprocessamento: a exceção existente É o motivo de tentar de novo)
    if not excecao_id and msg.get("message_id") and bd.email_ja_processado(msg["message_id"]):
        log.info("  Já processado anteriormente — ignorando")
        return _marcar_lido()

    # Remetente bloqueado
    if bd.remetente_bloqueado(msg["remetente"]):
        log.info("  Remetente bloqueado — ignorando")
        stats.bloqueados += 1
        return _marcar_lido()

    # Reincidência: o mesmo ARQUIVO não é lido de novo, seja qual for a vaga (antes de gastar extração, OCR e IA)
    anexo_previsto = _escolher_anexo(msg)
    hash_arquivo = gerar_hash_arquivo(anexo_previsto["conteudo"]) if anexo_previsto else None
    dono = bd.buscar_candidato_por_arquivo(hash_arquivo)
    motivo = _motivo_para_nao_reler(dono) if dono else None
    if motivo:
        stats.duplicados_detectados += 1
        log.info(f"  Mesmo arquivo já lido — ignorando ({motivo})")
        if excecao_id:
            bd.atualizar_excecao(excecao_id, {"status": "revisado", "reprocessar_solicitado_em": None,
                                              "detalhe_erro": f"Currículo já lido antes: {motivo}."})
        return _marcar_lido()

    # ── Extração ──
    texto, ocr, anexo, origem, erro = _obter_texto(msg)
    if anexo and (not hash_arquivo or anexo is not anexo_previsto):   # link do Drive, ou outro anexo que não o previsto: a impressão digital é do arquivo lido
        hash_arquivo = gerar_hash_arquivo(anexo["conteudo"])
    if erro:
        _registrar_excecao(msg, erro[0], erro[1], stats,
                           anexo["nome"] if anexo else None, excecao_id)
        return _marcar_lido()

    texto = limpar_texto(texto)

    # ── Identificação (Haiku): é currículo? quem é? ──
    modelo_cls = modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
    try:
        ident, _ = ia.identificar_curriculo(texto, modelo_cls, _nomes_das_regioes())
    except Exception as e:
        _registrar_excecao(msg, "erro_processamento", f"Falha na identificação: {e}", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido()

    if not ident:
        _registrar_excecao(msg, "erro_processamento",
                           "Identificador não retornou resposta válida", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido()

    if not ident.get("e_curriculo"):
        _registrar_excecao(msg, "nao_e_curriculo",
                           "Conteúdo não identificado como currículo", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido()

    # ── Banco de Talentos + análise ──
    remetente = bd.obter_ou_criar_remetente(msg["remetente"])
    resultado = _entrar_no_banco(
        texto, ident, cfg, areas, stats, origem_entrada="email",
        email_padrao=msg["remetente"],
        arquivo={"conteudo": anexo["conteudo"], "tipo_mime": anexo["tipo_mime"]} if anexo else None,
        curriculo={
            "remetente_id": remetente["id"] if remetente["id"] != "simulado" else None,
            # quem enviou e quando: vêm do cabeçalho do e-mail (From e Date), não da IA, então existem mesmo que a
            # análise falhe ou o currículo não traga e-mail. recebido_em é a data do envio.
            "email_envio": msg["remetente"],
            "email_message_id": msg.get("message_id"),
            "email_assunto": msg.get("assunto"),
            "recebido_em": msg.get("recebido_em") or bd.agora(),
            "nome_arquivo": anexo["nome"] if anexo else None,
            "tipo_mime": anexo["tipo_mime"] if anexo else "text/plain",
            "tamanho_bytes": anexo["tamanho"] if anexo else None,
            "origem": origem,
            "ocr_aplicado": ocr,
            "extracao_ok": True,
            "arquivo_hash": hash_arquivo,
        })
    if resultado and resultado.get("ignorado"):
        log.info(f"  Nada a importar: {resultado['ignorado']}")
        if excecao_id:
            bd.atualizar_excecao(excecao_id, {"status": "revisado", "reprocessar_solicitado_em": None,
                                              "detalhe_erro": f"Não importado: {resultado['ignorado']}."})
        return _marcar_lido()
    if not resultado:
        log.error("  Falha ao criar candidato")
        _registrar_excecao(msg, "erro_processamento", "Falha ao criar candidato", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido()

    # A partir daqui o currículo está no banco: se isto era um reprocessamento, a exceção original
    # está resolvida, mesmo que a análise ainda falhe — ela tem sua própria tentativa de novo.
    if excecao_id:
        bd.atualizar_excecao(excecao_id, {
            "status": "revisado",
            "detalhe_erro": "Reprocessado com sucesso — currículo no Banco de Talentos.",
            "reprocessar_solicitado_em": None,
        })

    stats.curriculos_processados += 1
    return _marcar_lido()


# ═══════════════════════════════════════════════════════════
#  (RE)ANÁLISE DO CANDIDATO — recém-migrados, currículo reenviado, botão do painel
# ═══════════════════════════════════════════════════════════
def reanalisar_candidato(cand: Dict, cfg: Dict, areas: List[str],
                         stats: Estatisticas) -> Optional[Dict]:
    """
    Refaz a análise de um candidato a partir do currículo atual. Aproveita para completar o perfil de
    busca (escolaridade, experiência, CNH, idade) de quem ainda não tem. Sem texto de currículo (dados
    excluídos) não há o que analisar: o pedido é encerrado, para não se repetir para sempre.
    """
    curriculo = bd.obter_curriculo_atual(cand["id"])
    texto = (curriculo or {}).get("texto_extraido")
    if not texto:
        log.warning(f"  candidato {cand['id'][:8]}: sem texto de currículo — reanálise encerrada")
        bd.atualizar_candidato(cand["id"], {"reanalise_solicitada_em": None})
        return None

    # Currículo importado antes da regra de reincidência não tem a impressão digital do arquivo: completa agora,
    # para que um reenvio do mesmo arquivo seja reconhecido sem ser lido de novo
    if not curriculo.get("arquivo_hash") and curriculo.get("storage_path"):
        conteudo = bd.baixar_arquivo(curriculo["storage_path"])
        if conteudo:
            bd.atualizar_curriculo(curriculo["id"], {"arquivo_hash": gerar_hash_arquivo(conteudo)})

    if all(cand.get(k) is None for k in ("escolaridade", "anos_experiencia")):
        campos = _campos_de_perfil(texto, _perfil_do_curriculo(texto, cfg))
        # só preenche o que está em branco: nada do que o RH corrigiu é sobrescrito
        vazios = {k: v for k, v in campos.items()
                  if cand.get(k) is None and not (k == "idade_informada" and cand.get("data_nascimento"))
                  and not (k == "data_nascimento" and cand.get("idade_informada"))}
        bd.atualizar_candidato(cand["id"], vazios)

    # Região onde mora, pelo texto do currículo (local e sem custo): só onde ainda não há uma decidida pela IA ou pelo RH
    if cand.get("regiao_origem") in (None, "cidade"):
        id_regiao = detectar_regiao(texto, _regioes())
        if id_regiao and id_regiao != cand.get("regiao_id"):
            bd.atualizar_candidato(cand["id"], {"regiao_id": id_regiao, "regiao_origem": "texto"})

    return _analisar_e_salvar(cand["id"], curriculo.get("id"), texto, cand.get("nome"), cfg, areas, stats)


def reanalisar_pendentes(pendentes: List[Dict], cfg: Dict, areas: List[str], stats: Estatisticas) -> None:
    log.info(f"{len(pendentes)} reanálise(s) pendente(s)")
    for cand in pendentes:
        try:
            log.info(f"► reanalisando candidato {cand['id'][:8]}")
            if reanalisar_candidato(cand, cfg, areas, stats) is None:
                log.warning("  Fica pendente; tento de novo na próxima execução")
        except Exception as e:
            log.error(f"  Erro inesperado na reanálise: {e}", exc_info=True)


def reanalisar() -> Dict:
    """
    Só as (re)análises pendentes, sem ler e-mails (python main.py --reanalisar). É o que preenche
    Área / Cargo / Nível dos candidatos migrados do modelo antigo. Use --limite N para fazer só N.
    Sem nada pendente não registra execução, para poder rodar com frequência.
    """
    ia.resetar_custo()
    stats = Estatisticas()
    pendentes = bd.listar_reanalises(LIMITE_EMAILS)
    if not pendentes:
        log.info("Nenhuma reanálise pendente")
        return stats.como_dict()

    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — nada será gravado")
    exec_id = bd.iniciar_execucao()
    erro_fatal = None
    try:
        reanalisar_pendentes(pendentes, bd.carregar_configuracoes(), bd.listar_areas(), stats)
    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)
    finally:
        bd.finalizar_execucao(exec_id, stats.como_dict(),
                              sucesso=erro_fatal is None, erro=erro_fatal)

    log.info(f"Análises realizadas    : {stats.avaliacoes_realizadas} de {len(pendentes)}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    return stats.como_dict()


# ═══════════════════════════════════════════════════════════
#  AVALIAÇÃO PARA UMA VAGA — só depois que o RH atribui o candidato a ela
# ═══════════════════════════════════════════════════════════
def _avaliar_e_salvar(cand_id: str, texto: str, vaga: Dict, nome: Optional[str],
                      cfg: Dict, stats: Estatisticas, sequencia: int = 1) -> bool:
    """
    Avalia o currículo contra a vaga e grava a nota. Na faixa ambígua grava também
    a segunda opinião (sequencia + 1). False = a IA não devolveu avaliação válida.
    cand_id é o id da CANDIDATURA (o vínculo candidato ↔ vaga).
    """
    modelo_aval = modelo_configurado(cfg, "modelo_ia_avaliacao", MODELO_AVALIACAO_PADRAO)
    try:
        aval, uso = ia.avaliar(texto, vaga, modelo_aval, variacao=1,
                               nome_candidato=nome)
    except Exception as e:
        log.error(f"  Falha na avaliação: {e}")
        return False

    if not aval:
        log.error("  Avaliador não retornou resposta válida")
        return False

    nota = int(aval.get("nota", 0))
    log.info(f"  Nota: {nota}")

    bd.salvar_avaliacao({
        "candidatura_id": cand_id,
        "vaga_id": vaga["id"],
        "nota": nota,
        "resumo_nota": aval.get("resumo_nota"),
        "resumo_ia": aval.get("resumo_ia"),
        "pontos_fortes": aval.get("pontos_fortes") or [],
        "lacunas": aval.get("lacunas") or [],
        "requisitos_faltantes": aval.get("requisitos_faltantes") or [],
        "eliminado_por_regra": bool(aval.get("eliminado_por_regra")),
        "versao_criterios": vaga["versao_criterios"],
        "modelo_ia": uso["modelo"],
        "tokens_entrada": uso["tokens_entrada"],
        "tokens_saida": uso["tokens_saida"],
        "duracao_ms": uso["duracao_ms"],
        "sequencia": sequencia,
    })
    stats.avaliacoes_realizadas += 1

    # ── Segunda opinião (faixa ambígua) ──
    faixa = faixa_segunda_avaliacao(cfg)

    if faixa and faixa[0] <= nota <= faixa[1]:
        log.info(f"  Nota na faixa ambígua — segunda avaliação")
        try:
            aval2, uso2 = ia.avaliar(texto, vaga, modelo_aval, variacao=2,
                                     nome_candidato=nome)
            if aval2:
                nota2 = int(aval2.get("nota", 0))
                divergiu = abs(nota - nota2) > 10
                log.info(f"  Segunda nota: {nota2}"
                         f"{' — DIVERGÊNCIA' if divergiu else ''}")

                bd.salvar_avaliacao({
                    "candidatura_id": cand_id,
                    "vaga_id": vaga["id"],
                    "nota": nota2,
                    "resumo_nota": aval2.get("resumo_nota"),
                    "resumo_ia": aval2.get("resumo_ia"),
                    "pontos_fortes": aval2.get("pontos_fortes") or [],
                    "lacunas": aval2.get("lacunas") or [],
                    "requisitos_faltantes": aval2.get("requisitos_faltantes") or [],
                    "eliminado_por_regra": bool(aval2.get("eliminado_por_regra")),
                    "versao_criterios": vaga["versao_criterios"],
                    "modelo_ia": uso2["modelo"],
                    "tokens_entrada": uso2["tokens_entrada"],
                    "tokens_saida": uso2["tokens_saida"],
                    "duracao_ms": uso2["duracao_ms"],
                    "sequencia": sequencia + 1,
                    "divergencia_detectada": divergiu,
                })
                stats.avaliacoes_realizadas += 1
        except Exception as e:
            log.warning(f"  Segunda avaliação falhou: {e}")

    return True


def reavaliar_pendentes(pendentes: List[Dict], vagas: List[Dict], cfg: Dict,
                        stats: Estatisticas) -> None:
    """
    Avalia contra a vaga as candidaturas que o RH atribuiu no painel (avaliacao_pendente), usando o
    currículo atual do candidato. A nota entra como a avaliação mais recente da candidatura. Não mexe no
    status da candidatura: quem move o processo é o RH (agendar, aprovar, reprovar…).
    """
    log.info(f"{len(pendentes)} avaliação(ões) para vaga pendente(s)")
    por_id = {v["id"]: v for v in vagas}

    for cand in pendentes:
        cand_id = cand["id"]
        try:
            vaga = por_id.get(cand["vaga_id"])
            log.info(f"► avaliando candidatura {cand_id[:8]}"
                     f"{' para ' + vaga['titulo'] if vaga else ''}")
            if not vaga:
                log.warning("  A vaga não está mais aberta — sem nota para esta candidatura")
                bd.atualizar_candidatura(cand_id, {"avaliacao_pendente": False})
                continue

            curriculo = bd.obter_curriculo_atual(cand["candidato_id"])
            texto = (curriculo or {}).get("texto_extraido")
            if not texto:
                log.warning("  Sem texto do currículo (dados expurgados?) — sem nota para esta candidatura")
                bd.atualizar_candidatura(cand_id, {"avaliacao_pendente": False})
                continue

            candidato = bd.obter_candidato(cand["candidato_id"]) or {}
            if _avaliar_e_salvar(cand_id, texto, vaga, candidato.get("nome"), cfg, stats,
                                 sequencia=bd.proxima_sequencia(cand_id)):
                bd.atualizar_candidatura(cand_id, {"avaliacao_pendente": False})
            else:
                log.warning("  Fica pendente; tento de novo na próxima execução")
        except Exception as e:
            log.error(f"  Erro inesperado na avaliação: {e}", exc_info=True)


def reavaliar() -> Dict:
    """
    Só as avaliações para vaga pendentes, sem ler e-mails (python main.py --reavaliar).
    Sem nada pendente não registra execução, para poder rodar com frequência.
    """
    ia.resetar_custo()
    stats = Estatisticas()
    pendentes = bd.listar_reavaliacoes()
    if not pendentes:
        log.info("Nenhuma avaliação para vaga pendente")
        return stats.como_dict()

    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — nada será gravado")
    exec_id = bd.iniciar_execucao()
    erro_fatal = None
    try:
        cfg = bd.carregar_configuracoes()
        reavaliar_pendentes(pendentes, bd.listar_vagas_abertas(), cfg, stats)
    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)
    finally:
        bd.finalizar_execucao(exec_id, stats.como_dict(),
                              sucesso=erro_fatal is None, erro=erro_fatal)

    log.info(f"Avaliações realizadas  : {stats.avaliacoes_realizadas}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    return stats.como_dict()


def reprocessar_excecoes() -> Dict:
    """
    Tenta de novo as exceções que o RH marcou na Fila de exceções (botão
    "Reprocessar"), sem ler o restante da caixa de entrada
    (python main.py --reprocessar-excecoes). Busca cada e-mail original de novo
    pelo Message-ID e roda o mesmo caminho de sempre — então uma causa
    passageira (link do Drive que estava privado, oscilação da IA) pode se
    resolver nesta tentativa, mesmo sem nada ter mudado no e-mail em si.

    Sem nada marcado não registra execução, para poder rodar com frequência.
    """
    ia.resetar_custo()
    stats = Estatisticas()
    pendentes = bd.listar_excecoes_para_reprocessar()
    if not pendentes:
        log.info("Nenhuma exceção marcada para reprocessar")
        return stats.como_dict()

    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — nada será gravado")
    log.info(f"{len(pendentes)} exceção(ões) marcada(s) para reprocessar")

    exec_id = bd.iniciar_execucao()
    erro_fatal = None
    try:
        cfg = bd.carregar_configuracoes()
        areas = bd.listar_areas()
        for exc in pendentes:
            message_id = exc.get("email_message_id")
            log.info(f"► reprocessando exceção {exc['id'][:8]} ({exc['email_remetente']})")
            try:
                if not message_id:
                    log.warning("  Sem Message-ID salvo — não é possível buscar o e-mail original")
                    bd.atualizar_excecao(exc["id"], {"reprocessar_solicitado_em": None})
                    continue

                # Este e-mail já virou currículo por outro caminho (ex.: uma execução normal
                # o pegou de novo antes de alguém revisar esta exceção) — a exceção ficou
                # esquecida, mas não há nada a reprocessar: só encerrar, sem tentar duplicar
                # (isso já quebrou o lote uma vez: "duplicate key" no Message-ID).
                if bd.curriculo_existe_para_mensagem(message_id):
                    bd.atualizar_excecao(exc["id"], {
                        "status": "revisado",
                        "detalhe_erro": "Este e-mail já tinha virado currículo por outro caminho — exceção estava desatualizada.",
                        "reprocessar_solicitado_em": None,
                    })
                    continue

                msg = mail.buscar_por_message_id(message_id)
                if not msg:
                    bd.atualizar_excecao(exc["id"], {
                        "tipo": "erro_processamento",
                        "detalhe_erro": "E-mail original não encontrado na caixa (pode ter sido apagado)",
                        "reprocessar_solicitado_em": None,
                    })
                    continue
                processar_mensagem(msg, cfg, areas, stats, excecao_id=exc["id"])
            except Exception as e:
                # Uma exceção só não pode travar as outras 25 — antes travava o lote inteiro.
                log.error(f"  Falha ao reprocessar {exc['id'][:8]}: {e}", exc_info=True)
                try:
                    bd.atualizar_excecao(exc["id"], {"reprocessar_solicitado_em": None})
                except Exception:
                    pass
    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)
    finally:
        bd.finalizar_execucao(exec_id, stats.como_dict(),
                              sucesso=erro_fatal is None, erro=erro_fatal)

    log.info(f"Currículos processados : {stats.curriculos_processados} de {len(pendentes)}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    return stats.como_dict()


# ═══════════════════════════════════════════════════════════
#  UPLOAD MANUAL (currículo enviado direto no painel, sem e-mail)
# ═══════════════════════════════════════════════════════════
def processar_upload_manual(item: Dict, cfg: Dict, areas: List[str],
                            stats: Estatisticas) -> None:
    """
    Processa um currículo enviado manualmente no painel (botão "Enviar currículo", sem passar por
    e-mail). Como todo currículo, entra primeiro no Banco de Talentos e é qualificado pela IA, exatamente como os
    e-mails. Se o RH escolheu uma vaga ao enviar, o candidato é atribuído a ela em nome dele e o setor, a função e o
    nível do currículo são os da vaga (o RH já decidiu que ele serve); o resto da qualificação, a nota inclusive, é da IA.
    Não há avaliação contra a vaga.
    """
    upload_id = item["id"]
    log.info(f"► upload manual {upload_id[:8]} ({item['nome_arquivo']})")

    def _falhar(motivo: str) -> None:
        log.warning(f"  {motivo}")
        bd.atualizar_upload_manual(upload_id, {
            "status": "erro", "detalhe_erro": motivo[:400], "processado_em": bd.agora(),
        })

    conteudo = bd.baixar_arquivo(item["storage_path"])
    if not conteudo:
        _falhar("Não foi possível ler o arquivo enviado")
        return

    # Reincidência: se este arquivo já foi lido, nada é lido de novo; o envio serve para achar o cadastro que já existe
    hash_arquivo = gerar_hash_arquivo(conteudo)
    dono = bd.buscar_candidato_por_arquivo(hash_arquivo)
    motivo = _motivo_para_nao_reler(dono) if dono else None
    if motivo:
        stats.duplicados_detectados += 1
        log.info(f"  Mesmo arquivo já lido — não relido ({motivo})")
        resultado = {"candidato_id": dono["id"], "novo": False, "analise": None, "ignorado": motivo}
    else:
        texto, ocr = extrator.extrair(conteudo, item["tipo_mime"])
        if not texto or len(texto.strip()) < 100:
            _falhar(f"Arquivo '{item['nome_arquivo']}' sem texto legível")
            return
        texto = limpar_texto(texto)

        modelo_cls = modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
        try:
            ident, _ = ia.identificar_curriculo(texto, modelo_cls, _nomes_das_regioes())
        except Exception as e:
            _falhar(f"Falha na identificação: {e}")
            return

        if not ident or not ident.get("e_curriculo"):
            _falhar("Conteúdo não identificado como currículo")
            return

        forcada = None
        if item.get("vaga_id"):
            try:
                forcada = bd.obter_qualificacao_da_vaga(item["vaga_id"])
            except Exception as e:
                log.warning(f"  Não consegui ler a qualificação da vaga; a IA classifica: {type(e).__name__}")
        resultado = _entrar_no_banco(
            texto, ident, cfg, areas, stats, origem_entrada="upload_manual", qualificacao_forcada=forcada,
            curriculo={
                "origem": "upload_manual",
                "storage_path": item["storage_path"],
                "nome_arquivo": item["nome_arquivo"],
                "tipo_mime": item["tipo_mime"],
                "tamanho_bytes": item.get("tamanho_bytes"),
                "ocr_aplicado": ocr,
                "extracao_ok": True,
                "recebido_em": bd.agora(),
                "arquivo_hash": hash_arquivo,
            })
    if not resultado:
        _falhar("Falha ao criar candidato")
        return
    if resultado.get("ignorado") and not resultado.get("candidato_id"):
        _falhar(f"Não importado: {resultado['ignorado']}")          # lista negra
        return
    if not resultado.get("ignorado"):
        stats.curriculos_processados += 1

    candidatura_id = None
    aviso = (f"Este currículo já estava no Banco de Talentos ({resultado['ignorado']}); a análise existente foi mantida."
             if resultado.get("ignorado") else None)
    if item.get("vaga_id"):
        try:
            candidatura_id = bd.atribuir_candidato_vaga(resultado["candidato_id"], item["vaga_id"], item["enviado_por"])
        except Exception as e:
            inicio = f"{aviso} Não foi atribuído à vaga: " if aviso else "Entrou no Banco de Talentos, mas não foi atribuído à vaga: "
            aviso = (inicio + f"{getattr(e, 'message', None) or e}")[:400]
            log.warning(f"  {aviso}")

    bd.atualizar_upload_manual(upload_id, {
        "status": "processado", "candidato_gerado_id": resultado["candidato_id"],
        "candidatura_gerada_id": candidatura_id, "detalhe_erro": aviso, "processado_em": bd.agora(),
    })



def processar_uploads_manuais_pendentes(cfg: Dict, areas: List[str], stats: Estatisticas) -> None:
    pendentes = bd.listar_uploads_manuais_pendentes()
    if not pendentes:
        return
    log.info(f"{len(pendentes)} upload(s) manual(is) pendente(s)")
    for item in pendentes:
        try:
            processar_upload_manual(item, cfg, areas, stats)
        except Exception as e:
            log.error(f"  Erro inesperado: {e}", exc_info=True)
            bd.atualizar_upload_manual(item["id"], {
                "status": "erro", "detalhe_erro": str(e)[:400], "processado_em": bd.agora(),
            })


def processar_uploads_manuais() -> Dict:
    """
    Só os currículos enviados manualmente no painel, sem ler e-mail nenhum
    (python main.py --uploads-manuais). Sem nada pendente não registra execução,
    para poder rodar com frequência.
    """
    ia.resetar_custo()
    stats = Estatisticas()
    pendentes = bd.listar_uploads_manuais_pendentes()
    if not pendentes:
        log.info("Nenhum upload manual pendente")
        return stats.como_dict()

    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — nada será gravado")

    exec_id = bd.iniciar_execucao()
    erro_fatal = None
    try:
        cfg = bd.carregar_configuracoes()
        processar_uploads_manuais_pendentes(cfg, bd.listar_areas(), stats)
    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)
    finally:
        bd.finalizar_execucao(exec_id, stats.como_dict(),
                              sucesso=erro_fatal is None, erro=erro_fatal)

    log.info(f"Currículos processados : {stats.curriculos_processados} de {len(pendentes)}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    return stats.como_dict()


# ═══════════════════════════════════════════════════════════
#  EXECUÇÃO COMPLETA
# ═══════════════════════════════════════════════════════════
def reler_caixa(limite: int = 0, ate_uid: int = 0) -> Dict:
    """
    Relê a caixa de entrada desde IMAP_DESDE, lidos e não lidos, e põe no Banco de Talentos o que ainda não
    estiver lá (python main.py --reler-caixa --desde AAAA-MM-DD [--ate-uid N]). Serve para recarregar o banco
    depois de zerá-lo.

      • não marca nada como lido: a caixa não é alterada
      • pode ser repetido (e retomado, se cair): o e-mail já importado é reconhecido pelo Message-ID e ignorado
      • sem data inicial recusa rodar, para nunca varrer a caixa inteira
      • limite / ate_uid vêm só da linha de comando; o LIMITE_EMAILS do .env (que serve à execução diária) não vale aqui
      • o marcador de progresso só avança (nunca recua): a execução diária segue dele
    """
    if not mail.IMAP_DESDE:
        raise RuntimeError("--reler-caixa exige uma data inicial: use --desde AAAA-MM-DD (ou IMAP_DESDE).")

    ia.resetar_custo()
    stats = Estatisticas()
    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — nada será gravado")
    exec_id = bd.iniciar_execucao()
    erro_fatal = None

    try:
        cfg = bd.carregar_configuracoes()
        areas = bd.listar_areas()
        mensagens, validade = mail.buscar_novos(limite, todas=True, ate_uid=ate_uid)
        stats.emails_lidos = len(mensagens)

        ultimo_uid = None      # até onde tudo foi tratado, sem falha no meio
        avancar = True
        for i, msg in enumerate(mensagens, 1):
            log.info(f"[{i}/{len(mensagens)}]")
            tratada = True
            try:
                processar_mensagem(msg, cfg, areas, stats)
            except Exception as e:
                log.error(f"  Erro inesperado: {e}", exc_info=True)
                try:
                    _registrar_excecao(msg, "erro_processamento", str(e)[:400], stats)
                except Exception:
                    tratada = False
            if not tratada:
                avancar = False
            elif avancar:
                ultimo_uid = int(msg["uid"])

        if ultimo_uid:
            atual, validade_atual = bd.obter_cursor_imap()
            if ultimo_uid > atual or validade != validade_atual:
                bd.salvar_cursor_imap(ultimo_uid, validade)
    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)
    finally:
        bd.finalizar_execucao(exec_id, stats.como_dict(),
                              sucesso=erro_fatal is None, erro=erro_fatal)

    log.info(f"E-mails lidos          : {stats.emails_lidos}")
    log.info(f"Currículos processados : {stats.curriculos_processados}")
    log.info(f"Exceções geradas       : {stats.excecoes_geradas}")
    log.info(f"Reenvios (já no banco) : {stats.duplicados_detectados}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    return stats.como_dict()


def executar() -> Dict:
    """Execução completa do pipeline diário."""
    log.info("=" * 60)
    log.info("RECRUTEI — Banco de Talentos")
    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — nada será gravado")
    log.info("=" * 60)

    ia.resetar_custo()
    stats = Estatisticas()
    exec_id = bd.iniciar_execucao()
    erro_fatal = None

    try:
        cfg = bd.carregar_configuracoes()
        faixa = faixa_segunda_avaliacao(cfg)
        log.info("Segunda avaliação (para vaga): " +
                 (f"notas de {faixa[0]} a {faixa[1]}" if faixa else "desativada"))
        areas = bd.listar_areas()

        # (Re)análises pedidas: candidatos migrados, currículo reenviado, botão do painel
        try:
            reanalises = bd.listar_reanalises()
            if reanalises:
                log.info("-" * 60)
                reanalisar_pendentes(reanalises, cfg, areas, stats)
        except Exception as e:
            log.error(f"Falha nas reanálises: {e}", exc_info=True)

        # Currículos enviados manualmente no painel, antes dos e-mails novos
        try:
            log.info("-" * 60)
            processar_uploads_manuais_pendentes(cfg, areas, stats)
        except Exception as e:
            log.error(f"Falha nos uploads manuais: {e}", exc_info=True)

        # E-mails de outras áreas ficam não lidos; o marcador de progresso
        # (último UID analisado) evita relê-los a cada execução.
        cursor_uid, cursor_validade = bd.obter_cursor_imap()
        mensagens, validade = mail.buscar_novos(LIMITE_EMAILS, cursor_uid, cursor_validade)
        stats.emails_lidos = len(mensagens)

        if not mensagens:
            log.info("Nenhuma mensagem nova")
        else:
            log.info("-" * 60)
            tratadas = []
            ultimo_uid = None      # até onde tudo foi tratado, sem falha no meio
            avancar = True
            for i, msg in enumerate(mensagens, 1):
                log.info(f"[{i}/{len(mensagens)}]")
                tratada = True
                try:
                    if processar_mensagem(msg, cfg, areas, stats):
                        tratadas.append(msg["uid"])
                except Exception as e:
                    log.error(f"  Erro inesperado: {e}", exc_info=True)
                    try:
                        _registrar_excecao(msg, "erro_processamento", str(e)[:400], stats)
                        if _marcar_lido():
                            tratadas.append(msg["uid"])
                    except Exception:
                        tratada = False   # nem a exceção foi registrada: tentar de novo
                if not tratada:
                    avancar = False
                elif avancar:
                    ultimo_uid = int(msg["uid"])

            mail.marcar_como_lidas(tratadas)
            log.info(f"{len(tratadas)} marcada(s) como lida(s); "
                     f"{len(mensagens) - len(tratadas)} mantida(s) não lida(s)")

            if ultimo_uid:
                try:
                    bd.salvar_cursor_imap(ultimo_uid, validade)
                except Exception as e:
                    log.warning(f"Não consegui salvar o marcador de progresso: {e}")

        # Manutenção: partições da auditoria e arquivos de dados já excluídos.
        # Nada é inativado nem apagado sozinho: isso é decisão do RH na sanitização.
        log.info("-" * 60)
        log.info("Executando manutenção")
        manut = bd.executar_manutencao()
        if manut:
            log.info(f"  Arquivos removidos do Storage: {manut.get('arquivos_removidos', 0)}")

        # Sanitização: gera a lista de sugestões quando o intervalo (2 meses) venceu e avisa o RH
        try:
            sanitizacao.verificar_e_gerar()
        except Exception as e:
            log.error(f"Falha na sanitização: {e}", exc_info=True)

    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)

    finally:
        bd.finalizar_execucao(exec_id, stats.como_dict(),
                              sucesso=erro_fatal is None, erro=erro_fatal)

    log.info("=" * 60)
    log.info(f"E-mails lidos          : {stats.emails_lidos}")
    log.info(f"Currículos processados : {stats.curriculos_processados}")
    log.info(f"Análises/avaliações    : {stats.avaliacoes_realizadas}")
    log.info(f"Exceções geradas       : {stats.excecoes_geradas}")
    log.info(f"Reenvios (já no banco) : {stats.duplicados_detectados}")
    log.info(f"Remetentes bloqueados  : {stats.bloqueados}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    log.info("=" * 60)

    return stats.como_dict()
