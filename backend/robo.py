"""
O robô em tempo (quase) real.

  python main.py --continuo   fica ligado (Railway sem Cron Schedule) e a cada PEDIDOS_DO_RH_CADA_S segundos faz um ciclo
  python main.py --agendada   um único ciclo (para quem prefere o Cron Schedule do Railway: no mínimo de 5 em 5 minutos)

Um ciclo, dentro da janela de Configurações (dias e horário; ver agenda.py):
  1. PEDIDOS DO RH, na hora: exceção marcada para "tentar de novo", currículo enviado à mão e reanálise pedida no painel;
  2. LEITURA DOS E-MAILS, a cada leitura_intervalo_minutos (padrão 10): puxa os não lidos e analisa;
  3. a manutenção do banco (partições, arquivos excluídos, sanitização) na primeira leitura de cada dia.
Fora da janela não lê nada nem gasta IA; só dá sinal de vida. Em todo passo a tela Status recebe o andamento (status_robo.py).
Só uma instância trabalha por vez (reserva no banco): um deploy que sobrepõe a instância velha e a nova não lê a caixa em dobro.
"""
import signal
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Dict, Optional

import agenda
import database as bd
import leitor_email as mail
import pipeline
import status_robo
from config import LIMITE_EMAILS, LIMITE_POR_LEITURA_PADRAO, PEDIDOS_DO_RH_CADA_S, log

SINAL_A_CADA = timedelta(seconds=55)          # o sinal de vida vai ao banco no máximo uma vez por minuto
ESPERA_REANALISE = timedelta(minutes=10)      # reanálise que falhou (fica pendente) só é tentada de novo depois disto: cada tentativa gasta IA


@dataclass
class Estado:
    """O que o robô lembra entre um ciclo e outro (na memória; o essencial também fica gravado em pipeline_status)."""
    ultima_leitura: Optional[datetime] = None
    ultima_manutencao: Optional[date] = None
    reanalise_liberada_em: Optional[datetime] = None
    ultimo_sinal: Optional[datetime] = None
    ultimo_estado: Optional[str] = None
    carregado: bool = False


def _sinal(estado: Estado, agora: datetime, novo_estado: str, proxima: Optional[datetime], atividade: Optional[str] = None) -> None:
    """Sinal de vida sem repetir a mesma coisa a cada 30 s."""
    if estado.ultimo_sinal and novo_estado == estado.ultimo_estado and agora - estado.ultimo_sinal < SINAL_A_CADA:
        return
    status_robo.sinal(novo_estado, proxima_leitura=proxima, atividade=atividade)
    estado.ultimo_sinal, estado.ultimo_estado = agora, novo_estado


def _contar_nao_lidos() -> Optional[int]:
    try:
        cursor_uid, cursor_validade = bd.obter_cursor_imap()
        return mail.contar_nao_lidos(cursor_uid, cursor_validade)
    except Exception as e:                    # a caixa fora do ar não pode derrubar o ciclo; a tela mostra o número antigo com a hora dele
        log.warning(f"Não consegui contar os e-mails não lidos ({type(e).__name__})")
        return None


def _pedidos_do_rh(estado: Estado, agora: datetime) -> Dict[str, int]:
    """Quantos pedidos do RH esperam agora. A reanálise que falhou espera ESPERA_REANALISE antes de ser tentada outra vez."""
    pedidos = {"excecoes": len(bd.listar_excecoes_para_reprocessar()),
               "envios_manuais": len(bd.listar_uploads_manuais_pendentes())}
    if estado.reanalise_liberada_em is None or agora >= estado.reanalise_liberada_em:
        pedidos["reanalises"] = len(bd.listar_reanalises(1))
    return {k: v for k, v in pedidos.items() if v}


def _atender_pedidos(estado: Estado, agora: datetime, pedidos: Dict[str, int]) -> None:
    status_robo.processando(sum(pedidos.values()), "Pedidos do RH: " + ", ".join(
        {"excecoes": "tentar de novo", "envios_manuais": "currículo enviado", "reanalises": "reanálise"}[k] for k in pedidos))
    if "excecoes" in pedidos:
        pipeline.reprocessar_excecoes()
    if "envios_manuais" in pedidos:
        pipeline.processar_uploads_manuais()
    if "reanalises" in pedidos:
        pipeline.reanalisar()
        ainda = bd.listar_reanalises(1)
        estado.reanalise_liberada_em = agora + ESPERA_REANALISE if ainda else None      # falhou: não insiste a cada 30 s


def ciclo(estado: Estado, agora: Optional[datetime] = None, tolerancia: timedelta = agenda.TOLERANCIA) -> str:
    """
    Um ciclo do robô. Devolve o que aconteceu: "pausado", "fora_do_horario", "ocioso", "pedidos", "leitura" (pode incluir pedidos) ou
    "ocupado" (outra instância está com o trabalho).
    """
    agora = agora or datetime.now(agenda.FUSO)
    cfg = bd.carregar_configuracoes()
    janela = agenda.janela_configurada(cfg)
    if not estado.carregado:
        estado.ultima_leitura, estado.carregado = status_robo.ultima_checagem(), True     # uma reinicialização não repete a leitura na hora
    proxima = agenda.proxima_leitura(agora, estado.ultima_leitura, janela)

    if bd.ia_pausada():
        _sinal(estado, agora, "pausado", proxima)
        return "pausado"
    if not agenda.dentro_da_janela(agora, janela):
        _sinal(estado, agora, "fora_do_horario", proxima)
        return "fora_do_horario"

    pedidos = _pedidos_do_rh(estado, agora)
    ler_caixa = agenda.leitura_devida(agora, estado.ultima_leitura, janela, tolerancia)
    if not pedidos and not ler_caixa:
        _sinal(estado, agora, "ocioso", proxima)
        return "ocioso"

    if not status_robo.reservar():
        return "ocupado"
    try:
        feito = "pedidos"
        if pedidos:
            _atender_pedidos(estado, agora, pedidos)
        if ler_caixa:
            feito = "leitura"
            _ler_caixa(estado, agora, janela)
        else:
            status_robo.sinal("ocioso", proxima_leitura=agenda.proxima_leitura(agora, estado.ultima_leitura, janela))
            estado.ultimo_sinal, estado.ultimo_estado = agora, "ocioso"
        return feito
    finally:
        status_robo.liberar()


def _ler_caixa(estado: Estado, agora: datetime, janela: agenda.Janela) -> None:
    """
    Olha a caixa: conta os não lidos e, havendo, roda a leitura (no máximo LIMITE_EMAILS, ou 50, de uma vez; o resto fica para a
    próxima). Sem nada a ler não abre uma execução no histórico nem apaga o resultado da última leitura na tela. A primeira checagem
    do dia roda sempre, para fazer a manutenção do banco.
    """
    estado.ultima_leitura = agora
    status_robo.marcar_checagem(agora)
    aguardando = _contar_nao_lidos()
    if aguardando is not None:
        status_robo.nao_lidos(aguardando)
    manutencao = estado.ultima_manutencao != agora.date()
    if aguardando == 0 and not manutencao:
        status_robo.sinal("ocioso", proxima_leitura=agenda.proxima_leitura(agora, agora, janela))
        estado.ultimo_sinal, estado.ultimo_estado = agora, "ocioso"
        return
    status_robo.marcar_leitura(agora)
    resultado = pipeline.executar(manutencao=manutencao, limite=LIMITE_EMAILS or LIMITE_POR_LEITURA_PADRAO)
    if manutencao and not resultado.get("erro"):
        estado.ultima_manutencao = agora.date()
    restantes = _contar_nao_lidos()
    if restantes is not None:
        status_robo.nao_lidos(restantes)
    resumo = {k: resultado.get(k) for k in
              ("emails_lidos", "curriculos_processados", "excecoes_geradas", "duplicados_detectados", "custo_estimado_usd")}
    status_robo.concluir(resumo, resultado.get("erro"),
                         agenda.proxima_leitura(datetime.now(agenda.FUSO), estado.ultima_leitura, janela))
    estado.ultimo_sinal, estado.ultimo_estado = datetime.now(agenda.FUSO), "ocioso"


def uma_batida() -> str:
    """python main.py --agendada: um ciclo e sai. O Cron Schedule do Railway atrasa a partida do contêiner: a folga do intervalo é maior."""
    return ciclo(Estado(), tolerancia=timedelta(minutes=2))


def continuo() -> int:
    """python main.py --continuo: o laço do robô. SIGTERM/Ctrl+C terminam o ciclo em curso (entre um e-mail e outro) e saem."""
    def parar(signum, frame):
        log.warning("Pedido de encerramento recebido: termino o item em curso e saio")
        agenda.encerrar.set()

    signal.signal(signal.SIGTERM, parar)
    signal.signal(signal.SIGINT, parar)
    estado = Estado()
    falhas = 0
    log.info(f"Robô contínuo no ar: um ciclo a cada {PEDIDOS_DO_RH_CADA_S} s (janela de leitura em Configurações)")
    while not agenda.encerrar.is_set():
        try:
            ciclo(estado)
            falhas = 0
        except Exception as e:                # o robô nunca morre por um ciclo ruim: registra, avisa a tela e tenta de novo com espera crescente
            falhas += 1
            log.error(f"Erro no ciclo do robô ({falhas}ª vez seguida): {e}", exc_info=True)
            status_robo.sinal("erro", ultimo_erro=str(e)[:300], ultimo_erro_em=datetime.now(agenda.FUSO).isoformat())
        agenda.encerrar.wait(PEDIDOS_DO_RH_CADA_S if not falhas else min(300, PEDIDOS_DO_RH_CADA_S * 2 ** min(falhas, 4)))
    log.info("Robô encerrado")
    return 0
