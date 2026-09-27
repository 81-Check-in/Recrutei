"""
Carga em lote pela Batch API (metade do preço): lê os e-mails não lidos recebidos antes de uma data e os grava no Banco de
Talentos pelo MESMO caminho do pipeline (pipeline.processar_mensagem), trocando só a chamada à IA. Carga pontual, não rotina.

  python lote.py --ate 2026-09-01 --dir temp/lote/carga1 [--limite 40] [--teto-usd 22]

Etapas (cada uma grava seu ponto de retomada em --dir; rodar de novo com o mesmo --dir continua de onde parou):
  1. seleciona os não lidos com indício de anexo recebidos antes de --ate;
  2. baixa cada e-mail e extrai o texto (OCR local, sem custo de API), e separa o que o pipeline descartaria de graça
     (Message-ID ou arquivo já no banco, mesmo arquivo repetido na seleção, extração sem texto);
  3. lote 1 (Haiku): identificação de cada currículo;
  4. decide quem é pessoa nova (mesmo critério de pipeline._entrar_no_banco) e monta o lote 2: perfil (Haiku) + qualificação (Sonnet);
  5. reproduz o pipeline e-mail por e-mail com as respostas dos lotes: grava candidato, currículo, arquivo e análise e marca lido.
     Quem ficou sem resposta (erro do lote) não é tocado: continua não lido para a próxima carga ou para a rotina normal.

O sexo pelo nome NÃO é estimado aqui (uma chamada por candidato, tarefa minúscula): fica em branco e python main.py --sexo-pelo-nome
completa em bloco. Os arquivos de --dir têm texto de currículo: apague a pasta quando a carga terminar.
"""
import argparse
import hashlib
import imaplib
import json
import sys
import time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from contextlib import ExitStack
from datetime import date, datetime
from pathlib import Path
from typing import Dict, List, Optional

from config import log, IMAP_PASTA_ENTRADA, MODELO_CLASSIFICACAO_PADRAO, MODELO_AVALIACAO_PADRAO, PRECOS
import database as bd
import extrator
import ia
import leitor_email as mail
import pipeline as pl
from utils import (
    limpar_texto, extrair_telefone, extrair_email, gerar_hash_identidade, normalizar_texto, calcular_custo,
)

TAMANHO_LOTE_IDENTIFICACAO = 5000
TAMANHO_LOTE_ANALISE = 1000         # pedidos por lote da etapa 2: se o saldo da conta acabar, só os lotes seguintes deixam de ir
# US$ por pedido, já com o desconto do lote, medidos no piloto: identificação ~0,001; perfil ~0,0007 e qualificação ~0,0078 (média 0,0043)
CUSTO_ESTIMADO_POR_PEDIDO = {"identificacao": 0.0011, "analise": 0.0043}
MAX_TENTATIVAS_POR_PEDIDO = 2
INTERVALO_CONSULTA_S = 60
_CFG: Dict = {}                     # configurações do painel, herdadas pelos processos de extração


# ─────────────────────────────────────────────
# Arquivos de trabalho
# ─────────────────────────────────────────────
def _ler_json(caminho: Path, padrao):
    return json.loads(caminho.read_text(encoding="utf-8")) if caminho.exists() else padrao


def _gravar_json(caminho: Path, dados) -> None:
    tmp = caminho.with_suffix(".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False), encoding="utf-8")
    tmp.replace(caminho)


def _ler_jsonl(caminho: Path) -> List[Dict]:
    if not caminho.exists():
        return []
    return [json.loads(l) for l in caminho.read_text(encoding="utf-8").splitlines() if l.strip()]


def _instalar_cache_de_extracao(pasta: Path) -> None:
    """A extração (OCR inclusive) é a parte lenta do local: o texto de cada arquivo fica guardado e não se refaz na etapa 5."""
    pasta.mkdir(parents=True, exist_ok=True)
    original = extrator.extrair

    def com_cache(conteudo: bytes, tipo_mime: str):
        arq = pasta / (hashlib.sha256(conteudo + tipo_mime.encode()).hexdigest() + ".json")
        if arq.exists():
            d = json.loads(arq.read_text(encoding="utf-8"))
            return d["texto"], d["ocr"]
        texto, ocr = original(conteudo, tipo_mime)
        arq.write_text(json.dumps({"texto": texto, "ocr": ocr}, ensure_ascii=False), encoding="utf-8")
        return texto, ocr

    extrator.extrair = com_cache


# ─────────────────────────────────────────────
# 1. Seleção
# ─────────────────────────────────────────────
def _tem_indicio_de_anexo(estrutura: str) -> bool:
    import re
    b = estrutura.lower()
    return bool(re.search(r'"application" "(pdf|msword|vnd\.openxmlformats[^"]*|octet-stream)"', b)
                or '"attachment"' in b or re.search(r'"image" "(jpeg|png)"', b)
                or re.search(r'\.(pdf|docx?|jpe?g|png)\b', b))


def selecionar(ate: date, limite: int) -> List[Dict]:
    """Não lidos com indício de anexo, recebidos antes de `ate`, do mais antigo para o mais novo: [{"uid", "recebido"}]."""
    import re
    inicio = re.compile(rb"^\d+ \(")
    achados: Dict[int, Dict] = {}
    with mail.conexao_imap() as conn:
        conn.select(IMAP_PASTA_ENTRADA, readonly=True)
        status, dados = conn.uid("SEARCH", "UNSEEN")
        uids = [int(u) for u in dados[0].split()] if status == "OK" else []
        for i in range(0, len(uids), 100):
            lote = ",".join(map(str, uids[i:i + 100]))
            status, resp = conn.uid("FETCH", lote, "(UID INTERNALDATE BODYSTRUCTURE)")
            if status != "OK":
                continue
            atual: Optional[Dict] = None
            partes: List[Dict] = []
            for item in resp:
                cab, lit = (item[0], item[1]) if isinstance(item, tuple) else (item, None)
                if inicio.match(cab):
                    atual = {"texto": b"", "literais": []}
                    partes.append(atual)
                if atual is not None:
                    atual["texto"] += cab
                    if lit is not None:
                        atual["literais"].append(lit)
            for p in partes:
                t = p["texto"].decode("latin-1")
                uid = int(re.search(r"UID (\d+)", t).group(1))
                recebido = datetime.strptime(re.search(r'INTERNALDATE "([^"]+)"', t).group(1), "%d-%b-%Y %H:%M:%S %z")
                estrutura = t[t.find("BODYSTRUCTURE"):] + " " + " ".join(l.decode("latin-1", "replace") for l in p["literais"])
                if recebido.date() < ate and _tem_indicio_de_anexo(estrutura):
                    achados[uid] = {"uid": uid, "recebido": recebido.isoformat()}
    ordenados = sorted(achados.values(), key=lambda x: (x["recebido"], x["uid"]))
    return ordenados[:limite] if limite else ordenados


# ─────────────────────────────────────────────
# 2. Baixar e extrair (processos em paralelo)
# ─────────────────────────────────────────────
def _preparar_uids(uids: List[int]) -> List[Dict]:
    """Roda num processo próprio (o limite de tempo da extração usa SIGALRM, só no processo principal de cada um)."""
    saida: List[Dict] = []
    caixa = _Caixa()        # o servidor IMAP às vezes derruba a conexão no meio: a caixa reconecta e repete o e-mail
    try:
        for uid in uids:
            try:
                msg = caixa.mensagem(uid)
                if not msg:
                    saida.append({"uid": uid, "pular": True})
                    continue
                previsto = pl._escolher_anexo(msg, _CFG)
                texto, ocr, anexo, origem, erro = pl._obter_texto(msg, _CFG)
                saida.append({
                    "uid": uid, "message_id": msg.get("message_id"), "remetente": msg["remetente"],
                    "hash": pl.gerar_hash_arquivo(previsto["conteudo"]) if previsto else None,
                    "texto": texto, "origem": origem, "erro": list(erro) if erro else None,
                })
            except Exception as e:
                saida.append({"uid": uid, "falha": type(e).__name__})
    finally:
        caixa.fechar()
    return saida


def preparar(pasta: Path, selecao: List[Dict], processos: int) -> Dict[int, Dict]:
    """Baixa e extrai cada e-mail. O que falhar (conexão derrubada, por exemplo) é tentado de novo, em até 3 passadas."""
    caminho = pasta / "prep.jsonl"
    prontos = {r["uid"]: r for r in _ler_jsonl(caminho) if "falha" not in r}
    for passada in (1, 2, 3):
        faltam = [s["uid"] for s in selecao if s["uid"] not in prontos]
        log.info(f"Extração (passada {passada}): {len(prontos)} pronto(s), {len(faltam)} a baixar e extrair")
        if not faltam:
            break
        pedacos = [faltam[i:i + 10] for i in range(0, len(faltam), 10)]
        feitos, falhas = 0, 0
        with ProcessPoolExecutor(processos) as ex, open(caminho, "a", encoding="utf-8") as f:
            for resultado in ex.map(_preparar_uids, pedacos):
                for r in resultado:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
                    if "falha" in r:
                        falhas += 1
                    else:
                        prontos[r["uid"]] = r
                feitos += len(resultado)
                f.flush()
                if (feitos // 10) % 20 == 0:
                    log.info(f"  extraídos {feitos}/{len(faltam)} (falhas de leitura: {falhas})")
        if not falhas:
            break
    restantes = [s["uid"] for s in selecao if s["uid"] not in prontos]
    if restantes:
        log.warning(f"{len(restantes)} e-mail(s) não puderam ser lidos nem após 3 passadas: ficam como estão (não lidos)")
    return prontos


# ─────────────────────────────────────────────
# Banco: o que já existe (uma leitura em bloco, não uma consulta por e-mail)
# ─────────────────────────────────────────────
def _tudo(tabela: str, campos: str) -> List[Dict]:
    saida, ini = [], 0
    while True:
        r = bd.conectar().table(tabela).select(campos).range(ini, ini + 999).execute().data
        saida += r
        if len(r) < 1000:
            return saida
        ini += 1000


def _conhecido_no_banco() -> Dict:
    curr = _tudo("curriculos", "email_message_id,arquivo_hash")
    exc = _tudo("excecoes", "email_message_id")
    cand = _tudo("candidatos", "hash_identidade,email,nome_norm,status_banco")
    chaves = set()
    for c in cand:
        if c["status_banco"] != "ativo":
            continue        # inativo/expurgado pode ser relido depois de 30 dias: o pipeline decide na hora
        if c.get("hash_identidade"):
            chaves.add(("h", c["hash_identidade"]))
        if c.get("email") and c.get("nome_norm"):
            chaves.add(("e", c["email"].lower(), c["nome_norm"]))
    return {
        "msgids": {c["email_message_id"] for c in curr if c["email_message_id"]} | {e["email_message_id"] for e in exc if e["email_message_id"]},
        "hashes": {c["arquivo_hash"] for c in curr if c["arquivo_hash"]},
        "pessoas": chaves,
    }


# ─────────────────────────────────────────────
# Coleta dos pedidos (os mesmos prompts do pipeline)
# ─────────────────────────────────────────────
def _coletar(fn, *args, **kwargs) -> str:
    """Chama uma função de ia.py em modo "coletar": devolve a chave do pedido que ela faria."""
    ia._modo_lote = "coletar"
    try:
        fn(*args, **kwargs)
    except ia.PedidoColetado as p:
        return p.args[0]
    finally:
        ia._modo_lote = None
    raise RuntimeError("a função não fez nenhum pedido à IA")


def candidatos_da_etapa_1(prep: Dict[int, Dict], selecao: List[Dict], banco: Dict) -> List[Dict]:
    """Quem precisa de identificação: nem Message-ID nem arquivo no banco, arquivo novo na seleção e texto extraído."""
    vistos = set()
    saida = []
    for s in selecao:
        r = prep.get(s["uid"])
        if not r or r.get("pular") or r.get("erro") or not r.get("texto"):
            continue
        if r.get("message_id") in banco["msgids"]:
            continue
        h = r.get("hash")
        if h and (h in banco["hashes"] or h in vistos):
            continue
        if h:
            vistos.add(h)
        saida.append(r)
    return saida


def montar_identificacao(candidatos: List[Dict], cfg: Dict) -> Dict[str, Dict]:
    modelo = pl.modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
    regioes = pl._nomes_das_regioes()
    pedidos: Dict[str, Dict] = {}
    for r in candidatos:
        chave = _coletar(ia.identificar_curriculo, limpar_texto(r["texto"]), modelo, regioes)
        pedidos[chave] = ia.pedidos_coletados[chave]
    return pedidos


def montar_perfil_e_analise(candidatos: List[Dict], cfg: Dict, areas: List[str], banco: Dict) -> Dict:
    """
    Com as identificações prontas, repete a decisão de pipeline._entrar_no_banco (pessoa nova ou já cadastrada) e coleta os
    pedidos de perfil e qualificação de quem precisa. Devolve {"pedidos": {chave: corpo}, "plano": {uid: {"chaves": [...]}}}.
    """
    modelo_cls = pl.modelo_configurado(cfg, "modelo_ia_classificacao", MODELO_CLASSIFICACAO_PADRAO)
    modelo_ava = pl.modelo_configurado(cfg, "modelo_ia_avaliacao", MODELO_AVALIACAO_PADRAO)
    regioes = pl._nomes_das_regioes()
    vocabulario = bd.carregar_vocabulario_qualificacao()
    conhecidas = set(banco["pessoas"])
    pedidos: Dict[str, Dict] = {}
    plano: Dict[int, Dict] = {}
    contagem = Counter()
    for r in candidatos:
        texto = limpar_texto(r["texto"])
        chave_ident = _coletar(ia.identificar_curriculo, texto, modelo_cls, regioes)
        ia._modo_lote = "repetir"
        try:
            ident, _ = ia.identificar_curriculo(texto, modelo_cls, regioes)
        except ia.RespostaDeLoteAusente:
            contagem["sem resposta da identificação"] += 1
            continue
        finally:
            ia._modo_lote = None
        plano[r["uid"]] = {"chaves": [chave_ident]}
        if not ident or not ident.get("e_curriculo"):
            contagem["não é currículo / resposta inválida (o pipeline registra a exceção)"] += 1
            continue
        nome = ident.get("nome_candidato")
        telefone = extrair_telefone(texto, *pl._prefixo_telefone(cfg))
        email_cand = (extrair_email(texto) or r["remetente"] or "").lower()
        hash_id = gerar_hash_identidade(nome, telefone)
        chaves_pessoa = []
        if nome and telefone and hash_id:
            chaves_pessoa.append(("h", hash_id))
        if email_cand and nome:
            chaves_pessoa.append(("e", email_cand, normalizar_texto(nome)))
        if any(k in conhecidas for k in chaves_pessoa):
            contagem["mesma pessoa já cadastrada ou já na carga (sem perfil nem qualificação)"] += 1
            continue
        conhecidas.update(chaves_pessoa)
        k_perfil = _coletar(ia.extrair_perfil, texto, modelo_cls)
        k_analise = _coletar(ia.analisar_curriculo, texto, areas, modelo_ava, nome_candidato=nome,
                             funcoes=vocabulario["funcoes"], niveis=vocabulario["niveis"],
                             iniciantes=vocabulario.get("iniciantes"))
        for k in (k_perfil, k_analise):
            pedidos[k] = ia.pedidos_coletados[k]
        plano[r["uid"]]["chaves"] += [k_perfil, k_analise]
        contagem["pessoa nova (perfil + qualificação)"] += 1
    for motivo, n in contagem.items():
        log.info(f"  {n:5d}  {motivo}")
    return {"pedidos": pedidos, "plano": plano}


# ─────────────────────────────────────────────
# Batch API
# ─────────────────────────────────────────────
def _enviar(pedidos: Dict[str, Dict]) -> str:
    lote = ia.cliente.beta.messages.batches.create(
        requests=[{"custom_id": k, "params": p} for k, p in pedidos.items()])
    log.info(f"  lote enviado: {lote.id} ({len(pedidos)} pedidos)")
    return lote.id


def _aguardar(lote_id: str, n: int) -> None:
    espera = 20 if n <= 100 else INTERVALO_CONSULTA_S
    while True:
        b = ia.cliente.beta.messages.batches.retrieve(lote_id)
        c = b.request_counts
        log.info(f"  lote ...{lote_id[-8:]}: {b.processing_status} — {c.succeeded} pronto(s), {c.errored} com erro, "
                 f"{c.processing} em andamento")
        if b.processing_status == "ended":
            return
        time.sleep(espera)


def _baixar(lote_id: str, caminho: Path) -> Dict:
    """Guarda as respostas em respostas.jsonl e devolve o resumo: custo real (com o desconto) e os erros por tipo."""
    custo, ok, erros, mensagens = 0.0, 0, Counter(), []
    with open(caminho, "a", encoding="utf-8") as f:
        for item in ia.cliente.beta.messages.batches.results(lote_id):
            r = item.result
            if r.type == "succeeded":
                m = r.message
                texto = "".join(b.text for b in m.content if b.type == "text")
                f.write(json.dumps({"chave": item.custom_id, "texto": texto, "tokens_entrada": m.usage.input_tokens,
                                    "tokens_saida": m.usage.output_tokens, "modelo": m.model}, ensure_ascii=False) + "\n")
                custo += ia.DESCONTO_LOTE * calcular_custo(m.model, m.usage.input_tokens, m.usage.output_tokens, PRECOS)
                ok += 1
            else:
                e = getattr(getattr(r, "error", None), "error", None)
                motivo = f"{r.type}: {getattr(e, 'message', '') or getattr(e, 'type', '') or ''}"[:200]
                erros[r.type] += 1
                mensagens.append(motivo)
    sem_saldo = any("credit balance" in m.lower() or "billing" in m.lower() for m in mensagens)
    return {"custo_usd": custo, "ok": ok, "erros": dict(erros), "exemplos": sorted(set(mensagens))[:3], "sem_saldo": sem_saldo}


def _registrar_resumo(estado: Dict, pasta: Path, e: Dict, resumo: Dict) -> None:
    e["resumo"] = resumo
    estado["custo_usd"] = round(estado.get("custo_usd", 0.0) + resumo["custo_usd"], 4)
    _gravar_json(pasta / "estado.json", estado)


def _concluir_pendentes(estado: Dict, pasta: Path) -> None:
    """Lote já enviado e ainda não baixado (a carga foi interrompida no meio): espera e baixa, sem enviar nada de novo."""
    for nome, e in estado["lotes"].items():
        if "resumo" not in e:
            log.info(f"  retomando o lote {nome} ({e['id']})")
            _aguardar(e["id"], e["pedidos"])
            _registrar_resumo(estado, pasta, e, _baixar(e["id"], pasta / "respostas.jsonl"))


def _completar(estado: Dict, pasta: Path, fase: str, pedidos: Dict[str, Dict], tamanho: int, teto_usd: float) -> Optional[str]:
    """
    Faz chegar resposta a todos os pedidos da fase, em lotes de até `tamanho`. Só vai à API o que ainda NÃO tem resposta e o que
    não foi tentado MAX_TENTATIVAS_POR_PEDIDO vezes: nunca se paga duas vezes pelo mesmo pedido, nem se insiste num pedido que o
    servidor recusa. Devolve o motivo de ter parado antes de terminar (teto de gasto ou falta de saldo), ou None.
    """
    _concluir_pendentes(estado, pasta)
    respostas = _carregar_respostas(pasta)
    tentativas = estado.setdefault("tentativas", {})
    faltam = [(k, p) for k, p in pedidos.items()
              if k not in respostas and tentativas.get(k, 0) < MAX_TENTATIVAS_POR_PEDIDO]
    log.info(f"Fase {fase}: {len(pedidos)} pedido(s), {len(pedidos) - len(faltam)} já respondido(s) ou esgotado(s), {len(faltam)} a enviar")
    for i in range(0, len(faltam), tamanho):
        pedaco = dict(faltam[i:i + tamanho])
        previsto = CUSTO_ESTIMADO_POR_PEDIDO[fase] * len(pedaco)
        if estado.get("custo_usd", 0) + previsto > teto_usd:
            return f"o próximo lote ({len(pedaco)} pedidos, ~US$ {previsto:.2f}) passaria do teto de US$ {teto_usd:.2f}"
        nome = f"{fase}_{sum(1 for n in estado['lotes'] if n.startswith(fase + '_')) + 1}"
        e = estado["lotes"][nome] = {"id": _enviar(pedaco), "pedidos": len(pedaco)}
        for k in pedaco:
            tentativas[k] = tentativas.get(k, 0) + 1
        _gravar_json(pasta / "estado.json", estado)
        _aguardar(e["id"], e["pedidos"])
        _registrar_resumo(estado, pasta, e, _baixar(e["id"], pasta / "respostas.jsonl"))
        r = e["resumo"]
        log.info(f"  {nome}: {r['ok']} resposta(s), erros {r['erros'] or 0}, custo US$ {r['custo_usd']:.4f} "
                 f"(acumulado US$ {estado['custo_usd']:.4f})")
        if r["sem_saldo"]:
            return "a Anthropic recusou pedidos por falta de saldo"
    return None


def _carregar_respostas(pasta: Path) -> Dict[str, Dict]:
    return {r["chave"]: r for r in _ler_jsonl(pasta / "respostas.jsonl") if "texto" in r}


# ─────────────────────────────────────────────
# 5. Reprodução do pipeline com as respostas dos lotes
# ─────────────────────────────────────────────
class _Caixa:
    """Conexão IMAP que se refaz sozinha: a reprodução dura horas."""

    def __init__(self):
        self._pilha = ExitStack()
        self.conn = None

    def abrir(self):
        self._pilha.close()
        self._pilha = ExitStack()
        self.conn = self._pilha.enter_context(mail.conexao_imap())
        self.conn.select(IMAP_PASTA_ENTRADA, readonly=True)

    def mensagem(self, uid: int) -> Optional[Dict]:
        for tentativa in (1, 2):
            try:
                if self.conn is None:
                    self.abrir()
                return mail._mensagem_de_uid(self.conn, str(uid).encode())
            except (imaplib.IMAP4.abort, OSError):
                if tentativa == 2:
                    raise
                self.conn = None
        return None

    def fechar(self):
        self._pilha.close()


def reproduzir(pasta: Path, ordem: List[int], plano: Dict[int, Dict], cfg: Dict, areas: List[str]) -> Dict:
    respostas = _carregar_respostas(pasta)
    ia.respostas_lote = respostas
    ia._modo_lote = "repetir"
    with mail.conexao_imap() as conn:                   # a carga pode ter sido interrompida e retomada: o que já foi gravado está lido
        conn.select(IMAP_PASTA_ENTRADA, readonly=True)
        _, dados = conn.uid("SEARCH", "UNSEEN")
        nao_lidos = {int(u) for u in dados[0].split()}
    ja_lidos = len([u for u in ordem if u not in nao_lidos])
    ordem = [u for u in ordem if u in nao_lidos]
    log.info(f"Reprodução: {len(ordem)} e-mail(s) a gravar ({ja_lidos} já lidos numa execução anterior)")
    pl._sexo_pelo_nome = lambda nome, cfg_: None       # ver o cabeçalho deste arquivo
    ia.resetar_custo()
    stats = pl.Estatisticas()
    exec_id = bd.iniciar_execucao()
    erro_fatal = None
    tratadas: List[int] = []
    adiadas = Counter()
    caixa = _Caixa()
    try:
        for i, uid in enumerate(ordem, 1):
            precisa = plano.get(uid, {}).get("chaves", [])
            if any(k not in respostas for k in precisa):
                adiadas["sem resposta do lote"] += 1
                continue
            try:
                msg = caixa.mensagem(uid)
                if not msg:
                    adiadas["e-mail não lido pelo leitor"] += 1
                    continue
                stats.emails_lidos += 1
                if pl.processar_mensagem(msg, cfg, areas, stats):
                    tratadas.append(uid)
            except ia.RespostaDeLoteAusente:
                adiadas["resposta do lote ausente no meio do caminho"] += 1
            except ia.IAPausada:
                stats.interrompida = True
                log.warning("Envio à IA pausado no painel: paro a reprodução. O que falta continua não lido.")
                break
            except Exception as e:
                log.error(f"  Erro inesperado (UID {uid}): {type(e).__name__}: {e}", exc_info=True)
                try:
                    pl._registrar_excecao(msg, "erro_processamento", str(e)[:400], stats)
                    tratadas.append(uid)
                except Exception:
                    adiadas["falha ao registrar a exceção"] += 1
            if len(tratadas) and len(tratadas) % 25 == 0:
                mail.marcar_como_lidas([str(u) for u in tratadas[-25:]])
            if i % 50 == 0:
                log.info(f"  reproduzidos {i}/{len(ordem)}: {stats.curriculos_processados} currículo(s), "
                         f"{stats.excecoes_geradas} exceção(ões), {stats.duplicados_detectados} reenvio(s)")
        restante = len(tratadas) % 25
        if restante:
            mail.marcar_como_lidas([str(u) for u in tratadas[-restante:]])
    except Exception as e:
        erro_fatal = str(e)
        log.error(f"ERRO FATAL: {e}", exc_info=True)
    finally:
        caixa.fechar()
        ia._modo_lote = None
        pl._finalizar_execucao(exec_id, stats, erro_fatal)
    return {"tratadas": len(tratadas), "adiadas": dict(adiadas), "stats": stats.como_dict()}


# ─────────────────────────────────────────────
# Orquestração
# ─────────────────────────────────────────────
def rodar(args) -> None:
    pasta = Path(args.dir)
    pasta.mkdir(parents=True, exist_ok=True)
    estado = _ler_json(pasta / "estado.json", {"lotes": {}, "custo_usd": 0.0})
    if bd.ia_pausada():
        log.error("Envio à IA pausado no painel (Configurações → Zona de perigo): nada foi feito.")
        sys.exit(2)
    global _CFG
    cfg = _CFG = bd.carregar_configuracoes()
    areas = bd.listar_areas()
    _instalar_cache_de_extracao(pasta / "extracao")

    # 1. seleção
    selecao = _ler_json(pasta / "selecao.json", None)
    if selecao is None:
        selecao = selecionar(date.fromisoformat(args.ate), args.limite)
        _gravar_json(pasta / "selecao.json", selecao)
    log.info(f"Selecionados: {len(selecao)} e-mail(s) não lidos com anexo, recebidos antes de {args.ate}")
    if not selecao:
        return

    # 2. extração
    prep = preparar(pasta, selecao, args.processos)
    banco = _conhecido_no_banco()
    candidatos = candidatos_da_etapa_1(prep, selecao, banco)
    log.info(f"Etapa 1: {len(candidatos)} currículo(s) a identificar "
             f"({len(selecao) - len(candidatos)} e-mail(s) que o pipeline resolve sem IA: já no banco, repetidos ou sem texto)")

    # 3. lote 1: identificação
    ident = montar_identificacao(candidatos, cfg)
    if args.so_planejar:
        chars = sum(len(p["system"]) + len(p["messages"][0]["content"]) for p in ident.values())
        log.info(f"Só planejar: {len(ident)} pedido(s) de identificação, ~{chars // 3:,} tokens de entrada (estimativa por caracteres). Nada foi enviado.")
        return
    parou = _completar(estado, pasta, "identificacao", ident, TAMANHO_LOTE_IDENTIFICACAO, args.teto_usd)

    # 4. lote 2: perfil + qualificação (o plano é refeito a cada execução: quem já entrou no banco deixa de precisar)
    ia.respostas_lote = _carregar_respostas(pasta)
    etapa2 = montar_perfil_e_analise(candidatos, cfg, areas, banco)
    ia.respostas_lote = {}
    if not parou:
        parou = _completar(estado, pasta, "analise", etapa2["pedidos"], TAMANHO_LOTE_ANALISE, args.teto_usd)
    if parou:
        log.error(f"Parei antes de enviar tudo: {parou}. O que já foi respondido será gravado; o resto continua não lido.")

    # 5. reprodução
    plano = {int(k): v for k, v in etapa2["plano"].items()}
    ordem = [s["uid"] for s in selecao if s["uid"] in prep]
    resultado = reproduzir(pasta, ordem, plano, cfg, areas)
    _gravar_json(pasta / "resultado.json", {**resultado, "custo_usd": estado.get("custo_usd"), "parou": parou})
    log.info("=" * 60)
    log.info(f"Custo real dos lotes : US$ {estado.get('custo_usd', 0):.4f}")
    log.info(f"Tratadas (marcadas lidas): {resultado['tratadas']} | adiadas: {resultado['adiadas'] or 0}")
    log.info(f"Resumo do pipeline   : {resultado['stats']}")
    log.info("=" * 60)


def main() -> None:
    p = argparse.ArgumentParser(description="Recrutei — carga em lote (Batch API)")
    p.add_argument("--ate", required=True, metavar="AAAA-MM-DD", help="só e-mails recebidos ANTES desta data")
    p.add_argument("--dir", required=True, help="pasta de trabalho (repetir a pasta retoma a carga)")
    p.add_argument("--limite", type=int, default=0, help="só os N primeiros e-mails (piloto)")
    p.add_argument("--teto-usd", type=float, default=22.0, help="não envia lote que faça o custo passar disto")
    p.add_argument("--processos", type=int, default=3, help="processos de extração em paralelo")
    p.add_argument("--so-planejar", action="store_true", help="seleciona, extrai e monta os pedidos da etapa 1, sem enviar nada")
    rodar(p.parse_args())


if __name__ == "__main__":
    main()
