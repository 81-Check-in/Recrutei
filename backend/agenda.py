"""
Quando o robô trabalha (python main.py --continuo, ou --agendada = uma batida do cron).

O RH define em Configurações a janela de leitura da caixa de e-mail (fuso de Brasília): de quantos em quantos minutos lê
(leitura_intervalo_minutos), a partir de que hora (leitura_hora_inicio), até que hora (leitura_hora_fim, exclusiva) e em que dias da
semana (leitura_dias_semana: 1 = segunda ... 7 = domingo). Fora da janela o robô não lê e-mail nem analisa nada: só dá sinal de vida
para a tela Status. Configuração que falta ou está escrita errada cai no padrão de config.py, com aviso no log.
"""
import threading
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from typing import FrozenSet, Optional
from zoneinfo import ZoneInfo

from config import (
    FUSO_EXECUCAO, LEITURA_DIAS_PADRAO, LEITURA_FIM_PADRAO, LEITURA_INICIO_PADRAO, LEITURA_INTERVALO_PADRAO_MIN, log,
)

FUSO = ZoneInfo(FUSO_EXECUCAO)
CHAVE_INTERVALO = "leitura_intervalo_minutos"
CHAVE_INICIO = "leitura_hora_inicio"
CHAVE_FIM = "leitura_hora_fim"
CHAVE_DIAS = "leitura_dias_semana"

INTERVALO_MIN, INTERVALO_MAX = 1, 240       # minutos
TOLERANCIA = timedelta(seconds=20)          # uma batida que chega um pouco antes do intervalo completo ainda conta

# Pedido de encerramento (SIGTERM do deploy, Ctrl+C): quem trabalha em laço confere entre um item e outro e para com o resto intacto
encerrar = threading.Event()


@dataclass(frozen=True)
class Janela:
    inicio: time
    fim: time
    dias: FrozenSet[int]
    intervalo: timedelta

    def descricao(self) -> str:
        nomes = {1: "seg", 2: "ter", 3: "qua", 4: "qui", 5: "sex", 6: "sáb", 7: "dom"}
        return (f"{', '.join(nomes[d] for d in sorted(self.dias))}, {self.inicio:%H:%M} às {self.fim:%H:%M}, "
                f"a cada {int(self.intervalo.total_seconds() // 60)} min")


def interpretar_horario(valor) -> time:
    """"HH:MM" (ou "H:MM") -> time. ValueError se não for uma hora do dia."""
    texto = str(valor or "").strip()
    horas, dois_pontos, minutos = texto.partition(":")
    if not dois_pontos or not horas.isdigit() or not minutos.isdigit() or len(minutos) != 2:
        raise ValueError(f"horário inválido: {valor!r} (use HH:MM)")
    return time(int(horas), int(minutos))       # levanta ValueError se a hora ou o minuto estiver fora do intervalo


def interpretar_dias(valor) -> FrozenSet[int]:
    """Lista de dias ISO (1 = segunda ... 7 = domingo) -> conjunto. ValueError se vier vazia ou com dia que não existe."""
    if not isinstance(valor, (list, tuple, set, frozenset)) or not valor:
        raise ValueError(f"dias da semana inválidos: {valor!r} (use uma lista como [1,2,3,4,5,6])")
    dias = set()
    for d in valor:
        if isinstance(d, bool) or not isinstance(d, (int, str)) or not str(d).strip().isdigit() or not 1 <= int(d) <= 7:
            raise ValueError(f"dia da semana inválido: {d!r} (1 = segunda ... 7 = domingo)")
        dias.add(int(d))
    return frozenset(dias)


def interpretar_intervalo(valor) -> int:
    """Minutos entre uma leitura e a seguinte. ValueError se não for um número inteiro entre INTERVALO_MIN e INTERVALO_MAX."""
    try:
        if isinstance(valor, bool) or float(valor) != int(float(valor)):
            raise ValueError
        minutos = int(float(valor))
    except (TypeError, ValueError):
        raise ValueError(f"intervalo inválido: {valor!r} (minutos, número inteiro)") from None
    if not INTERVALO_MIN <= minutos <= INTERVALO_MAX:
        raise ValueError(f"intervalo fora do limite: {minutos} (de {INTERVALO_MIN} a {INTERVALO_MAX} minutos)")
    return minutos


_invalidos_avisados: set = set()


def _ou_padrao(cfg: dict, chave: str, interpretar, padrao):
    """Falta a configuração: usa o padrão em silêncio. Está escrita errada: usa o padrão e avisa UMA vez por valor (o ciclo roda a cada 30 s)."""
    valor = cfg.get(chave)
    try:
        return interpretar(valor)
    except ValueError:
        if valor is not None and (chave, repr(valor)) not in _invalidos_avisados:
            _invalidos_avisados.add((chave, repr(valor)))
            log.warning(f"Configuração {chave} inválida ({valor!r}): usando o padrão")
        return interpretar(padrao)


def janela_configurada(cfg: dict) -> Janela:
    """A janela de Configurações. Cada campo que faltar ou estiver errado cai no padrão sozinho. Fim antes do início vale o padrão dos dois."""
    inicio = _ou_padrao(cfg, CHAVE_INICIO, interpretar_horario, LEITURA_INICIO_PADRAO)
    fim = _ou_padrao(cfg, CHAVE_FIM, interpretar_horario, LEITURA_FIM_PADRAO)
    if fim <= inicio:
        log.warning(f"Janela de leitura invertida ({inicio:%H:%M} a {fim:%H:%M}): usando {LEITURA_INICIO_PADRAO} a {LEITURA_FIM_PADRAO}")
        inicio, fim = interpretar_horario(LEITURA_INICIO_PADRAO), interpretar_horario(LEITURA_FIM_PADRAO)
    dias = _ou_padrao(cfg, CHAVE_DIAS, interpretar_dias, list(LEITURA_DIAS_PADRAO))
    minutos = _ou_padrao(cfg, CHAVE_INTERVALO, interpretar_intervalo, LEITURA_INTERVALO_PADRAO_MIN)
    return Janela(inicio, fim, dias, timedelta(minutes=minutos))


def dentro_da_janela(agora: datetime, janela: Janela) -> bool:
    """Hoje é um dos dias e a hora está em [início, fim) no fuso de Brasília?"""
    agora = agora.astimezone(FUSO)
    return agora.isoweekday() in janela.dias and janela.inicio <= agora.time().replace(tzinfo=None) < janela.fim


def leitura_devida(agora: datetime, ultima: Optional[datetime], janela: Janela, tolerancia: timedelta = TOLERANCIA) -> bool:
    """É hora de ler a caixa? Dentro da janela e já passou o intervalo desde a última leitura (ou nunca leu), com uma folga."""
    if not dentro_da_janela(agora, janela):
        return False
    return ultima is None or agora - ultima >= janela.intervalo - tolerancia


def proxima_leitura(agora: datetime, ultima: Optional[datetime], janela: Janela) -> datetime:
    """Quando será a próxima leitura: o fim do intervalo se cair na janela; senão a próxima abertura dela (início de um dia útil)."""
    agora = agora.astimezone(FUSO)
    alvo = max(agora, ultima.astimezone(FUSO) + janela.intervalo) if ultima else agora
    if dentro_da_janela(alvo, janela):
        return alvo
    for adiante in range(0, 9):                                    # dentro de uma semana sempre há um dia da janela
        dia = alvo.date() + timedelta(days=adiante)
        abertura = datetime.combine(dia, janela.inicio, tzinfo=FUSO)
        if dia.isoweekday() in janela.dias and abertura >= alvo:
            return abertura
    return alvo + timedelta(days=1)                                # inalcançável com dias válidos; só para nunca devolver None
