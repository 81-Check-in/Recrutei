"""
Leitura da caixa de e-mail via IMAP (Locaweb).

Este módulo NUNCA apaga, move nem copia e-mails: não usa \\Deleted, EXPUNGE,
CLOSE, MOVE nem COPY. A única alteração feita na caixa é marcar como lida (\\Seen).
"""
import imaplib
import email
import email.message      # usado nas anotações; sem isto o módulo só importa se outro já tiver carregado o submódulo
import ssl
from datetime import date
from email.header import decode_header
from email.utils import parseaddr, parsedate_to_datetime
from typing import List, Dict, Optional, Iterator, Tuple
from contextlib import contextmanager

from config import (
    IMAP_SERVIDOR, IMAP_PORTA, IMAP_USUARIO, IMAP_SENHA,
    IMAP_PASTA_ENTRADA, IMAP_DESDE,
    FORMATOS_ACEITOS, TAMANHO_MAXIMO_ANEXO, MAX_ANEXOS_POR_EMAIL,
    MODO_SIMULACAO, log,
)


def _decodificar(valor: Optional[str]) -> str:
    """Decodifica cabeçalhos MIME (=?utf-8?B?...?=)."""
    if not valor:
        return ""
    partes = []
    for texto, enc in decode_header(valor):
        if isinstance(texto, bytes):
            try:
                partes.append(texto.decode(enc or "utf-8", errors="replace"))
            except (LookupError, TypeError):
                partes.append(texto.decode("utf-8", errors="replace"))
        else:
            partes.append(texto)
    return "".join(partes).strip()


@contextmanager
def conexao_imap() -> Iterator[imaplib.IMAP4_SSL]:
    """Abre e fecha a conexão com segurança."""
    # O padrão do imaplib (Python < 3.13) não valida o certificado do servidor
    conn = imaplib.IMAP4_SSL(IMAP_SERVIDOR, IMAP_PORTA,
                             ssl_context=ssl.create_default_context(),
                             timeout=60)
    try:
        conn.login(IMAP_USUARIO, IMAP_SENHA)
        log.info(f"Conectado a {IMAP_USUARIO}")
        yield conn
    finally:
        # Sem conn.close(): o CLOSE do IMAP remove em definitivo todas as
        # mensagens marcadas \Deleted na pasta (inclusive por outros clientes)
        try:
            conn.logout()
        except Exception:
            pass


def _extrair_corpo(msg: email.message.Message) -> str:
    """Texto do corpo — usado para achar link de Google Docs."""
    corpo = ""
    if msg.is_multipart():
        for parte in msg.walk():
            if parte.get_content_maintype() == "multipart":
                continue
            if parte.get("Content-Disposition") and "attachment" in str(parte.get("Content-Disposition")):
                continue
            if parte.get_content_type() in ("text/plain", "text/html"):
                try:
                    carga = parte.get_payload(decode=True)
                    if carga:
                        corpo += carga.decode(
                            parte.get_content_charset() or "utf-8",
                            errors="replace")
                except Exception:
                    pass
    else:
        try:
            carga = msg.get_payload(decode=True)
            if carga:
                corpo = carga.decode(
                    msg.get_content_charset() or "utf-8", errors="replace")
        except Exception:
            pass
    return corpo


def _assinatura_confere(tipo: str, conteudo: bytes) -> bool:
    """O tipo vem do remetente; confere se os primeiros bytes batem com ele."""
    if tipo == "application/pdf":
        return b"%PDF-" in conteudo[:1024]
    if "wordprocessingml" in tipo:
        return conteudo[:4] == b"PK\x03\x04"
    if tipo == "application/msword":
        return (conteudo[:4] == b"PK\x03\x04"
                or conteudo[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1")
    if tipo == "image/jpeg":
        return conteudo[:3] == b"\xff\xd8\xff"
    if tipo == "image/png":
        return conteudo[:8] == b"\x89PNG\r\n\x1a\n"
    return False


def _extrair_anexos(msg: email.message.Message) -> List[Dict]:
    """Retorna apenas anexos em formato aceito e dentro do limite."""
    anexos = []
    for parte in msg.walk():
        if len(anexos) >= MAX_ANEXOS_POR_EMAIL:
            log.warning("  Muitos anexos — os demais foram ignorados")
            break
        if parte.get_content_maintype() == "multipart":
            continue

        disp = str(parte.get("Content-Disposition") or "")
        nome = parte.get_filename()
        if not nome and "attachment" not in disp:
            continue

        nome = _decodificar(nome) or "anexo"
        tipo = parte.get_content_type()

        try:
            conteudo = parte.get_payload(decode=True)
        except Exception:
            continue
        if not conteudo:
            continue

        # Aceita pela extensão quando o MIME vem genérico
        if tipo not in FORMATOS_ACEITOS:
            ext = ("." + nome.rsplit(".", 1)[-1].lower()) if "." in nome else ""
            equivalente = {v: k for k, v in FORMATOS_ACEITOS.items()}
            if ext in equivalente:
                tipo = equivalente[ext]
            else:
                continue

        if len(conteudo) > TAMANHO_MAXIMO_ANEXO:
            log.warning("  Anexo excede o limite de tamanho — ignorado")
            continue

        anexos.append({
            "nome": nome,
            "tipo_mime": tipo,
            "conteudo": conteudo,
            "tamanho": len(conteudo),
            "assinatura_ok": _assinatura_confere(tipo, conteudo),
        })
    return anexos


_MESES_IMAP = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def _criterio_busca(apos_uid: int = 0, todas: bool = False) -> tuple:
    """
    UNSEEN (ou ALL, com todas=True), limitado por IMAP_DESDE (data) e por apos_uid (só UIDs maiores).
    O IMAP exige DD-Mon-AAAA com mês em inglês.
    """
    criterio: tuple = ("ALL",) if todas else ("UNSEEN",)
    if apos_uid > 0:
        criterio += ("UID", f"{apos_uid + 1}:*")
    if IMAP_DESDE:
        d = date.fromisoformat(IMAP_DESDE)
        criterio += ("SINCE", f"{d.day:02d}-{_MESES_IMAP[d.month - 1]}-{d.year}")
    return criterio


def _uidvalidity(conn: imaplib.IMAP4_SSL) -> int:
    """Identificador da caixa: se mudar, os UIDs guardados deixam de valer."""
    _, dados = conn.response("UIDVALIDITY")
    return int(dados[0]) if dados and dados[0] else 0


def _mensagem_de_uid(conn: imaplib.IMAP4_SSL, uid) -> Optional[Dict]:
    """Busca e decodifica uma mensagem pelo UID. None se não achar ou não tiver remetente."""
    # PEEK não marca como lida: se o processo cair, o e-mail é relido
    status, dados = conn.uid("FETCH", uid, "(BODY.PEEK[])")
    if status != "OK" or not dados or not isinstance(dados[0], tuple):
        return None
    msg = email.message_from_bytes(dados[0][1])

    _, remetente = parseaddr(msg.get("From", ""))
    if not remetente:
        return None

    try:
        recebido = parsedate_to_datetime(msg.get("Date")).isoformat()
    except Exception:
        recebido = None

    return {
        "uid": uid,
        "message_id": (msg.get("Message-ID") or "").strip("<> "),
        "remetente": remetente.lower(),
        "assunto": _decodificar(msg.get("Subject")),
        "corpo": _extrair_corpo(msg),
        "recebido_em": recebido,
        "anexos": _extrair_anexos(msg),
    }


def buscar_novos(limite: int = 0, apos_uid: int = 0,
                 uidvalidity_salvo: int = 0, todas: bool = False, ate_uid: int = 0) -> Tuple[List[Dict], int]:
    """
    Lê os e-mails não lidos da caixa de entrada, do mais antigo para o mais novo.

    apos_uid: ignora UIDs até esse valor (e-mails já analisados que ficaram não lidos).
    todas: lê também os já lidos (--reler-caixa). Exige IMAP_DESDE: sem data seria a caixa inteira,
           anos de e-mail que nada têm a ver com currículos.
    ate_uid: não passa desse UID (0 = sem limite). Serve para reler só o que o pipeline já tinha lido.
    Devolve (mensagens, UIDVALIDITY da caixa).
    """
    if todas and not IMAP_DESDE:
        raise RuntimeError("Reler a caixa exige uma data inicial (IMAP_DESDE ou --desde AAAA-MM-DD).")
    mensagens: List[Dict] = []

    with conexao_imap() as conn:
        conn.select(IMAP_PASTA_ENTRADA, readonly=True)
        validade = _uidvalidity(conn)
        if apos_uid and uidvalidity_salvo and validade != uidvalidity_salvo:
            log.warning("A caixa foi reindexada (UIDVALIDITY mudou) — "
                        "marcador de progresso ignorado")
            apos_uid = 0

        status, dados = conn.uid("SEARCH", *_criterio_busca(apos_uid, todas))
        if status != "OK":
            log.error("Falha ao buscar mensagens")
            return [], validade

        # "UID n:*" sempre inclui o maior UID da caixa, mesmo abaixo de n: filtrar aqui
        ids = [u for u in dados[0].split() if int(u) > apos_uid and (not ate_uid or int(u) <= ate_uid)]
        if limite > 0:
            ids = ids[:limite]
        desde = f" desde {IMAP_DESDE}" if IMAP_DESDE else ""
        apos = (f", após o UID {apos_uid}" if apos_uid else "") + (f", até o UID {ate_uid}" if ate_uid else "")
        log.info(f"{len(ids)} mensagem(ns) {'na caixa' if todas else 'não lida(s)'}{desde}{apos}")

        for uid in ids:
            try:
                msg = _mensagem_de_uid(conn, uid)
                if msg:
                    mensagens.append(msg)
            except Exception as e:
                log.error(f"  Erro ao ler mensagem {uid}: {e}")

    return mensagens, validade


def buscar_por_message_id(message_id: str) -> Optional[Dict]:
    """
    Busca de novo uma mensagem específica pelo cabeçalho Message-ID — usada para
    reprocessar uma exceção (o e-mail original já pode estar lido, então a busca
    não se limita a UNSEEN). None se a mensagem não existir mais na caixa (ex.:
    apagada por outro cliente de e-mail).
    """
    if not message_id:
        return None
    with conexao_imap() as conn:
        conn.select(IMAP_PASTA_ENTRADA, readonly=True)
        # HEADER faz busca por substring: o valor gravado no banco já vem sem "<>",
        # e o cabeçalho real inclui os "<>" — a substring ainda casa.
        status, dados = conn.uid("SEARCH", "HEADER", "Message-ID", message_id)
        if status != "OK" or not dados or not dados[0]:
            return None
        uid = dados[0].split()[0]
        return _mensagem_de_uid(conn, uid)


def marcar_como_lidas(uids: List) -> None:
    """
    Marca as mensagens tratadas como lidas. Os e-mails continuam na entrada:
    nada é removido, movido nem copiado.
    """
    if not uids or MODO_SIMULACAO:
        return

    with conexao_imap() as conn:
        conn.select(IMAP_PASTA_ENTRADA)
        marcadas = 0
        for uid in uids:
            try:
                # Lida = não entra de novo no SEARCH UNSEEN da próxima execução.
                # O imaplib não levanta exceção para respostas "NO": conferir o status
                status, _ = conn.uid("STORE", uid, "+FLAGS", "(\\Seen)")
                if status == "OK":
                    marcadas += 1
                else:
                    log.error(f"  Servidor recusou marcar a mensagem {uid} como lida")
            except Exception as e:
                log.error(f"  Falha ao marcar mensagem como lida: {e}")
        log.info(f"{marcadas} mensagem(ns) marcada(s) como lida(s)")


def testar_conexao() -> bool:
    """Valida credenciais antes de rodar o pipeline."""
    try:
        with conexao_imap() as conn:
            conn.select(IMAP_PASTA_ENTRADA, readonly=True)
            status, dados = conn.search(None, "ALL")
            total = len(dados[0].split()) if status == "OK" else 0
            log.info(f"Conexão OK — {total} mensagem(ns) na caixa")
        return True
    except Exception as e:
        log.error(f"Falha na conexão IMAP: {e}")
        return False
