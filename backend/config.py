"""
Configuração central do Recrutei.
Lê variáveis de ambiente e parâmetros do banco.
"""
import os
import logging
from datetime import date
from dotenv import load_dotenv

load_dotenv()


def _req(chave: str) -> str:
    """Variável obrigatória — falha cedo se faltar."""
    valor = os.getenv(chave, "").strip()
    if not valor:
        raise RuntimeError(
            f"Variável de ambiente obrigatória não definida: {chave}\n"
            f"Verifique o arquivo .env (use .env.example como base)."
        )
    return valor


# ── Supabase ──
SUPABASE_URL = _req("SUPABASE_URL")
SUPABASE_SERVICE_KEY = _req("SUPABASE_SERVICE_KEY")

# ── Claude ──
ANTHROPIC_API_KEY = _req("ANTHROPIC_API_KEY")

# ── E-mail ──
IMAP_SERVIDOR = os.getenv("IMAP_SERVIDOR", "email-ssl.com.br")
IMAP_PORTA = int(os.getenv("IMAP_PORTA", "993"))
IMAP_USUARIO = _req("IMAP_USUARIO")
IMAP_SENHA = _req("IMAP_SENHA")
IMAP_PASTA_ENTRADA = os.getenv("IMAP_PASTA_ENTRADA", "INBOX")
# Só processa não lidos recebidos a partir desta data (AAAA-MM-DD). Vazio = todos.
IMAP_DESDE = os.getenv("IMAP_DESDE", "").strip()
if IMAP_DESDE:
    try:
        date.fromisoformat(IMAP_DESDE)
    except ValueError:
        raise RuntimeError(
            f"IMAP_DESDE inválida: {IMAP_DESDE!r}. Use AAAA-MM-DD (ex.: 2026-09-18)."
        )

# ── Privacidade ──
# Chave do HMAC do hash de identidade. Se mudar, reenvios antigos deixam de ser detectados.
IDENTIDADE_CHAVE = _req("IDENTIDADE_CHAVE")
if len(IDENTIDADE_CHAVE) < 32:
    raise RuntimeError(
        "IDENTIDADE_CHAVE muito curta (mínimo 32 caracteres).\n"
        'Gere uma com: python -c "import secrets; print(secrets.token_hex(32))"'
    )

# ── Execução ──
MODO_SIMULACAO = os.getenv("MODO_SIMULACAO", "false").lower() == "true"
LIMITE_EMAILS = int(os.getenv("LIMITE_EMAILS", "0"))
# Só e-mails classificados neste setor são marcados como lidos; os demais ficam
# não lidos na caixa. Vazio = todo e-mail processado é marcado como lido.
SETOR_MARCAR_LIDO = os.getenv("SETOR_MARCAR_LIDO", "Logística").strip()
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()

# ── Constantes ──
BUCKET_CURRICULOS = "curriculos"

FORMATOS_ACEITOS = {
    "application/pdf": ".pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
    "application/msword": ".doc",
    "image/jpeg": ".jpg",
    "image/png": ".png",
}

TAMANHO_MINIMO_ANEXO = 10 * 1024       # 10 KB
TAMANHO_MAXIMO_ANEXO = 10 * 1024 * 1024  # 10 MB
MAX_ANEXOS_POR_EMAIL = 5

# Limites contra arquivos maliciosos (bombas de descompressão, imagens gigantes)
LIMITE_PIXELS_IMAGEM = 60_000_000
LIMITE_ZIP_DESCOMPRIMIDO = 100 * 1024 * 1024
LIMITE_ZIP_ENTRADAS = 2000
LADO_MAX_PDF_PX = 2400          # lado maior da página ao rasterizar para OCR
TEMPO_MAX_OCR = 60              # segundos por chamada de OCR
TEMPO_MAX_EXTRACAO = 180        # segundos por currículo (Linux/macOS)

# Custo por milhão de tokens (USD) — atualizar se a tabela mudar
PRECOS = {
    "claude-fable-5-1":          {"entrada": 10.00, "saida": 50.00},
    "claude-opus-5":             {"entrada": 5.00,  "saida": 25.00},
    "claude-sonnet-5":           {"entrada": 2.00,  "saida": 10.00},
    "claude-haiku-4-5-20251001": {"entrada": 1.00,  "saida": 5.00},
}

# Modelos padrão (os mais baratos que atendem): Haiku classifica, Sonnet avalia.
# Valem quando a configuração está ausente ou vazia.
MODELO_CLASSIFICACAO_PADRAO = "claude-haiku-4-5-20251001"
MODELO_AVALIACAO_PADRAO = "claude-sonnet-5"

# Sonnet 5, Opus 5 e Fable 5.1 raciocinam por padrão, e o raciocínio conta como saída
# (custo e max_tokens). Aqui vai só o necessário para devolver o JSON pedido:
#   corpo        campos extras enviados na requisição
#   folga_tokens somado ao max_tokens para o raciocínio não cortar a resposta
# O Haiku 4.5 não raciocina por padrão e não precisa de nada.
PARAMETROS_MODELO = {
    "claude-sonnet-5":  {"corpo": {"thinking": {"type": "disabled"}}, "folga_tokens": 0},
    "claude-opus-5":    {"corpo": {"output_config": {"effort": "low"}}, "folga_tokens": 2000},
    "claude-fable-5-1": {"corpo": {"output_config": {"effort": "low"}}, "folga_tokens": 2000},
}


def configurar_log() -> logging.Logger:
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL, logging.INFO),
        format="%(asctime)s │ %(levelname)-7s │ %(message)s",
        datefmt="%H:%M:%S",
    )
    # Silencia bibliotecas verbosas. hpack/h2 gravam cabeçalhos (apikey, authorization)
    # e anthropic grava o prompt inteiro (currículo) quando o nível é DEBUG.
    for lib in ("httpx", "httpcore", "urllib3", "pdfminer", "PIL",
                "hpack", "h2", "hyperframe", "anthropic"):
        logging.getLogger(lib).setLevel(logging.WARNING)
    return logging.getLogger("recrutei")


log = configurar_log()
