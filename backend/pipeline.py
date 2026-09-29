"""Orquestração: e-mail → extração → identificação → Banco de Talentos → análise da IA.

Todo currículo entra PRIMEIRO no Banco de Talentos, independente de vaga, já qualificado pela IA (setor, função, nível
e nota). Na vaga não há IA escolhendo currículo: o RH pede "Selecionar CVs" e o banco filtra, por SQL, os currículos com o
setor, a função e o nível da vaga. A única exceção é o currículo enviado à mão a partir de uma vaga: setor, função e nível
são os da vaga (um humano já decidiu a compatibilidade); o resto da qualificação é o de sempre.
"""
from datetime import date, datetime, timezone
from typing import Dict, List, Optional, Tuple
import uuid

import database as bd
import leitor_email as mail
import extrator
import ia
import sanitizacao
import agenda
import status_robo
from config import (
    FORMATOS_ACEITOS, TAMANHO_MAXIMO_ANEXO, TAMANHO_MINIMO_ANEXO, TAMANHO_MINIMO_DOCUMENTO, LIMITE_EMAILS, REENVIO_DIAS_MINIMO,
    MODO_SIMULACAO, MODELO_CLASSIFICACAO_PADRAO, MODELO_AVALIACAO_PADRAO,
    CONFIANCA_MINIMA_PADRAO, VERSAO_PROMPT_ANALISE, PORTAIS_DE_CURRICULO, ASSUNTOS_BLOQUEADOS, log,
)
from utils import (
    extrair_telefone, extrair_email, gerar_hash_identidade, gerar_hash_arquivo,
    detectar_link_google_docs, limpar_texto, extrair_idade, extrair_nascimento, separar_cidade_uf,
    detectar_regiao, normalizar_texto, html_para_texto, parece_curriculo, link_do_html, primeiro_nome,
)


class Estatisticas:
    def __init__(self):
        self.emails_lidos = 0
        self.curriculos_processados = 0
        self.excecoes_geradas = 0
        self.avaliacoes_realizadas = 0      # análises do candidato + avaliações para vaga
        self.duplicados_detectados = 0      # currículo de quem já estava no banco
        self.bloqueados = 0
        self.interrompida = False           # a pausa de emergência da IA parou a execução no meio

    def como_dict(self) -> Dict:
        return {
            "emails_lidos": self.emails_lidos,
            "curriculos_processados": self.curriculos_processados,
            "excecoes_geradas": self.excecoes_geradas,
            "avaliacoes_realizadas": self.avaliacoes_realizadas,
            "duplicados_detectados": self.duplicados_detectados,
            "custo_estimado_usd": round(ia.custo_total["usd"], 4),
        }


MOTIVO_PAUSA = "Interrompida: envio à IA pausado no painel (Configurações → Zona de perigo)"


def _ia_liberada() -> bool:
    """False (e avisa no log) se o administrador pausou todo envio à IA: a rotina não lê e-mail nem analisa nada."""
    if not bd.ia_pausada():
        return True
    log.warning("ENVIO À IA PAUSADO no painel (Configurações → Zona de perigo): nada é lido nem analisado. "
                "Os e-mails e os pedidos pendentes ficam como estão até a pausa ser desfeita.")
    return False


def _parar_por_pausa(stats: "Estatisticas", onde: str) -> None:
    """Chamado quando a IA é pausada com a execução em andamento: o item em curso fica como estava e o laço termina."""
    stats.interrompida = True
    log.warning(f"  Envio à IA pausado no painel: paro {onde}. O que falta continua pendente.")


def _finalizar_execucao(exec_id: Optional[str], stats: "Estatisticas", erro_fatal: Optional[str]) -> None:
    """Fecha o registro da execução; parada pela pausa da IA conta como não concluída, com o motivo."""
    bd.finalizar_execucao(exec_id, stats.como_dict(),
                          sucesso=erro_fatal is None and not stats.interrompida,
                          erro=erro_fatal or (MOTIVO_PAUSA if stats.interrompida else None))


def _registrar_excecao(msg: Dict, tipo: str, detalhe: str,
                       stats: Estatisticas, nome_arquivo: str = None,
                       excecao_id: str = None, texto: str = None, link_curriculo: str = None) -> None:
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
    # o link só vai quando existe: a coluna é da 039 e um e-mail comum não precisa dela
    extra = {"link_curriculo": link_curriculo} if link_curriculo else {}
    if excecao_id:
        bd.atualizar_excecao(excecao_id, {
            "tipo": tipo,
            "detalhe_erro": detalhe,
            "nome_arquivo": nome_arquivo,
            "email_corpo": _corpo_para_exibir(msg),
            "texto_extraido": texto,
            "reprocessar_solicitado_em": None,   # a tentativa terminou; não reentra sozinha
            **extra,
        })
        return
    remetente = bd.obter_ou_criar_remetente(msg["remetente"])
    bd.registrar_excecao({
        "remetente_id": remetente["id"] if remetente["id"] != "simulado" else None,
        "email_remetente": msg["remetente"],
        "email_message_id": msg.get("message_id"),
        "email_assunto": msg.get("assunto"),
        "email_corpo": _corpo_para_exibir(msg),
        "texto_extraido": texto,
        "tipo": tipo,
        "detalhe_erro": detalhe,
        "nome_arquivo": nome_arquivo,
        "recebido_em": msg.get("recebido_em") or bd.agora(),
        **extra,
    })
    stats.excecoes_geradas += 1


def _detalhe_nao_curriculo(ident: Dict) -> str:
    """Motivo mostrado na fila. Quando a IA reconhece o tipo do anexo (laudo, pagamento, phishing...), o texto começa com
    "Anexo de ..." — o painel usa esse início para destacar o aviso (frontend/js/vagas.js, avisoDoAnexo)."""
    tipo = ia.TIPOS_DOCUMENTO.get(ident.get("tipo_documento"))
    return f"Anexo de {tipo} — não é currículo" if tipo else "Conteúdo não identificado como currículo"


def _corpo_para_exibir(msg: Dict) -> Optional[str]:
    """O que o RH lê em "Ver e-mail": o corpo em texto, com o endereço dos links (o HTML cru é ilegível). Sem o leitor, o corpo como veio."""
    legivel = msg.get("corpo_com_links")
    return legivel if legivel is not None else msg.get("corpo")


def _portal_de_curriculos(remetente: str) -> Optional[Dict]:
    """Dados da plataforma de vagas ({"nome", "link"}, config.PORTAIS_DE_CURRICULO) se o e-mail vem dela; None para candidato comum."""
    dominio = (remetente or "").rsplit("@", 1)[-1].lower()
    return next((p for d, p in PORTAIS_DE_CURRICULO.items() if dominio == d or dominio.endswith("." + d)), None)


_valores_invalidos_avisados: set = set()


def _numero_da_config(cfg: Optional[Dict], chave: str, padrao: int, minimo: int, maximo: int) -> int:
    """Inteiro de Configurações dentro de [minimo, maximo]; ausente ou fora disso vale o padrão (com um aviso por valor, no log)."""
    bruto = (cfg or {}).get(chave)
    if bruto in (None, ""):
        return padrao
    try:
        valor = int(float(bruto))
        if minimo <= valor <= maximo:
            return valor
    except (TypeError, ValueError, OverflowError):
        pass
    if (chave, str(bruto)) not in _valores_invalidos_avisados:
        _valores_invalidos_avisados.add((chave, str(bruto)))
        log.warning(f"Configuração {chave} inválida ({bruto!r}; use de {minimo} a {maximo}): usando {padrao}")
    return padrao


def _prefixo_telefone(cfg: Optional[Dict]) -> Tuple[str, str]:
    """(DDI, DDD) que completam telefone sem eles: de Configurações (ddi_padrao, ddd_padrao) quando válidos, senão 55 e 61."""
    saida = []
    for chave, padrao, tamanhos in (("ddi_padrao", "55", (1, 2, 3)), ("ddd_padrao", "61", (2,))):
        bruto = str((cfg or {}).get(chave) if (cfg or {}).get(chave) is not None else "").strip()
        if bruto.isdigit() and len(bruto) in tamanhos:
            saida.append(bruto)
            continue
        if bruto and (chave, bruto) not in _valores_invalidos_avisados:
            _valores_invalidos_avisados.add((chave, bruto))
            log.warning(f"Configuração {chave} inválida ({bruto!r}): usando {padrao}")
        saida.append(padrao)
    return saida[0], saida[1]


def _tamanho_minimo(anexo: Dict, cfg: Optional[Dict] = None) -> int:
    """
    Imagem pequena é logotipo/ícone de assinatura de e-mail: o piso é o de Configurações (tamanho_minimo_anexo_bytes, padrão 10 KB).
    Documento pequeno pode ser um currículo simples: o piso dele é fixo (config.py), de propósito, para ninguém recusar um PDF só de texto.
    """
    if anexo["tipo_mime"].startswith("image/"):
        return _numero_da_config(cfg, "tamanho_minimo_anexo_bytes", TAMANHO_MINIMO_ANEXO, 1024, 1024 * 1024)
    return TAMANHO_MINIMO_DOCUMENTO


def _anexos_validos(msg: Dict, cfg: Optional[Dict] = None) -> List[Dict]:
    """Os anexos que podem ser um currículo: assinatura do arquivo confere com o tipo e tamanho acima do piso do tipo. PDF antes dos demais."""
    validos = [a for a in msg["anexos"] if a["tamanho"] >= _tamanho_minimo(a, cfg) and a.get("assinatura_ok")]
    validos.sort(key=lambda a: 0 if a["tipo_mime"] == "application/pdf" else 1)
    return validos


def _escolher_anexo(msg: Dict, cfg: Optional[Dict] = None) -> Optional[Dict]:
    """O primeiro anexo que será tentado como currículo (o hash prévio, para não reler o mesmo arquivo, sai dele). None se não houver."""
    validos = _anexos_validos(msg, cfg)
    return validos[0] if validos else None


def _curriculo_no_corpo(msg: Dict) -> Optional[str]:
    """
    O currículo escrito no próprio e-mail (sem anexo nem link: comum em quem manda pelo celular). Só vale se o texto do
    corpo tem cara de currículo (parece_curriculo); a IA ainda confirma depois, em identificar_curriculo. None = não é.
    """
    corpo = msg.get("corpo_texto")
    if corpo is None:                                  # mensagem montada sem o leitor de e-mail
        corpo = html_para_texto(msg.get("corpo"))
    texto = limpar_texto(corpo)
    return texto if parece_curriculo(texto) else None


def _obter_texto(msg: Dict, cfg: Optional[Dict] = None) -> tuple:
    """
    Busca o currículo no anexo, em link do Google Docs ou, na falta dos dois, no texto do próprio e-mail.
    Retorna (texto, ocr_aplicado, anexo, origem, erro)
    """
    resultado = _obter_texto_de_arquivo(msg, cfg)
    if resultado[4] is None or _portal_de_curriculos(msg["remetente"]):     # o corpo de um aviso de portal não é currículo
        return resultado
    texto = _curriculo_no_corpo(msg)
    if texto:
        log.info(f"  Sem arquivo legível ({resultado[4][0]}): o currículo está no corpo do e-mail")
        return texto, False, None, "corpo_email", None
    return resultado


def _obter_texto_de_arquivo(msg: Dict, cfg: Optional[Dict] = None) -> tuple:
    """
    Busca o currículo no anexo ou em link do Google Docs.
    Retorna (texto, ocr_aplicado, anexo, origem, erro)
    """
    # 1. Anexo válido. Com mais de um (ex.: um PDF sem texto e um DOCX), vale o primeiro que tiver texto legível; só se NENHUM
    #    tiver é que vira exceção, com o motivo do primeiro tentado.
    primeira_falha = None
    for anexo in _anexos_validos(msg, cfg):
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

    # 2. Link de Google Docs no corpo. O texto vem do link; o ARQUIVO também é baixado e devolvido como o anexo, para ser
    #    guardado no Storage (sem ele o painel não tem o que abrir). Se o arquivo não puder ser baixado, o currículo entra sem ele.
    #    Vale também quando o anexo não abriu: quem anexa o arquivo errado e cola o link do certo não pode ficar de fora.
    link = detectar_link_google_docs(msg.get("corpo", ""))
    if link:
        texto, ocr = extrator.extrair_google_docs(link)
        if texto and len(texto.strip()) >= 100:
            return texto, ocr, extrator.arquivo_do_google_docs(link), "google_docs", None

    # Nem o anexo nem o link deram texto: o motivo é o do anexo (o primeiro tentado); sem anexo, o do link
    if primeira_falha:
        anexo, ocr = primeira_falha
        tipo_erro = "ocr_falhou" if ocr else "arquivo_corrompido"
        return None, False, anexo, None, (tipo_erro, f"Arquivo '{anexo['nome']}' sem texto legível")
    if link:
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

    # Anexo em formato aceito, mas maior que o limite: não é "sem anexo" (o RH abre o arquivo no e-mail)
    grandes = msg.get("anexos_grandes")
    if grandes:
        g = grandes[0]
        return None, False, None, None, (
            "formato_invalido",
            f"Anexo '{g['nome']}' grande demais ({g['tamanho'] / 1024 / 1024:.0f} MB; o limite é {TAMANHO_MAXIMO_ANEXO // 1024 // 1024} MB)")

    return None, False, None, None, ("sem_anexo", "E-mail sem anexo nem link de currículo")


def modelo_configurado(cfg: Dict, chave: str, padrao: str) -> str:
    """Modelo escolhido em Configurações; ausente ou vazio usa o padrão."""
    valor = cfg.get(chave)
    return valor.strip() if isinstance(valor, str) and valor.strip() else padrao


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
    except ia.IAPausada:
        raise
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


def _sexo_pelo_nome(nome: Optional[str], cfg: Dict) -> Optional[str]:
    """Estimativa da IA pelo PRIMEIRO nome (só ele sai do sistema). None = não decidiu ou não deu. A pausa da IA sobe."""
    primeiro = primeiro_nome(nome)
    if not primeiro:
        return None
    modelo = modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
    try:
        return ia.inferir_sexo_pelo_nome([primeiro], modelo)[0].get(primeiro)
    except ia.IAPausada:
        raise
    except Exception as e:                      # nunca derruba a importação do currículo: fica sem sexo e o RH (ou --sexo-pelo-nome) completa
        log.warning(f"  Não consegui estimar o sexo pelo nome: {type(e).__name__}")
        return None


def _sexo_do_cadastro(nome: Optional[str], sexo_do_curriculo: Optional[str], existente: Optional[Dict], cfg: Dict) -> Dict:
    """
    sexo e sexo_origem que vão para o cadastro (só estatística e comparação, nunca critério de seleção):
      • o RH já decidiu (sexo_origem "manual", inclusive deixar em branco) → não mexe em nada
      • o currículo informa                                                 → sexo e "informado" (vale mais que uma estimativa)
      • o cadastro já tem sexo                                              → não estima de novo
      • senão a IA estima pelo primeiro nome                                → sexo e "ia_nome"; se não decidir, fica em branco
    """
    if existente and existente.get("sexo_origem") == "manual":
        return {}
    if sexo_do_curriculo:
        return {"sexo": sexo_do_curriculo, "sexo_origem": "informado"}
    if existente and existente.get("sexo"):
        return {}
    estimado = _sexo_pelo_nome(nome, cfg)
    return {"sexo": estimado, "sexo_origem": "ia_nome"} if estimado else {}


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
    except ia.IAPausada:
        raise
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

    # A IA não soube o setor: fica com Vendas ou Logística, o que mais se parecer com as experiências do currículo (sem olhar
    # sexo nem dado pessoal). Sem semelhança clara com nenhum dos dois, segue para a revisão manual.
    if not analise.get("area_sugerida") and not qualificacao_forcada:
        palpite = ia.area_pela_experiencia(texto, vocabulario["funcoes"])
        if palpite:
            analise["area_sugerida"], analise["cargo_sugerido"] = palpite
            if not analise.get("nivel_sugerido") and any(n["codigo"] == "junior" for n in vocabulario["niveis"]):
                analise["nivel_sugerido"] = "junior"
            log.info(f"  IA sem setor: encaminhado por semelhança com a experiência → {palpite[0]} / {palpite[1]}")

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
    anterior e o candidato foi sanitizado (inativo ou com os dados excluídos). Nunca para quem está bloqueado nem
    para quem tem retenção permanente (contratado).
    """
    if candidato.get("lista_negra"):
        return "candidato bloqueado"
    if candidato.get("retencao_permanente"):
        return "candidato com retenção permanente"
    # Cadastro ATIVO sem nenhum currículo é sobra de uma gravação interrompida (queda, deploy no meio do e-mail): não há currículo a
    # "não reler". Sem esta saída o e-mail reenviado seria ignorado como "já está no banco" e a pessoa ficaria sem currículo para sempre.
    if candidato.get("status_banco") == "ativo" and not bd.obter_curriculo_atual(candidato["id"]):
        return None
    if candidato.get("status_banco") not in ("inativo", "expurgado"):
        ultima = bd.ultima_importacao(candidato["id"])
        lido = f" (lido há {(datetime.now(timezone.utc) - ultima).days} dia(s))" if ultima else ""
        return f"já está no banco{lido}; só é relido depois de sanitizado"
    # Os 30 dias contam da SAÍDA do banco (inativação; o expurgo mantém essa data). Sem ela, da última importação.
    saida = _como_data(candidato.get("inativado_em")) or bd.ultima_importacao(candidato["id"])
    dias = (datetime.now(timezone.utc) - saida).days if saida else None
    if dias is not None and dias < REENVIO_DIAS_MINIMO:
        return f"saiu do banco há {dias} dia(s); só é relido depois de {REENVIO_DIAS_MINIMO} dias"
    return None


def _como_data(valor) -> Optional[datetime]:
    """Data que veio do banco (texto ISO) ou já pronta; None se vazia."""
    if not valor:
        return None
    if isinstance(valor, datetime):
        return valor
    return datetime.fromisoformat(str(valor).replace("Z", "+00:00"))


def _entrar_no_banco(texto: str, ident: Dict, cfg: Dict, areas: List[str], stats: Estatisticas, *,
                     origem_entrada: str, curriculo: Dict, arquivo: Optional[Dict] = None,
                     email_padrao: Optional[str] = None, qualificacao_forcada: Optional[Dict] = None) -> Optional[Dict]:
    """
    Coloca o currículo no Banco de Talentos e dispara a análise da IA.

      • pessoa nova            → cria o candidato ("ativo")
      • pessoa que já está lá  → NÃO é lida de novo (regra de reincidência). Só quando passaram 30 dias da importação
                                 anterior E ela foi sanitizada: o currículo vira a versão ATUAL do mesmo candidato,
                                 a análise é refeita e ele volta a "ativo"
      • e-mail bloqueado       → ignorado
    curriculo: colunas da tabela curriculos (sem candidato_id/texto). arquivo: {"conteudo","tipo_mime"} a subir
    ao Storage (e-mail); no upload manual o arquivo já está lá e curriculo traz o storage_path.
    Devolve {"candidato_id", "novo", "analise"[, "ignorado": motivo]} ou None se não conseguiu gravar o candidato.
    Com "ignorado", nada foi gravado (candidato_id é o do cadastro que já existia, ou None se o e-mail está bloqueado).
    """
    nome = ident.get("nome_candidato")
    telefone = extrair_telefone(texto, *_prefixo_telefone(cfg))
    email_cand = extrair_email(texto) or email_padrao
    hash_id = gerar_hash_identidade(nome, telefone)

    # Bloqueios: vale também o e-mail que consta no próprio currículo (a pessoa pode escrever de outro endereço)
    if email_cand and bd.remetente_bloqueado(email_cand):
        log.info("  E-mail do currículo está bloqueado — ignorando")
        return {"candidato_id": None, "novo": False, "analise": None, "ignorado": "e-mail bloqueado"}

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
    perfil = _campos_de_perfil(texto, _perfil_do_curriculo(texto, cfg))
    dados = {"nome": nome, "telefone": telefone, "telefone_e164": telefone, "email": email_cand,
             "cidade": cidade, "uf": uf, **regiao, **perfil}
    dados.pop("sexo", None)
    dados.update(_sexo_do_cadastro(nome, perfil.get("sexo"), existente, cfg))     # currículo, estimativa pelo nome ou decisão do RH
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

    # Assunto de golpe conhecido (boleto/cobrança falsa): o remetente muda a cada e-mail, o assunto não
    assunto_normalizado = normalizar_texto(msg.get("assunto"))
    if any(padrao in assunto_normalizado for padrao in ASSUNTOS_BLOQUEADOS):
        log.info("  Assunto bloqueado — ignorando")
        stats.bloqueados += 1
        return _marcar_lido()

    # Reincidência: o mesmo ARQUIVO não é lido de novo, seja qual for a vaga (antes de gastar extração, OCR e IA)
    anexo_previsto = _escolher_anexo(msg, cfg)
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
    texto, ocr, anexo, origem, erro = _obter_texto(msg, cfg)
    if anexo and (not hash_arquivo or anexo is not anexo_previsto):   # link do Drive, ou outro anexo que não o previsto: a impressão digital é do arquivo lido
        hash_arquivo = gerar_hash_arquivo(anexo["conteudo"])
    portal = _portal_de_curriculos(msg["remetente"])          # o remetente é a plataforma, não o candidato: as regras "por remetente" não valem
    if erro:
        link_do_curriculo = None
        if erro[0] == "sem_anexo" and portal:
            # o aviso traz o link do currículo na plataforma: vira o botão "Abrir currículo" (sem o link, o RH procura em "Ver e-mail")
            link_do_curriculo = link_do_html(msg.get("corpo"), portal["link"])
            onde = 'Clique em "Abrir currículo"' if link_do_curriculo else f'Em "Ver e-mail", procure o link "{portal["link"]}"'
            erro = ("sem_anexo", f'Aviso do {portal["nome"]}: o currículo está na plataforma, não no e-mail. '
                                 f'{onde}, baixe o currículo lá e envie por "Enviar currículo".')
        # E-mail vazio ou "segue em anexo" sem anexo de quem JÁ tem currículo no banco (o currículo veio em outra mensagem): não há o
        # que o RH resolver, então não entra na fila. Num reprocessamento, a exceção existente é encerrada.
        if erro[0] == "sem_anexo" and not portal and bd.remetente_tem_curriculo(msg["remetente"]):
            log.info("  E-mail sem currículo de quem já tem currículo no banco — não vira exceção")
            if excecao_id:
                bd.atualizar_excecao(excecao_id, {"status": "revisado", "reprocessar_solicitado_em": None,
                                                  "detalhe_erro": "Este remetente já tem currículo no Banco de Talentos."})
            return _marcar_lido()
        _registrar_excecao(msg, erro[0], erro[1], stats,
                           anexo["nome"] if anexo else None, excecao_id, link_curriculo=link_do_curriculo)
        return _marcar_lido()

    texto = limpar_texto(texto)

    # ── Identificação (Haiku): é currículo? quem é? ──
    modelo_cls = modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
    try:
        ident, _ = ia.identificar_curriculo(texto, modelo_cls, _nomes_das_regioes())
    except ia.IAPausada:
        raise                       # não é defeito deste e-mail: continua não lido, sem exceção registrada
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
        _registrar_excecao(msg, "nao_e_curriculo", _detalhe_nao_curriculo(ident), stats,
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
    # Quem mandou o e-mail vazio (ou o anexo que não abriu) e logo depois o currículo certo: as falhas de antes deixam de valer
    try:
        encerradas = 0 if portal else bd.encerrar_excecoes_do_remetente(msg["remetente"], msg.get("recebido_em") or bd.agora())
        if encerradas:
            log.info(f"  {encerradas} exceção(ões) anterior(es) do mesmo remetente encerrada(s): o currículo dele entrou")
    except Exception as e:                                # nunca desfaz um currículo que já entrou
        log.warning(f"  Não consegui encerrar as exceções anteriores do remetente: {type(e).__name__}")
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
        if cand.get("sexo_origem") == "manual":
            vazios.pop("sexo", None)                # o RH deixou em branco de propósito: o currículo não refaz a decisão dele
        if "sexo" in vazios:
            vazios["sexo_origem"] = "informado"
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
        except ia.IAPausada:
            _parar_por_pausa(stats, "as reanálises")
            break
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
    if not _ia_liberada():
        return stats.como_dict()
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
        _finalizar_execucao(exec_id, stats, erro_fatal)

    log.info(f"Análises realizadas    : {stats.avaliacoes_realizadas} de {len(pendentes)}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    return stats.como_dict()


def preencher_sexo_pelo_nome(limite: int = 0) -> Dict:
    """
    Estima, pelo PRIMEIRO nome, o sexo de quem está no banco sem sexo (python main.py --sexo-pelo-nome; --limite N faz só N;
    --simular conta sem gravar). O limite vem só da linha de comando: o LIMITE_EMAILS do .env serve à leitura de e-mails e não vale aqui. Serve à estatística de cadastro (quantos currículos de mulheres e de homens chegam e são
    contratados), nunca à seleção. Só a IA vê o primeiro nome, em lotes de 50; nome ambíguo fica em branco. Quem o RH já
    decidiu (inclusive deixando em branco) não entra, e a decisão dele nunca é refeita. Pode ser repetido: só pega quem falta.
    Sem nada para estimar não registra execução. Nomes não vão para o log, só contagens.
    """
    ia.resetar_custo()
    stats = Estatisticas()
    if not _ia_liberada():
        return stats.como_dict()
    pendentes = bd.listar_candidatos_sem_sexo(limite)
    if not pendentes:
        log.info("Nenhum candidato sem sexo para estimar")
        return stats.como_dict()

    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — nada será gravado")
    exec_id = bd.iniciar_execucao()
    erro_fatal = None
    feminino = masculino = indecisos = perdidos = 0
    ids_por_nome: Dict[str, List[str]] = {}         # "maria" (sem acento nem caixa) -> candidatos
    como_veio: Dict[str, str] = {}                  # "maria" -> "Maria" (o que vai à IA)
    for cand in pendentes:
        primeiro = primeiro_nome(cand.get("nome"))
        if primeiro:
            chave = normalizar_texto(primeiro)
            ids_por_nome.setdefault(chave, []).append(cand["id"])
            como_veio.setdefault(chave, primeiro)
        else:
            indecisos += 1                          # só inicial ou nome que não dá para ler: nada a estimar
    try:
        modelo = modelo_configurado(bd.carregar_configuracoes(), "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
        chaves = sorted(ids_por_nome)
        log.info(f"{len(pendentes)} candidato(s) sem sexo; {len(chaves)} primeiro(s) nome(s) distinto(s)")
        for i in range(0, len(chaves), ia.LOTE_SEXO_PELO_NOME):         # grava a cada lote: uma pausa no meio não joga fora o que já veio
            lote = chaves[i:i + ia.LOTE_SEXO_PELO_NOME]
            sexos, _ = ia.inferir_sexo_pelo_nome([como_veio[k] for k in lote], modelo)
            sexo_por_chave = {normalizar_texto(n): s for n, s in sexos.items()}
            for chave in lote:
                sexo = sexo_por_chave.get(chave)
                for candidato_id in ids_por_nome[chave]:
                    if not sexo:
                        indecisos += 1
                    elif bd.gravar_sexo_estimado(candidato_id, sexo):
                        stats.avaliacoes_realizadas += 1
                        feminino += sexo == "feminino"
                        masculino += sexo == "masculino"
                    else:
                        perdidos += 1               # o RH mexeu no meio do caminho: a decisão dele vale
    except ia.IAPausada:
        _parar_por_pausa(stats, "a estimativa do sexo")
    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)
    finally:
        _finalizar_execucao(exec_id, stats, erro_fatal)

    log.info(f"Sexo estimado          : {stats.avaliacoes_realizadas} (feminino {feminino}, masculino {masculino})")
    log.info(f"Sem decisão da IA      : {indecisos} (nome ambíguo ou ilegível: o RH define à mão)")
    if perdidos:
        log.info(f"Já preenchidos pelo RH : {perdidos} (não foram alterados)")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    return stats.como_dict()


# ═══════════════════════════════════════════════════════════
#  AVALIAÇÃO PARA UMA VAGA — só depois que o RH atribui o candidato a ela
# ═══════════════════════════════════════════════════════════
def _avaliar_e_salvar(cand_id: str, texto: str, vaga: Dict, nome: Optional[str],
                      cfg: Dict, stats: Estatisticas, sequencia: int = 1) -> bool:
    """
    Avalia o currículo contra a vaga e grava a nota. False = a IA não devolveu avaliação válida.
    cand_id é o id da CANDIDATURA (o vínculo candidato ↔ vaga).
    """
    modelo_aval = modelo_configurado(cfg, "modelo_ia_avaliacao", MODELO_AVALIACAO_PADRAO)
    try:
        aval, uso = ia.avaliar(texto, vaga, modelo_aval, variacao=1,
                               nome_candidato=nome)
    except ia.IAPausada:
        raise
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
        except ia.IAPausada:
            _parar_por_pausa(stats, "as avaliações")
            break
        except Exception as e:
            log.error(f"  Erro inesperado na avaliação: {e}", exc_info=True)


def reavaliar() -> Dict:
    """
    Só as avaliações para vaga pendentes, sem ler e-mails (python main.py --reavaliar).
    Sem nada pendente não registra execução, para poder rodar com frequência.
    """
    ia.resetar_custo()
    stats = Estatisticas()
    if not _ia_liberada():
        return stats.como_dict()
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
        _finalizar_execucao(exec_id, stats, erro_fatal)

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
    if not _ia_liberada():
        return stats.como_dict()
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
            except ia.IAPausada:
                _parar_por_pausa(stats, "o reprocessamento")     # o pedido de "Reprocessar" continua marcado
                break
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
        _finalizar_execucao(exec_id, stats, erro_fatal)

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
        except ia.IAPausada:
            raise                   # o envio continua "pendente" na fila, sem virar erro
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
        _falhar(f"Não importado: {resultado['ignorado']}")          # e-mail bloqueado
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
        except ia.IAPausada:
            _parar_por_pausa(stats, "os envios manuais")         # o item continua "pendente"
            break
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
    if not _ia_liberada():
        return stats.como_dict()
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
        _finalizar_execucao(exec_id, stats, erro_fatal)

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
    if not _ia_liberada():
        return stats.como_dict()
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
            except ia.IAPausada:
                _parar_por_pausa(stats, "a releitura da caixa")
                break
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
        _finalizar_execucao(exec_id, stats, erro_fatal)

    log.info(f"E-mails lidos          : {stats.emails_lidos}")
    log.info(f"Currículos processados : {stats.curriculos_processados}")
    log.info(f"Exceções geradas       : {stats.excecoes_geradas}")
    log.info(f"Reenvios (já no banco) : {stats.duplicados_detectados}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    return stats.como_dict()


def executar(manutencao: bool = True, limite: Optional[int] = None) -> Dict:
    """
    Uma leitura completa: as (re)análises e os envios manuais pendentes, os e-mails não lidos e (com manutencao=True) a manutenção
    do banco e a conferência da sanitização. O modo contínuo (robo.py) lê a cada poucos minutos e faz a manutenção só uma vez por dia.
    limite: quantos e-mails ler nesta execução (None = LIMITE_EMAILS; 0 = todos). Devolve os números da execução, mais "erro" (texto, ou None) e "interrompida" (a pausa da IA ou um pedido de encerramento parou no meio).
    """
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
        stats.interrompida = not _ia_liberada()     # pausada: nada de e-mail nem de IA, mas a manutenção do banco segue
        cfg = bd.carregar_configuracoes()
        areas = bd.listar_areas()

        # (Re)análises pedidas: candidatos migrados, currículo reenviado, botão do painel
        try:
            reanalises = None if stats.interrompida else bd.listar_reanalises()
            if reanalises:
                log.info("-" * 60)
                reanalisar_pendentes(reanalises, cfg, areas, stats)
        except Exception as e:
            log.error(f"Falha nas reanálises: {e}", exc_info=True)

        # Currículos enviados manualmente no painel, antes dos e-mails novos
        if not stats.interrompida:
            try:
                log.info("-" * 60)
                processar_uploads_manuais_pendentes(cfg, areas, stats)
            except Exception as e:
                log.error(f"Falha nos uploads manuais: {e}", exc_info=True)

        # E-mails de outras áreas ficam não lidos; o marcador de progresso
        # (último UID analisado) evita relê-los a cada execução.
        mensagens, validade = [], None
        if not stats.interrompida:
            cursor_uid, cursor_validade = bd.obter_cursor_imap()
            mensagens, validade = mail.buscar_novos(LIMITE_EMAILS if limite is None else limite, cursor_uid, cursor_validade)
        stats.emails_lidos = len(mensagens)

        if not mensagens:
            if not stats.interrompida:
                log.info("Nenhuma mensagem nova")
        else:
            log.info("-" * 60)
            status_robo.processando(len(mensagens), "Lendo os e-mails da caixa")      # a tela Status mostra "x de y"
            tratadas = []
            ultimo_uid = None      # até onde tudo foi tratado, sem falha no meio
            avancar = True
            for i, msg in enumerate(mensagens, 1):
                if agenda.encerrar.is_set():        # o deploy pediu para parar: o que falta continua não lido e a próxima leitura pega
                    stats.interrompida = True
                    log.warning("Encerramento pedido: paro a leitura. O que falta continua não lido.")
                    break
                log.info(f"[{i}/{len(mensagens)}]")
                tratada = True
                try:
                    if processar_mensagem(msg, cfg, areas, stats):
                        tratadas.append(msg["uid"])
                except ia.IAPausada:
                    # este e-mail e os seguintes continuam não lidos; o marcador só avança até o último tratado
                    _parar_por_pausa(stats, "a leitura dos e-mails")
                    break
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
                status_robo.avancar(i)

            mail.marcar_como_lidas(tratadas)
            log.info(f"{len(tratadas)} marcada(s) como lida(s); "
                     f"{len(mensagens) - len(tratadas)} mantida(s) não lida(s)")

            if ultimo_uid:
                try:
                    bd.salvar_cursor_imap(ultimo_uid, validade)
                except Exception as e:
                    log.warning(f"Não consegui salvar o marcador de progresso: {e}")

        # Manutenção: partições da auditoria, expurgo dos inativos há mais de N meses (o banco apaga os dados pessoais) e
        # remoção dos arquivos de quem foi apagado. Ninguém é inativado aqui: isso é decisão do RH (cadastro ou sanitização).
        if manutencao:
            log.info("-" * 60)
            log.info("Executando manutenção")
            manut = bd.executar_manutencao()
            if manut:
                sanitizacao.registrar_expurgo(manut.get("expurgo"))
                log.info(f"  Arquivos removidos do Storage: {manut.get('arquivos_removidos', 0)}")

            # Sanitização: a cada 7 dias (o banco decide; chamar todo dia é seguro) sugere quem completou 1 mês sem alteração e avisa o RH
            try:
                sanitizacao.verificar_e_gerar()
            except Exception as e:
                log.error(f"Falha na sanitização: {e}", exc_info=True)

    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)

    finally:
        _finalizar_execucao(exec_id, stats, erro_fatal)

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

    return {**stats.como_dict(), "erro": erro_fatal, "interrompida": stats.interrompida}
