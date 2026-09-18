"""Orquestração: e-mail → extração → classificação → avaliação → banco."""
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple
import uuid

import database as bd
import leitor_email as mail
import extrator
import ia
from config import (
    FORMATOS_ACEITOS, TAMANHO_MINIMO_ANEXO, LIMITE_EMAILS,
    MODO_SIMULACAO, MODELO_CLASSIFICACAO_PADRAO, MODELO_AVALIACAO_PADRAO, log,
)
from utils import (
    extrair_telefone, extrair_email, gerar_hash_identidade,
    detectar_link_google_docs, limpar_texto,
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
                       stats: Estatisticas, nome_arquivo: str = None) -> None:
    # O detalhe pode conter nome de arquivo/candidato: fica só no banco, não no log
    log.warning(f"  Exceção [{tipo}]")
    remetente = bd.obter_ou_criar_remetente(msg["remetente"])
    bd.registrar_excecao({
        "remetente_id": remetente["id"] if remetente["id"] != "simulado" else None,
        "email_remetente": msg["remetente"],
        "email_message_id": msg.get("message_id"),
        "email_assunto": msg.get("assunto"),
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
        texto = extrator.extrair_google_docs(link)
        if texto and len(texto.strip()) >= 100:
            return texto, False, None, "google_docs", None
        return None, False, None, None, ("docs_privado", "Google Docs com acesso restrito")

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
    Desativa quando faixa_ambigua_min ou faixa_ambigua_max está vazia.
    """
    brutos = [cfg.get("faixa_ambigua_min", 60), cfg.get("faixa_ambigua_max", 75)]
    if any(v is None or str(v).strip() == "" for v in brutos):
        return None
    try:
        return int(float(brutos[0])), int(float(brutos[1]))
    except (TypeError, ValueError):
        log.warning("faixa_ambigua_min/max inválidas — usando 60 a 75")
        return 60, 75


def processar_mensagem(msg: Dict, vagas: List[Dict], cfg: Dict,
                       stats: Estatisticas) -> bool:
    """Processa um e-mail. Retorna True se pode ser marcado como lido."""
    uid = msg["uid"].decode() if isinstance(msg["uid"], bytes) else msg["uid"]
    log.info(f"► mensagem UID {uid}")

    # Idempotência
    if msg.get("message_id") and bd.email_ja_processado(msg["message_id"]):
        log.info("  Já processado anteriormente — ignorando")
        return True

    # Remetente bloqueado
    if bd.remetente_bloqueado(msg["remetente"]):
        log.info("  Remetente bloqueado — ignorando")
        stats.bloqueados += 1
        return True

    # ── Extração ──
    texto, ocr, anexo, origem, erro = _obter_texto(msg)
    if erro:
        _registrar_excecao(msg, erro[0], erro[1], stats,
                           anexo["nome"] if anexo else None)
        return True

    texto = limpar_texto(texto)

    # ── Classificação (Haiku) ──
    modelo_cls = modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
    try:
        resultado, _ = ia.classificar(texto, vagas, modelo_cls)
    except Exception as e:
        _registrar_excecao(msg, "erro_processamento", f"Falha na classificação: {e}", stats)
        return True

    if not resultado:
        _registrar_excecao(msg, "erro_processamento",
                           "Classificador não retornou resposta válida", stats)
        return True

    if not resultado.get("e_curriculo"):
        _registrar_excecao(msg, "nao_e_curriculo",
                           "Conteúdo não identificado como currículo", stats)
        return True

    vaga_id = resultado.get("vaga_id")
    vaga = next((v for v in vagas if v["id"] == vaga_id), None)
    if not vaga:
        _registrar_excecao(msg, "vaga_nao_identificada",
                           "Nenhuma vaga aberta corresponde ao perfil", stats)
        return True

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
        return False

    cand_id = candidatura["id"]

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
    modelo_aval = modelo_configurado(cfg, "modelo_ia_avaliacao", MODELO_AVALIACAO_PADRAO)
    try:
        aval, uso = ia.avaliar(texto, vaga, modelo_aval, variacao=1,
                               nome_candidato=nome)
    except Exception as e:
        log.error(f"  Falha na avaliação: {e}")
        bd.atualizar_candidatura(cand_id, {"status": "recebido"})
        return True

    if not aval:
        log.error("  Avaliador não retornou resposta válida")
        bd.atualizar_candidatura(cand_id, {"status": "recebido"})
        return True

    nota = int(aval.get("nota", 0))
    log.info(f"  Nota: {nota}")

    bd.salvar_avaliacao({
        "candidatura_id": cand_id,
        "vaga_id": vaga_id,
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
        "sequencia": 1,
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
                    "vaga_id": vaga_id,
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
                    "sequencia": 2,
                    "divergencia_detectada": divergiu,
                })
                stats.avaliacoes_realizadas += 1
        except Exception as e:
            log.warning(f"  Segunda avaliação falhou: {e}")

    bd.atualizar_candidatura(cand_id, {"status": "avaliado"})
    return True


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

        mensagens = mail.buscar_novos(LIMITE_EMAILS)
        stats.emails_lidos = len(mensagens)

        if not mensagens:
            log.info("Nenhuma mensagem nova")
        else:
            log.info("-" * 60)
            tratadas = []
            for i, msg in enumerate(mensagens, 1):
                log.info(f"[{i}/{len(mensagens)}]")
                try:
                    if processar_mensagem(msg, vagas, cfg, stats):
                        tratadas.append(msg["uid"])
                except Exception as e:
                    log.error(f"  Erro inesperado: {e}", exc_info=True)
                    try:
                        _registrar_excecao(msg, "erro_processamento", str(e)[:400], stats)
                        tratadas.append(msg["uid"])
                    except Exception:
                        pass

            mail.marcar_como_lidas(tratadas)

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
