"""Orquestração: e-mail → extração → classificação → avaliação → banco."""
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple
import os
import uuid

import database as bd
import leitor_email as mail
import extrator
import ia
from config import (
    FORMATOS_ACEITOS, TAMANHO_MINIMO_ANEXO, LIMITE_EMAILS, SETOR_MARCAR_LIDO,
    MODO_SIMULACAO, MODELO_CLASSIFICACAO_PADRAO, MODELO_AVALIACAO_PADRAO, log,
)
from utils import (
    extrair_telefone, extrair_email, gerar_hash_identidade,
    detectar_link_google_docs, limpar_texto, extrair_idade,
)


class Estatisticas:
    def __init__(self):
        self.emails_lidos = 0
        self.curriculos_processados = 0
        self.excecoes_geradas = 0
        self.avaliacoes_realizadas = 0
        self.duplicados_detectados = 0
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
    existe quando a extração deu certo — "não é currículo" e "vaga indefinida").
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


def _obter_texto(msg: Dict) -> tuple:
    """
    Busca o currículo no anexo ou em link do Google Docs.
    Retorna (texto, ocr_aplicado, anexo, origem, erro)
    """
    # 1. Anexos válidos
    validos = [a for a in msg["anexos"]
               if a["tamanho"] >= TAMANHO_MINIMO_ANEXO and a.get("assinatura_ok")]

    if validos:
        # Prioriza PDF, depois DOCX
        validos.sort(key=lambda a: 0 if a["tipo_mime"] == "application/pdf" else 1)
        anexo = validos[0]
        texto, ocr = extrator.extrair(anexo["conteudo"], anexo["tipo_mime"])

        if not texto or len(texto.strip()) < 100:
            tipo_erro = "ocr_falhou" if ocr else "arquivo_corrompido"
            return None, False, anexo, None, (tipo_erro, f"Arquivo '{anexo['nome']}' sem texto legível")

        origem = {
            "application/pdf": "anexo_pdf",
            "application/msword": "anexo_doc",
        }.get(anexo["tipo_mime"], "anexo_docx")
        if anexo["tipo_mime"].startswith("image/"):
            origem = "anexo_pdf"
        return texto, ocr, anexo, origem, None

    # 2. Link de Google Docs no corpo
    link = detectar_link_google_docs(msg.get("corpo", ""))
    if link:
        texto, ocr = extrator.extrair_google_docs(link)
        if texto and len(texto.strip()) >= 100:
            return texto, ocr, None, "google_docs", None
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
    Faixa de notas que dispara a segunda avaliação; None = desativada.
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


def _perfil_do_curriculo(texto: str, cfg: Dict) -> Dict:
    """
    Dados de busca do currículo, guardados em dados_pessoais para os filtros do painel:
    idade (lida do texto, sem IA), escolaridade, anos de experiência e CNH (Haiku).
    "perfil_v" marca que a IA já extraiu; sem ele o comando --enriquecer tenta de novo.
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
            perfil["perfil_v"] = 1
    except Exception as e:
        log.warning(f"  Não consegui extrair o perfil de busca: {e}")
    return perfil


def _marcar_lido(vaga: Optional[Dict] = None) -> bool:
    """
    Só e-mails classificados no setor SETOR_MARCAR_LIDO viram "lidos"; os demais
    (outros setores, sem vaga, não-currículo, erros) continuam não lidos na caixa.
    SETOR_MARCAR_LIDO vazio = todo e-mail processado é marcado como lido.
    """
    if not SETOR_MARCAR_LIDO:
        return True
    setor = ((vaga or {}).get("setor_nome") or "").strip()
    return setor.casefold() == SETOR_MARCAR_LIDO.casefold()


def processar_mensagem(msg: Dict, vagas: List[Dict], cfg: Dict,
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

    # ── Extração ──
    texto, ocr, anexo, origem, erro = _obter_texto(msg)
    if erro:
        _registrar_excecao(msg, erro[0], erro[1], stats,
                           anexo["nome"] if anexo else None, excecao_id)
        return _marcar_lido()

    texto = limpar_texto(texto)

    # ── Classificação (Haiku) ──
    modelo_cls = modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
    try:
        resultado, _ = ia.classificar(texto, vagas, modelo_cls)
    except Exception as e:
        _registrar_excecao(msg, "erro_processamento", f"Falha na classificação: {e}", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido()

    if not resultado:
        _registrar_excecao(msg, "erro_processamento",
                           "Classificador não retornou resposta válida", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido()

    if not resultado.get("e_curriculo"):
        _registrar_excecao(msg, "nao_e_curriculo",
                           "Conteúdo não identificado como currículo", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido()

    vaga_id = resultado.get("vaga_id")
    vaga = next((v for v in vagas if v["id"] == vaga_id), None)
    if not vaga:
        _registrar_excecao(msg, "vaga_nao_identificada",
                           "Nenhuma vaga aberta corresponde ao perfil", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido()

    log.info(f"  Vaga: {vaga['titulo']} ({resultado.get('aderencia', 0)}% aderência)")

    # ── Dados pessoais ──
    nome = resultado.get("nome_candidato")
    telefone = extrair_telefone(texto)
    email_cand = extrair_email(texto) or msg["remetente"]
    hash_id = gerar_hash_identidade(nome, telefone)

    # ── Duplicata ──
    carencia = int(cfg.get("reincidencia_dias_carencia", 90))
    dup = bd.buscar_duplicata(hash_id, vaga_id, carencia)
    if dup:
        log.info(f"  Reenvio dentro de {carencia} dias — registrado como reincidência")
        stats.duplicados_detectados += 1

    # ── Persistência ──
    remetente = bd.obter_ou_criar_remetente(msg["remetente"])

    candidatura = bd.criar_candidatura({
        "remetente_id": remetente["id"] if remetente["id"] != "simulado" else None,
        "vaga_id": vaga_id,
        "dados_pessoais": {
            "nome": nome,
            "telefone": telefone,
            "telefone_e164": telefone,
            "email": email_cand,
            "cidade": resultado.get("cidade"),
            **_perfil_do_curriculo(texto, cfg),
        },
        "hash_identidade": hash_id,
        "status": "em_analise",
        "aderencia_vaga": resultado.get("aderencia"),
        "email_message_id": msg.get("message_id"),
        "email_assunto": msg.get("assunto"),
        "recebido_em": msg.get("recebido_em") or bd.agora(),
    })
    if not candidatura:
        log.error("  Falha ao criar candidatura")
        _registrar_excecao(msg, "erro_processamento", "Falha ao criar candidatura", stats,
                           excecao_id=excecao_id, texto=texto)
        return _marcar_lido(vaga)

    cand_id = candidatura["id"]

    # A partir daqui existe candidatura: se isto era um reprocessamento, a exceção
    # original está resolvida, mesmo que a avaliação (nota) ainda falhe abaixo —
    # ela já tem sua própria tentativa de novo na próxima execução normal.
    if excecao_id:
        bd.atualizar_excecao(excecao_id, {
            "status": "revisado",
            "detalhe_erro": "Reprocessado com sucesso — candidatura criada.",
            "reprocessar_solicitado_em": None,
        })

    # ── Arquivo no Storage ──
    caminho = None
    if anexo and not MODO_SIMULACAO:
        ext = FORMATOS_ACEITOS.get(anexo["tipo_mime"], ".bin")
        hoje = datetime.now(timezone.utc)
        caminho = f"{hoje.year}/{hoje.month:02d}/{uuid.uuid4().hex}{ext}"
        caminho = bd.enviar_arquivo(caminho, anexo["conteudo"], anexo["tipo_mime"])

    bd.salvar_curriculo({
        "candidatura_id": cand_id,
        "storage_path": caminho,
        "nome_arquivo": anexo["nome"] if anexo else None,
        "tipo_mime": anexo["tipo_mime"] if anexo else "text/plain",
        "tamanho_bytes": anexo["tamanho"] if anexo else None,
        "origem": origem,
        "texto_extraido": texto,
        "ocr_aplicado": ocr,
        "extracao_ok": True,
    })

    stats.curriculos_processados += 1

    # ── Avaliação (Sonnet) ──
    if not _avaliar_e_salvar(cand_id, texto, vaga, nome, cfg, stats):
        bd.atualizar_candidatura(cand_id, {"status": "recebido"})
        return _marcar_lido(vaga)

    bd.atualizar_candidatura(cand_id, {"status": "avaliado"})
    return _marcar_lido(vaga)


def _avaliar_e_salvar(cand_id: str, texto: str, vaga: Dict, nome: Optional[str],
                      cfg: Dict, stats: Estatisticas, sequencia: int = 1) -> bool:
    """
    Avalia o currículo contra a vaga e grava a nota. Na faixa ambígua grava também
    a segunda opinião (sequencia + 1). False = a IA não devolveu avaliação válida.
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


def _devolver_status(cand_id: str) -> None:
    """Reavaliação impossível: a candidatura volta ao estado em que a IA a deixaria."""
    bd.atualizar_candidatura(
        cand_id, {"status": "avaliado" if bd.proxima_sequencia(cand_id) > 1 else "recebido"})


def reavaliar_pendentes(pendentes: List[Dict], vagas: List[Dict], cfg: Dict,
                        stats: Estatisticas) -> None:
    """
    Reavalia as candidaturas que o RH mandou para outra vaga no painel (status
    em_analise), usando o texto do currículo já guardado. A nota nova entra como a
    avaliação mais recente; as anteriores ficam no histórico.
    """
    log.info(f"{len(pendentes)} reavaliação(ões) pendente(s)")
    por_id = {v["id"]: v for v in vagas}

    for cand in pendentes:
        cand_id = cand["id"]
        try:
            vaga = por_id.get(cand["vaga_id"])
            log.info(f"► reavaliando candidatura {cand_id[:8]}"
                     f"{' para ' + vaga['titulo'] if vaga else ''}")
            if not vaga:
                log.warning("  A vaga escolhida não está mais aberta — mantendo a nota anterior")
                _devolver_status(cand_id)
                continue

            texto = bd.obter_texto_curriculo(cand_id)
            if not texto:
                log.warning("  Sem texto do currículo (dados expurgados?) — mantendo a nota anterior")
                _devolver_status(cand_id)
                continue

            nome = (cand.get("dados_pessoais") or {}).get("nome")
            if _avaliar_e_salvar(cand_id, texto, vaga, nome, cfg, stats,
                                 sequencia=bd.proxima_sequencia(cand_id)):
                bd.atualizar_candidatura(cand_id, {"status": "avaliado"})
            else:
                log.warning("  Fica em análise; tento de novo na próxima execução")
        except Exception as e:
            log.error(f"  Erro inesperado na reavaliação: {e}", exc_info=True)


def enriquecer() -> None:
    """
    Preenche o perfil de busca (idade, escolaridade, experiência, CNH) das candidaturas
    que ainda não têm, a partir do texto já guardado (python main.py --enriquecer).
    Use --limite N para fazer só as N primeiras.
    """
    ia.resetar_custo()
    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — nada será gravado")
    cfg = bd.carregar_configuracoes()
    pendentes = bd.listar_sem_perfil(LIMITE_EMAILS)
    if not pendentes:
        log.info("Nenhuma candidatura sem perfil de busca")
        return

    log.info(f"{len(pendentes)} candidatura(s) sem perfil de busca")
    feitas = 0
    for cand in pendentes:
        try:
            texto = bd.obter_texto_curriculo(cand["id"])
            if not texto:
                log.warning(f"  candidatura {cand['id'][:8]}: sem texto do currículo — ignorada")
                continue
            perfil = _perfil_do_curriculo(texto, cfg)
            if not perfil.get("perfil_v"):
                continue                      # a IA falhou; a próxima execução tenta de novo
            bd.atualizar_candidatura(
                cand["id"], {"dados_pessoais": {**(cand.get("dados_pessoais") or {}), **perfil}})
            feitas += 1
        except Exception as e:
            log.error(f"  candidatura {cand['id'][:8]}: {e}", exc_info=True)

    log.info(f"Perfis preenchidos: {feitas} de {len(pendentes)} | "
             f"custo US$ {ia.custo_total['usd']:.4f} ({ia.custo_total['chamadas']} chamadas)")


def reavaliar() -> Dict:
    """
    Só as reavaliações pendentes, sem ler e-mails (python main.py --reavaliar).
    Sem nada pendente não registra execução, para poder rodar com frequência.
    """
    ia.resetar_custo()
    stats = Estatisticas()
    pendentes = bd.listar_reavaliacoes()
    if not pendentes:
        log.info("Nenhuma reavaliação pendente")
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
        vagas = bd.listar_vagas_abertas()
        for exc in pendentes:
            message_id = exc.get("email_message_id")
            log.info(f"► reprocessando exceção {exc['id'][:8]} ({exc['email_remetente']})")
            try:
                if not message_id:
                    log.warning("  Sem Message-ID salvo — não é possível buscar o e-mail original")
                    bd.atualizar_excecao(exc["id"], {"reprocessar_solicitado_em": None})
                    continue

                # Este e-mail já virou candidatura por outro caminho (ex.: uma execução normal
                # o pegou de novo antes de alguém revisar esta exceção) — a exceção ficou
                # esquecida, mas não há nada a reprocessar: só encerrar, sem tentar duplicar
                # (isso já quebrou o lote uma vez: "duplicate key ... idx_cand_message_id").
                if bd.candidatura_existe_para_mensagem(message_id):
                    bd.atualizar_excecao(exc["id"], {
                        "status": "revisado",
                        "detalhe_erro": "Este e-mail já tinha virado candidatura por outro caminho — exceção estava desatualizada.",
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
                processar_mensagem(msg, vagas, cfg, stats, excecao_id=exc["id"])
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


def processar_upload_manual(item: Dict, vagas: List[Dict], cfg: Dict,
                            stats: Estatisticas) -> None:
    """
    Processa um currículo enviado manualmente no painel (botão "Enviar currículo",
    sem passar por e-mail). O RH já escolheu a vaga ao enviar, então a IA não
    precisa achar qual vaga combina — só confirma que é currículo de verdade,
    extrai nome/cidade e avalia contra essa única vaga (mesmo prompt de sempre,
    com a lista de vagas restrita a uma).
    """
    upload_id = item["id"]
    log.info(f"► upload manual {upload_id[:8]} ({item['nome_arquivo']})")

    def _falhar(motivo: str) -> None:
        log.warning(f"  {motivo}")
        bd.atualizar_upload_manual(upload_id, {
            "status": "erro", "detalhe_erro": motivo[:400], "processado_em": bd.agora(),
        })

    vaga = next((v for v in vagas if v["id"] == item["vaga_id"]), None)
    if not vaga:
        _falhar("A vaga escolhida não está mais aberta")
        return

    conteudo = bd.baixar_arquivo(item["storage_path"])
    if not conteudo:
        _falhar("Não foi possível ler o arquivo enviado")
        return

    texto, ocr = extrator.extrair(conteudo, item["tipo_mime"])
    if not texto or len(texto.strip()) < 100:
        _falhar(f"Arquivo '{item['nome_arquivo']}' sem texto legível")
        return
    texto = limpar_texto(texto)

    modelo_cls = modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
    try:
        resultado, _ = ia.classificar(texto, [vaga], modelo_cls)
    except Exception as e:
        _falhar(f"Falha na classificação: {e}")
        return

    if not resultado or not resultado.get("e_curriculo"):
        _falhar("Conteúdo não identificado como currículo")
        return

    nome = resultado.get("nome_candidato")
    telefone = extrair_telefone(texto)
    email_cand = extrair_email(texto)
    hash_id = gerar_hash_identidade(nome, telefone)

    carencia = int(cfg.get("reincidencia_dias_carencia", 90))
    dup = bd.buscar_duplicata(hash_id, vaga["id"], carencia)
    if dup:
        log.info(f"  Reenvio dentro de {carencia} dias — registrado como reincidência")
        stats.duplicados_detectados += 1

    # Sem e-mail de origem: usa o e-mail achado no currículo, ou um identificador
    # próprio (remetente_id é obrigatório em candidaturas, e o e-mail é único).
    remetente = bd.obter_ou_criar_remetente(
        email_cand or f"upload-manual-{upload_id}@sem-email.recrutei")

    candidatura = bd.criar_candidatura({
        "remetente_id": remetente["id"] if remetente["id"] != "simulado" else None,
        "vaga_id": vaga["id"],
        "dados_pessoais": {
            "nome": nome,
            "telefone": telefone,
            "telefone_e164": telefone,
            "email": email_cand,
            "cidade": resultado.get("cidade"),
            **_perfil_do_curriculo(texto, cfg),
        },
        "hash_identidade": hash_id,
        "status": "em_analise",
        "aderencia_vaga": resultado.get("aderencia"),
        "recebido_em": bd.agora(),
    })
    if not candidatura:
        _falhar("Falha ao criar candidatura")
        return

    cand_id = candidatura["id"]

    bd.salvar_curriculo({
        "candidatura_id": cand_id,
        "storage_path": item["storage_path"],
        "nome_arquivo": item["nome_arquivo"],
        "tipo_mime": item["tipo_mime"],
        "tamanho_bytes": item.get("tamanho_bytes"),
        "origem": "upload_manual",
        "texto_extraido": texto,
        "ocr_aplicado": ocr,
        "extracao_ok": True,
    })
    stats.curriculos_processados += 1

    if _avaliar_e_salvar(cand_id, texto, vaga, nome, cfg, stats):
        bd.atualizar_candidatura(cand_id, {"status": "avaliado"})
    else:
        bd.atualizar_candidatura(cand_id, {"status": "recebido"})

    bd.atualizar_upload_manual(upload_id, {
        "status": "processado", "candidatura_gerada_id": cand_id, "processado_em": bd.agora(),
    })


def processar_uploads_manuais_pendentes(vagas: List[Dict], cfg: Dict, stats: Estatisticas) -> None:
    pendentes = bd.listar_uploads_manuais_pendentes()
    if not pendentes:
        return
    log.info(f"{len(pendentes)} upload(s) manual(is) pendente(s)")
    for item in pendentes:
        try:
            processar_upload_manual(item, vagas, cfg, stats)
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
        vagas = bd.listar_vagas_abertas()
        processar_uploads_manuais_pendentes(vagas, cfg, stats)
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


def executar() -> Dict:
    """Execução completa do pipeline diário."""
    log.info("=" * 60)
    log.info("RECRUTEI — Pipeline de triagem")
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
        log.info("Segunda avaliação: " +
                 (f"notas de {faixa[0]} a {faixa[1]}" if faixa else "desativada"))
        vagas = bd.listar_vagas_abertas()

        if not vagas:
            log.warning("Nenhuma vaga aberta — currículos não podem ser classificados")
        else:
            log.info(f"{len(vagas)} vaga(s) aberta(s): "
                     f"{', '.join(v['titulo'] for v in vagas)}")

        # Reavaliações que o RH pediu no painel (troca de vaga) vêm antes dos e-mails novos
        try:
            pendentes = bd.listar_reavaliacoes()
            if pendentes:
                log.info("-" * 60)
                reavaliar_pendentes(pendentes, vagas, cfg, stats)
        except Exception as e:
            log.error(f"Falha nas reavaliações: {e}", exc_info=True)

        # Currículos enviados manualmente no painel, antes dos e-mails novos
        try:
            log.info("-" * 60)
            processar_uploads_manuais_pendentes(vagas, cfg, stats)
        except Exception as e:
            log.error(f"Falha nos uploads manuais: {e}", exc_info=True)

        # E-mails de outros setores ficam não lidos; o marcador de progresso
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
                    if processar_mensagem(msg, vagas, cfg, stats):
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

        # Manutenção: inativação e expurgo
        log.info("-" * 60)
        log.info("Executando manutenção (retenção e expurgo)")
        manut = bd.executar_manutencao()
        if manut:
            log.info(f"  Inativadas: {manut.get('inativadas', 0)} | "
                     f"Expurgadas: {manut.get('expurgadas', 0)}")

    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)

    finally:
        bd.finalizar_execucao(exec_id, stats.como_dict(),
                              sucesso=erro_fatal is None, erro=erro_fatal)

    log.info("=" * 60)
    log.info(f"E-mails lidos          : {stats.emails_lidos}")
    log.info(f"Currículos processados : {stats.curriculos_processados}")
    log.info(f"Avaliações realizadas  : {stats.avaliacoes_realizadas}")
    log.info(f"Exceções geradas       : {stats.excecoes_geradas}")
    log.info(f"Duplicados detectados  : {stats.duplicados_detectados}")
    log.info(f"Remetentes bloqueados  : {stats.bloqueados}")
    log.info(f"Custo da execução      : US$ {ia.custo_total['usd']:.4f} "
             f"({ia.custo_total['chamadas']} chamadas)")
    log.info("=" * 60)

    return stats.como_dict()
