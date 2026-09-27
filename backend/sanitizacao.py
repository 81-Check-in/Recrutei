"""
Sanitização periódica do Banco de Talentos: gera a lista de SUGESTÕES e avisa o RH.

A sanitização só sugere: nada é inativado nem apagado por este módulo. O que ele faz, a cada conferência (toda semana,
configurável em Configurações → sanitizacao_intervalo_dias):
  1. pede ao banco a lista de candidatos sugeridos para limpeza, cada um com motivo e prioridade. Só entra quem
     está ATIVO e ficou 1 mês sem nenhuma alteração, contado da entrada no sistema (nunca da data do e-mail); as
     regras e os pesos também são parâmetros do painel — ver backend/sql/043 e 047;
  2. avisa o RH: dentro do sistema (a tela "Sanitização" e o painel mostram as pendentes) e, se houver
     e-mail configurado, por e-mail. O e-mail só traz contagens: nunca nome nem dado de candidato.
A decisão — Manter ou Inativar, individual ou em lote — é do RH, no painel. A fila NÃO exclui.

O expurgo (apagar os dados pessoais, sobrando só o esqueleto para reconhecer um reenvio) é outra etapa e é AUTOMÁTICA:
quem está inativo há mais de N meses (Configurações → expurgo_meses_apos_inativar, padrão 6) é apagado pela manutenção
diária do banco — fn_manutencao_diaria → fn_expurgar_inativos_vencidos (backend/sql/047), chamada por
database.executar_manutencao. Este módulo só registra o resultado no log (registrar_expurgo).

Roda junto da execução diária (pipeline.executar) e sozinha com: python main.py --sanitizacao [--forcar]
"""
import smtplib
import ssl
from email.message import EmailMessage
from typing import Dict, List, Optional, Tuple

import database as bd
from config import (
    MODO_SIMULACAO, PAINEL_URL, SMTP_SERVIDOR, SMTP_PORTA, SMTP_USUARIO, SMTP_SENHA, SMTP_REMETENTE, log,
)


def destinatarios(cfg: Dict) -> List[str]:
    """E-mails do aviso (Configurações → sanitizacao_emails_aviso, separados por vírgula ou ponto e vírgula)."""
    bruto = cfg.get("sanitizacao_emails_aviso")
    if not isinstance(bruto, str):
        return []
    partes = bruto.replace(";", ",").split(",")
    return [p.strip() for p in partes if "@" in p and p.strip()]


def montar_email(novas: int, por_prioridade: Dict[str, int], pendentes: Dict[str, int]) -> Tuple[str, str]:
    """(assunto, corpo). Só contagens — sem nenhum dado pessoal de candidato."""
    assunto = f"Banco de Talentos: {pendentes['total']} sugestão(ões) de sanitização aguardando revisão"
    linhas = [
        "Banco de Talentos — sugestões de sanitização",
        "",
        f"Foi gerada a lista deste ciclo: {novas} candidato(s) sugerido(s) para limpeza"
        f" (alta: {por_prioridade.get('alta', 0)}, média: {por_prioridade.get('media', 0)},"
        f" baixa: {por_prioridade.get('baixa', 0)}).",
        f"No total, {pendentes['total']} sugestão(ões) aguardam a sua decisão"
        f" (alta: {pendentes['alta']}, média: {pendentes['media']}, baixa: {pendentes['baixa']}).",
        "",
        "Nada foi apagado nem inativado: cada decisão (Manter ou Inativar) é do RH. Quem for inativado tem os dados"
        " apagados automaticamente depois do prazo definido em Configurações.",
    ]
    if PAINEL_URL:
        linhas += ["", f"Abrir o painel: {PAINEL_URL}  →  Sanitização"]
    return assunto, "\n".join(linhas) + "\n"


def registrar_expurgo(expurgo: Optional[Dict]) -> None:
    """
    Registra no log o resultado do expurgo automático (o banco o faz dentro de fn_manutencao_diaria: inativos há mais de
    N meses). None = banco sem a migração 047 ou modo simulação: não há o que registrar.
    """
    if expurgo is None:
        return
    if expurgo.get("erro"):
        log.error(f"  Expurgo automático FALHOU: {expurgo['erro']}")
        return
    apagados = int(expurgo.get("expurgados") or 0)
    falhas = int(expurgo.get("falhas") or 0)
    restantes = int(expurgo.get("restantes") or 0)
    if not (apagados or falhas or restantes):
        log.info("  Expurgo automático: nenhum inativo vencido")
        return
    log.info(f"  Expurgo automático: {apagados} candidato(s) com os dados apagados "
             f"(inativos há mais de {expurgo.get('meses')} meses)")
    if falhas:
        log.warning(f"  Expurgo automático: {falhas} candidato(s) com falha (ver o log do banco); tentam de novo na próxima execução")
    if restantes:
        log.info(f"  Expurgo automático: {restantes} ainda na fila (o banco apaga até 300 por execução)")


def enviar_email(para: List[str], assunto: str, corpo: str) -> bool:
    """Envia por SMTP (465 = SSL direto; outra porta = STARTTLS). Nunca levanta: falha vira aviso no log."""
    msg = EmailMessage()
    msg["Subject"] = assunto
    msg["From"] = SMTP_REMETENTE
    msg["To"] = ", ".join(para)
    msg.set_content(corpo)
    try:
        contexto = ssl.create_default_context()
        if SMTP_PORTA == 465:
            with smtplib.SMTP_SSL(SMTP_SERVIDOR, SMTP_PORTA, context=contexto, timeout=30) as smtp:
                smtp.login(SMTP_USUARIO, SMTP_SENHA)
                smtp.send_message(msg)
        else:
            with smtplib.SMTP(SMTP_SERVIDOR, SMTP_PORTA, timeout=30) as smtp:
                smtp.starttls(context=contexto)
                smtp.login(SMTP_USUARIO, SMTP_SENHA)
                smtp.send_message(msg)
        return True
    except Exception as e:
        log.warning(f"  Não consegui enviar o e-mail de aviso da sanitização: {e}")
        return False


def notificar(resultado: Dict) -> bool:
    """Avisa por e-mail (se configurado). O aviso dentro do sistema não precisa de código: a tela lê as pendentes."""
    para = destinatarios(bd.carregar_configuracoes())
    if not para:
        log.info("  Sem e-mail de aviso configurado — o RH vê as pendentes dentro do sistema")
        return False
    assunto, corpo = montar_email(int(resultado.get("total") or 0),
                                  resultado.get("por_prioridade") or {}, bd.contar_sugestoes_pendentes())
    if not enviar_email(para, assunto, corpo):
        return False
    if resultado.get("ciclo_id"):
        bd.marcar_ciclo_notificado(resultado["ciclo_id"])
    log.info(f"  Aviso enviado a {len(para)} destinatário(s)")
    return True


def verificar_e_gerar(forcar: bool = False, origem: str = "job") -> Dict:
    """
    Gera a lista de sugestões se o intervalo venceu (ou sempre, com forcar) e avisa o RH.
    É seguro chamar todo dia: fora do prazo o banco só responde "ainda não venceu".
    """
    if MODO_SIMULACAO:
        log.warning("MODO SIMULAÇÃO — sanitização não gerada")
        return {"gerada": False, "simulacao": True}

    resultado = bd.gerar_sugestoes_sanitizacao(origem, forcar)
    if not resultado.get("gerada"):
        log.info(f"Sanitização: {resultado.get('motivo', 'nada a fazer')}"
                 f"{' (próxima em ' + str(resultado['proxima_em'])[:10] + ')' if resultado.get('proxima_em') else ''}")
        return resultado

    total = int(resultado.get("total") or 0)
    por = resultado.get("por_prioridade") or {}
    log.info(f"Sanitização: {total} sugestão(ões) gerada(s) — alta {por.get('alta', 0)}, "
             f"média {por.get('media', 0)}, baixa {por.get('baixa', 0)}")
    if total:
        notificar(resultado)
    return resultado
