"""Funções auxiliares: telefone, hash, texto, máscara de dados pessoais."""
import re
import hmac
import hashlib
import unicodedata
from datetime import date
from typing import Dict, List, Optional, Tuple

from config import IDENTIDADE_CHAVE


def normalizar_telefone(tel: Optional[str], ddi: str = "55", ddd: str = "61") -> Optional[str]:
    """
    Converte qualquer formato para o padrão do link do WhatsApp.
    (61) 9 9211-6739 -> 5561992116739
    """
    if not tel:
        return None

    n = re.sub(r"\D", "", str(tel))
    if not n:
        return None

    # Remove zeros de operadora no início (ex: 041, 015)
    n = re.sub(r"^0+", "", n)

    if n.startswith(ddi) and len(n) >= 12:
        return n
    if len(n) in (10, 11):        # DDD + número
        return ddi + n
    if len(n) in (8, 9):          # só o número
        return ddi + ddd + n
    return n if len(n) >= 12 else None


def extrair_telefone(texto: str) -> Optional[str]:
    """Localiza o primeiro telefone celular plausível no currículo."""
    if not texto:
        return None

    padroes = [
        r"\(?\d{2}\)?\s*9\s*\d{4}[-\s]?\d{4}",  # celular com DDD
        r"\(?\d{2}\)?\s*\d{4,5}[-\s]?\d{4}",    # fixo ou celular
        r"9\s?\d{4}[-\s]?\d{4}",                # sem DDD
    ]
    for p in padroes:
        for m in re.finditer(p, texto):
            tel = normalizar_telefone(m.group())
            # Celular brasileiro: 55 + DDD + 9 dígitos = 13
            if tel and len(tel) >= 12:
                return tel
    return None


def extrair_email(texto: str) -> Optional[str]:
    if not texto:
        return None
    m = re.search(r"[\w\.\-\+]+@[\w\-]+\.[\w\.\-]+", texto)
    return m.group().lower() if m else None


def gerar_hash_identidade(nome: Optional[str], telefone: Optional[str]) -> Optional[str]:
    """
    Hash de identidade para detectar duplicatas mesmo após o expurgo
    dos dados pessoais (LGPD).

    HMAC com chave secreta: um SHA-256 simples de nome+telefone pode ser revertido
    por força bruta (o telefone tem poucas combinações), o que desfaria o expurgo.
    """
    if not nome and not telefone:
        return None
    base = f"{normalizar_texto(nome or '')}|{telefone or ''}"
    return hmac.new(IDENTIDADE_CHAVE.encode(), base.encode(), hashlib.sha256).hexdigest()


def gerar_hash_arquivo(conteudo: bytes) -> str:
    """
    Impressão digital do ARQUIVO do currículo, para reconhecer o mesmo arquivo reenviado sem precisar lê-lo
    (extração, OCR e IA custam). HMAC com a mesma chave do hash de identidade: sobrevive à exclusão dos dados
    (só o texto e o caminho do arquivo são apagados) e não permite descobrir o conteúdo a partir dela.
    """
    return hmac.new(IDENTIDADE_CHAVE.encode(), conteudo, hashlib.sha256).hexdigest()


def normalizar_texto(s: str) -> str:
    """Minúsculas, sem acento, espaços colapsados."""
    if not s:
        return ""
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", s).strip().lower()


_RE_LINHA_DE_ENDERECO = re.compile(
    r"(?im)^[ \t]*(?:endere[cç]o|end\.|bairro|resid[eê]ncia|reside|mora(?:\s+em)?|moro(?:\s+em)?|cidade|localiza[cç][aã]o)\b.*$")


def detectar_regiao(texto: str, regioes: List[Dict]) -> Optional[str]:
    """
    Acha, no texto do currículo, a região onde a pessoa mora (devolve o id em regioes_df). Tudo aqui é local: casa o
    texto com os nomes e apelidos das regiões (palavra inteira, sem acento nem caixa) e nada é enviado a ninguém —
    inclusive as linhas de endereço, que a IA nem chega a ver (o mascaramento as troca por [ENDEREÇO]).
    Procura primeiro nas linhas de endereço/bairro/cidade e, se não achar, no cabeçalho (primeiros 1.200 caracteres);
    um nome citado mais adiante (empregos anteriores, escola) não conta. Com vários, vale o nome mais comprido
    ("Novo Gama" antes de "Gama"). "Brasília" sozinho não aponta região.
    regioes: [{"id", "nome", "apelidos": [...]}].
    """
    if not texto or not regioes:
        return None
    nomes = []                                  # (nome normalizado, id)
    for r in regioes:
        for n in [r.get("nome")] + list(r.get("apelidos") or []):
            n = re.sub(r"[^a-z0-9 ]", "", normalizar_texto(n or ""))
            if n:
                nomes.append((n, r["id"]))

    def melhor(trecho: str) -> Optional[str]:
        alvo = f" {re.sub(r'[^a-z0-9]+', ' ', normalizar_texto(trecho))} "
        achados = [(len(n), rid) for n, rid in nomes if f" {n} " in alvo]
        return max(achados)[1] if achados else None

    linhas = " \n".join(m.group(0) for m in _RE_LINHA_DE_ENDERECO.finditer(texto))
    return melhor(linhas) or melhor(texto[:1200])


_RE_NASCIMENTO = re.compile(
    r"(?i)\b(?:data\s+de\s+nascimento|nascimento|nasc\.?|nascid[oa](?:\s+em)?|d\.?\s?n\.?)"
    r"\s*[:\-]?\s*(\d{1,2})\s*[/.\-]\s*(\d{1,2})\s*[/.\-]\s*(\d{4}|\d{2})(?!\d)"
)
# "Tenho X anos" é ambíguo com tempo de experiência ("Tenho 20 anos de experiência",
# "Tenho 15 anos atuando em..."). Só conta como idade quando NÃO é seguido de uma dessas
# continuações — nesses casos o número é tempo de trabalho, não idade da pessoa.
_CONTINUACAO_EXPERIENCIA = (
    r"de|na|no|em|com|para|atuando|trabalhando|exercendo|desenvolvendo|militando|"
    r"dedicad[oa]s?|completos?\s+de"
)
_RE_IDADE = re.compile(
    r"(?i)\bidade\s*[:\-]?\s*(\d{2})(?:\s*anos)?(?!\d)"
    rf"|\btenho\s+(\d{{2}})\s+anos(?:\s+de\s+idade)?(?!\s*(?:{_CONTINUACAO_EXPERIENCIA})\b)"
)


def extrair_idade(texto: str, hoje: Optional[date] = None) -> Optional[int]:
    """
    Idade em anos, lida do próprio currículo: data de nascimento ("Nascimento: 12/03/1998")
    ou idade escrita ("Idade: 27 anos"). None se o currículo não informa.
    Roda só localmente: a data de nascimento não é enviada à IA.
    """
    if not texto:
        return None
    hoje = hoje or date.today()
    m = _RE_NASCIMENTO.search(texto)
    if m:
        dia, mes, ano = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if ano < 100:                                   # "98" → 1998; "05" → 2005
            ano += 2000 if ano <= hoje.year % 100 else 1900
        try:
            nasc = date(ano, mes, dia)
        except ValueError:
            nasc = None
        if nasc and nasc <= hoje:
            idade = hoje.year - nasc.year - ((hoje.month, hoje.day) < (nasc.month, nasc.day))
            if 14 <= idade <= 85:
                return idade
    m = _RE_IDADE.search(texto)
    if m:
        idade = int(m.group(1) or m.group(2))
        if 14 <= idade <= 85:
            return idade
    return None


def extrair_nascimento(texto: str, hoje: Optional[date] = None) -> Optional[date]:
    """
    Data de nascimento EXATA, quando o currículo a traz ("Nascimento: 12/03/1998"). None se só informa a
    idade ("Idade: 27 anos") — nesse caso use extrair_idade(). Roda só localmente, como extrair_idade().
    """
    if not texto:
        return None
    hoje = hoje or date.today()
    m = _RE_NASCIMENTO.search(texto)
    if not m:
        return None
    dia, mes, ano = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if ano < 100:                                       # "98" → 1998; "05" → 2005
        ano += 2000 if ano <= hoje.year % 100 else 1900
    try:
        nasc = date(ano, mes, dia)
    except ValueError:
        return None
    if nasc > hoje:
        return None
    idade = hoje.year - nasc.year - ((hoje.month, hoje.day) < (nasc.month, nasc.day))
    return nasc if 14 <= idade <= 85 else None


UFS = frozenset("AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO".split())
_RE_CIDADE_UF = re.compile(r"^(?P<cidade>.*?)\s*[/,–-]\s*(?P<uf>[A-Za-z]{2})\s*$")


def separar_cidade_uf(texto: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    """
    "Brasília/DF", "Taguatinga - DF", "Ceilândia, DF" → ("Brasília", "DF"), ("Taguatinga", "DF"), ...
    Sem UF reconhecível ("Valparaíso de Goiás") devolve (texto, None). Mesma regra da migração 025.
    """
    texto = (texto or "").strip()
    if not texto:
        return None, None
    m = _RE_CIDADE_UF.match(texto)
    if m and m.group("uf").upper() in UFS:
        return (m.group("cidade").strip() or None), m.group("uf").upper()
    return texto, None


def limpar_texto(texto: str, limite: int = 20000) -> str:
    """Remove ruído de extração e limita tamanho para a API."""
    if not texto:
        return ""
    # PDF/OCR malformado às vezes gera \x00 e outros caracteres de controle;
    # o Postgres rejeita \u0000 em texto (erro 22P05) e derruba a gravação inteira.
    texto = texto.replace("\x00", "").translate(
        {c: None for c in range(32) if c not in (9, 10, 13)})
    texto = re.sub(r"[ \t]+", " ", texto)
    texto = re.sub(r"\n{3,}", "\n\n", texto)
    texto = texto.strip()
    if len(texto) > limite:
        texto = texto[:limite] + "\n\n[...texto truncado...]"
    return texto


# ─────────────────────────────────────────────
# MÁSCARA DE DADOS PESSOAIS (antes de enviar à IA)
# ─────────────────────────────────────────────
_MASCARAS = [
    (re.compile(r"[\w.+\-]{1,64}@[\w\-]{1,63}(?:\.[\w\-]{1,63}){1,5}"), "[E-MAIL]"),
    (re.compile(r"(?i)https?://(?:[\w\-]+\.)?(?:linkedin|facebook|instagram|twitter|tiktok)\.com/\S+"),
     "[PERFIL_SOCIAL]"),
    (re.compile(r"(?<!\d)\d{3}\.\d{3}\.\d{3}-\d{2}(?!\d)"), "[CPF]"),
    (re.compile(r"(?i)(\bcpf\b[^\n\d\[\]]{0,15})\d[\d.\- \t]{8,13}\d"), r"\1[CPF]"),
    (re.compile(r"(?i)(\b(?:rg\b|r\.g\.|carteira de identidade\b)[^\n\d\[\]]{0,20})"
                r"[\dXx][\dXx.\- \t/]{4,14}[\dXx]"), r"\1[RG]"),
    (re.compile(r"(?<!\d)\d{1,2}\.\d{3}\.\d{3}-[\dXx](?!\d)"), "[RG]"),
    # Só o número: "CNH categoria B" é requisito de vaga e precisa continuar visível
    (re.compile(r"(?i)(\bcnh\b[^\n\d\[\]]{0,30})\d{9,11}(?!\d)"), r"\1[NÚMERO]"),
    (re.compile(r"(?<!\d)\d{3}\.\d{5}\.\d{2}-\d(?!\d)"), "[PIS]"),
    (re.compile(r"(?<!\d)\d{5}-\d{3}(?!\d)"), "[CEP]"),
    (re.compile(r"(?im)^([ \t]*(?:endere[cç]o|end\.)[ \t]*[:\-]).*$"), r"\1 [ENDEREÇO]"),
]

_RE_TELEFONE = re.compile(
    r"(?<!\d)(?:\+?55[\s.\-]?)?(?:\(\d{2}\)|\d{2})[\s.\-]?(?:9[\s.\-]?)?\d{4}[\s.\-]?\d{4}(?!\d)"
    r"|(?<!\d)9[\s.\-]?\d{4}[\s.\-]?\d{4}(?!\d)"
)
# "2018 2019 2020" tem o formato de um telefone, mas é uma lista de anos
_RE_LISTA_DE_ANOS = re.compile(r"(?:\(?\d{2}\)?[\s.\-]*)?(?:19|20)\d{2}[\s.\-]*(?:19|20)\d{2}")

_PARTICULAS_NOME = {"de", "da", "do", "das", "dos", "del", "van", "von"}
_FAMILIAS_ACENTO = {"a": "aàáâãäå", "e": "eèéêë", "i": "iìíîï", "o": "oòóôõö",
                    "u": "uùúûü", "c": "cç", "n": "nñ", "y": "yýÿ"}


def _mascarar_telefone(m: "re.Match") -> str:
    trecho = m.group()
    return trecho if _RE_LISTA_DE_ANOS.fullmatch(trecho.strip()) else "[TELEFONE]"


def _padrao_do_token(token: str) -> str:
    """Casa o token com ou sem acento e em qualquer caixa (João / JOAO)."""
    base = normalizar_texto(token)
    return "".join(f"[{_FAMILIAS_ACENTO[c]}]" if c in _FAMILIAS_ACENTO else re.escape(c)
                   for c in base)


def _mascarar_nome(texto: str, nome: str) -> str:
    tokens = {t for t in re.findall(r"[^\W\d_]+", nome)
              if len(t) >= 3 and normalizar_texto(t) not in _PARTICULAS_NOME}
    for token in sorted(tokens, key=len, reverse=True):
        texto = re.sub(rf"(?<!\w){_padrao_do_token(token)}(?!\w)", "[CANDIDATO]",
                       texto, flags=re.IGNORECASE)
    return re.sub(r"(\[CANDIDATO\])(?:[ \t,]+\[CANDIDATO\])+", r"\1", texto)


def mascarar_dados_pessoais(texto: str, nome: Optional[str] = None) -> str:
    """
    Troca por marcadores o que identifica a pessoa e não pesa na avaliação:
    contatos, documentos e endereço. Com `nome`, oculta também o nome.
    Devolve uma cópia; o texto original (usado para extrair os contatos) não muda.
    """
    if not texto:
        return ""
    for padrao, marcador in _MASCARAS:
        texto = padrao.sub(marcador, texto)
    texto = _RE_TELEFONE.sub(_mascarar_telefone, texto)
    if nome:
        texto = _mascarar_nome(texto, nome)
    return texto


def detectar_link_google_docs(texto: str) -> Optional[str]:
    """Encontra link de Google Docs/Drive no corpo do e-mail."""
    if not texto:
        return None
    m = re.search(
        r"https?://(?:docs|drive)\.google\.com/[^\s<>\"']+", texto
    )
    return m.group() if m else None


def calcular_custo(modelo: str, tokens_entrada: int, tokens_saida: int,
                   precos: dict) -> float:
    p = precos.get(modelo)
    if not p:
        return 0.0
    return (tokens_entrada / 1_000_000 * p["entrada"]
            + tokens_saida / 1_000_000 * p["saida"])
