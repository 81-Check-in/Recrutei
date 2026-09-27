"""Funções auxiliares: telefone, hash, texto, máscara de dados pessoais."""
import re
import hmac
import hashlib
import unicodedata
from datetime import date
from html.parser import HTMLParser
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


def extrair_telefone(texto: str, ddi: str = "55", ddd: str = "61") -> Optional[str]:
    """Localiza o primeiro telefone celular plausível no currículo. ddi/ddd completam o número que vem sem eles (Configurações)."""
    if not texto:
        return None

    padroes = [
        r"\(?\d{2}\)?\s*9\s*\d{4}[-\s]?\d{4}",  # celular com DDD
        r"\(?\d{2}\)?\s*\d{4,5}[-\s]?\d{4}",    # fixo ou celular
        r"9\s?\d{4}[-\s]?\d{4}",                # sem DDD
    ]
    for p in padroes:
        for m in re.finditer(p, texto):
            tel = normalizar_telefone(m.group(), ddi, ddd)
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


def primeiro_nome(nome: Optional[str]) -> Optional[str]:
    """
    O primeiro nome de uma pessoa (só letras, acentos, hífen e apóstrofo; de 2 a 30 caracteres), ou None se não sobrar um nome de
    verdade (vazio, só inicial, número). É só isto que vai à IA na estimativa do sexo: nunca o sobrenome nem o nome completo.
    """
    m = re.match(r"\s*([^\W\d_]+(?:['’-][^\W\d_]+)*)", nome or "")
    return m.group(1) if m and 2 <= len(m.group(1)) <= 30 else None


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


# ─────────────────────────────────────────────
# CURRÍCULO ESCRITO NO CORPO DO E-MAIL (sem anexo nem link)
# ─────────────────────────────────────────────
_RE_LINK_DE_DESCADASTRO = re.compile(r"unsubscribe|descadastr|cancelar (?:a )?inscri|remover (?:meu )?(?:e-?mail|cadastro)|opt.?out", re.I)


class _HtmlParaTexto(HTMLParser):
    """Só o texto visível: descarta estilos e scripts e quebra a linha onde o HTML quebra (parágrafo, <br>, item de lista...)."""
    _IGNORAR = {"style", "script", "head", "title"}
    _BLOCOS = {"p", "div", "br", "li", "ul", "ol", "tr", "table", "hr", "blockquote", "section", "article",
               "h1", "h2", "h3", "h4", "h5", "h6"}

    def __init__(self, com_links: bool = False) -> None:
        super().__init__(convert_charrefs=True)
        self.partes: List[str] = []
        self._ignorando = 0
        self._linha_vazia = True                     # nada de texto na linha atual: outra quebra só criaria linha em branco
        self._com_links = com_links                  # escreve o endereço depois do texto do link: "Ver perfil: https://..."
        self._href: Optional[str] = None
        self._texto_do_link: List[str] = []

    def _fecha_link(self) -> None:
        href, texto = self._href or "", " ".join("".join(self._texto_do_link).split())
        self._href, self._texto_do_link = None, []
        if (not texto or not href.lower().startswith(("http://", "https://")) or texto.lower().startswith("http")
                or _RE_LINK_DE_DESCADASTRO.search(texto) or _RE_LINK_DE_DESCADASTRO.search(href)):
            return                                   # sem texto, sem endereço web, o texto já é o endereço ou é "cancelar inscrição"
        if self.partes:
            self.partes[-1] = self.partes[-1].rstrip(" \t")        # "Ver perfil " + ": url" não pode virar "Ver perfil : url"
        self.partes.append(f": {href}\n")
        self._linha_vazia = True

    def _quebra(self) -> None:
        if not self._linha_vazia:
            self.partes.append("\n")
            self._linha_vazia = True

    def handle_starttag(self, tag, attrs):
        if tag in self._IGNORAR:
            self._ignorando += 1
        elif tag in self._BLOCOS:
            self._quebra()
        elif tag == "a" and self._com_links and not self._ignorando:
            self._href, self._texto_do_link = (dict(attrs).get("href") or "").strip(), []

    def handle_startendtag(self, tag, attrs):        # <br/>
        if tag in self._BLOCOS:
            self._quebra()

    def handle_endtag(self, tag):
        if tag in self._IGNORAR:
            self._ignorando = max(0, self._ignorando - 1)
        elif tag in self._BLOCOS:
            self._quebra()
        elif tag == "a" and self._href is not None:
            self._fecha_link()

    def handle_data(self, data):
        if not self._ignorando:
            self.partes.append(data)
            if self._href is not None:
                self._texto_do_link.append(data)
            if data.strip():
                self._linha_vazia = False


_RE_PARECE_HTML = re.compile(r"<\s*/?\s*(?:html|head|body|div|p|br|span|table|tr|td|ul|ol|li|style|meta|font|h[1-6])\b", re.I)


def html_para_texto(html: Optional[str], com_links: bool = False) -> str:
    """
    Texto legível de um corpo de e-mail em HTML (o Apple Mail, por exemplo, manda 30 KB de estilo para 1 KB de texto).
    Texto puro passa quase intacto. Nunca levanta erro: HTML quebrado devolve o que deu para ler.
    com_links: depois do texto de cada link escreve o endereço ("Ver perfil: https://..."), menos os de cancelar inscrição.
    É o que o RH lê em "Ver e-mail" na Fila de Exceção; o texto que a IA lê como currículo não leva links.
    """
    if not html:
        return ""
    if not _RE_PARECE_HTML.search(html):             # texto puro: "Nome <a@b.com>" não pode ser lido como uma marcação
        return re.sub(r"\n{3,}", "\n\n", re.sub(r"[ \t]+", " ", html.replace("\xa0", " "))).strip()
    conversor = _HtmlParaTexto(com_links)
    try:
        conversor.feed(html)
        conversor.close()
    except Exception:
        pass
    texto = "".join(conversor.partes).replace("\xa0", " ")
    texto = re.sub(r"[ \t]+", " ", texto)
    texto = re.sub(r" ?\n ?", "\n", texto)
    return re.sub(r"\n{3,}", "\n\n", texto).strip()


# Palavras que um currículo costuma trazer, sem acento (normalizar_texto). Nenhuma sozinha diz nada ("experiência" está em
# todo e-mail de propaganda): o que vale é a combinação, e a IA ainda confirma se é currículo antes de qualquer coisa entrar no banco.
_SINAIS_DE_CURRICULO = (
    r"experiencias?", r"formacao", r"escolaridade", r"objetivo", r"habilidades", r"competencias", r"qualificacoes",
    r"ensino (?:medio|fundamental|superior)", r"graduacao", r"idiomas", r"\bcnh\b", r"estado civil", r"nascimento",
    r"dados pessoais", r"resumo profissional", r"perfil profissional", r"historico profissional", r"cursos?\b",
    r"disponibilidade", r"curriculo vitae",
)
_RE_SINAIS_DE_CURRICULO = [re.compile(r"\b" + p if not p.startswith(r"\b") else p) for p in _SINAIS_DE_CURRICULO]
CURRICULO_NO_CORPO_MIN_CARACTERES = 300
CURRICULO_NO_CORPO_MIN_SINAIS = 2


def parece_curriculo(texto: Optional[str]) -> bool:
    """
    O corpo de um e-mail sem anexo tem cara de currículo? Texto longo o bastante e com pelo menos dois dos sinais de
    currículo acima. É só o filtro barato que evita gastar a IA com "segue meu currículo em anexo" e propaganda.
    """
    if not texto or len(texto.strip()) < CURRICULO_NO_CORPO_MIN_CARACTERES:
        return False
    normalizado = normalizar_texto(texto)
    return sum(1 for r in _RE_SINAIS_DE_CURRICULO if r.search(normalizado)) >= CURRICULO_NO_CORPO_MIN_SINAIS


class _ExtratorDeLinks(HTMLParser):
    """Cada link <a> do HTML com o texto que ele mostra (inclusive o de um <button> dentro dele) e o endereço."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: List[Tuple[str, str]] = []
        self._href: Optional[str] = None
        self._texto: List[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self._href, self._texto = (dict(attrs).get("href") or "").strip(), []

    def handle_data(self, data):
        if self._href is not None:
            self._texto.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._href is not None:
            self.links.append((" ".join("".join(self._texto).split()), self._href))
            self._href = None


def link_do_html(html: Optional[str], texto_do_link: str) -> Optional[str]:
    """
    O endereço do primeiro link do HTML cujo texto contém `texto_do_link` ("Ver perfil"), sem diferença de acento ou caixa.
    Só endereço web (http/https): o e-mail é de terceiros e o painel usa o resultado em um botão. None se não houver.
    """
    if not html or not texto_do_link:
        return None
    extrator = _ExtratorDeLinks()
    try:
        extrator.feed(html)
        extrator.close()
    except Exception:
        pass
    alvo = normalizar_texto(texto_do_link)
    for texto, href in extrator.links:
        if alvo in normalizar_texto(texto) and re.match(r"https?://\S+$", href, re.I):
            return href
    return None


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
