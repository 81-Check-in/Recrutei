"""
Andamento do robô para a tela Status do painel (tabela pipeline_status, uma linha só; migração 046).

O painel só LÊ essa linha; quem escreve é o robô (chave de serviço). Tudo aqui é "melhor esforço": se o banco falhar na hora de contar
o que está acontecendo, a leitura dos e-mails NÃO pode parar por causa do painel — o erro vai para o log e o robô segue.

Estados: "ocioso" (esperando a próxima leitura), "processando", "fora_do_horario", "pausado" (IA pausada em Configurações) e "erro".
verificado_em é o sinal de vida: o painel mostra "sem sinal do robô" quando ele fica velho demais.
"""
import os
import re
import socket
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional

import database as bd
from config import LEASE_MINUTOS, MODO_SIMULACAO, log

TABELA = "pipeline_status"
DONO = re.sub(r"[^A-Za-z0-9_-]", "-", f"{socket.gethostname()}-{os.getpid()}")   # identifica esta instância na reserva do trabalho (só caracteres seguros num filtro)


def _agora() -> datetime:
    return datetime.now(timezone.utc)


def _iso(momento: Optional[datetime]) -> Optional[str]:
    return momento.astimezone(timezone.utc).isoformat() if momento else None


def _gravar(campos: Dict[str, Any]) -> None:
    if MODO_SIMULACAO:
        return
    try:
        bd.conectar().table(TABELA).upsert({"id": True, "verificado_em": _iso(_agora()), "atualizado_em": _iso(_agora()), **campos},
                                           on_conflict="id").execute()
    except Exception as e:                                # nunca derruba o robô por causa da tela de status
        log.warning(f"Não consegui atualizar o status do robô ({type(e).__name__})")


def ler() -> Dict[str, Any]:
    """A linha de status como está no banco ({} se ainda não existe ou não deu para ler)."""
    try:
        r = bd.conectar().table(TABELA).select("*").eq("id", True).limit(1).execute().data
        return r[0] if r else {}
    except Exception as e:
        log.warning(f"Não consegui ler o status do robô ({type(e).__name__})")
        return {}


def sinal(estado: str, proxima_leitura: Optional[datetime] = None, atividade: Optional[str] = None, **extra) -> None:
    """Sinal de vida: o estado agora e, quando se sabe, quando é a próxima leitura. Zera o andamento se não está processando."""
    campos: Dict[str, Any] = {"estado": estado, "atividade": atividade, "proxima_leitura_em": _iso(proxima_leitura), **extra}
    if estado != "processando":
        campos.update(processando_total=0, processando_feitos=0, processando_desde=None)
    _gravar(campos)


def nao_lidos(quantos: int) -> None:
    _gravar({"nao_lidos": quantos, "nao_lidos_em": _iso(_agora())})


def processando(total: int, atividade: str) -> None:
    """Começou a tratar `total` itens (e-mails ou pedidos do RH)."""
    _gravar({"estado": "processando", "atividade": atividade, "processando_total": total, "processando_feitos": 0,
             "processando_desde": _iso(_agora())})


def avancar(feitos: int) -> None:
    _gravar({"processando_feitos": feitos})


def concluir(resumo: Dict[str, Any], erro: Optional[str], proxima_leitura: Optional[datetime]) -> None:
    """Terminou a leitura: guarda o resultado, volta a "ocioso" (ou "erro") e zera o andamento."""
    _gravar({"estado": "erro" if erro else "ocioso", "atividade": None, "processando_total": 0, "processando_feitos": 0,
             "processando_desde": None, "ultima_leitura_fim": _iso(_agora()), "ultima_leitura_sucesso": erro is None,
             "ultima_leitura_resumo": resumo, "ultimo_erro": erro, "ultimo_erro_em": _iso(_agora()) if erro else None,
             "proxima_leitura_em": _iso(proxima_leitura)})


def marcar_checagem(momento: datetime) -> None:
    """O robô olhou a caixa: é daqui que o próximo intervalo é contado (sobrevive a uma reinicialização do robô)."""
    _gravar({"ultima_checagem_em": _iso(momento)})


def marcar_leitura(inicio: datetime) -> None:
    """Começou uma leitura COM e-mails a tratar (a tela mostra o resultado dela em "Última leitura")."""
    _gravar({"ultima_leitura_em": _iso(inicio)})


def ultima_checagem() -> Optional[datetime]:
    valor = ler().get("ultima_checagem_em")
    try:
        return datetime.fromisoformat(str(valor).replace("Z", "+00:00")) if valor else None
    except ValueError:
        return None


# ── Reserva do trabalho: só uma instância do robô lê a caixa por vez (deploy que sobrepõe a instância velha e a nova) ──
def reservar(minutos: int = LEASE_MINUTOS, dono: str = DONO) -> bool:
    """
    True = esta instância ficou com o trabalho pelos próximos `minutos` (ou já o tinha). False = outra instância está com ele.
    Sem banco não há como saber: na dúvida NÃO trabalha (melhor um ciclo perdido que duas leituras da mesma caixa).
    """
    if MODO_SIMULACAO:
        return True
    try:
        agora = _agora()
        ate = _iso(agora + timedelta(minutes=minutos))
        db = bd.conectar()
        db.table(TABELA).upsert({"id": True}, on_conflict="id", ignore_duplicates=True).execute()      # garante a linha
        agora_z = agora.strftime("%Y-%m-%dT%H:%M:%SZ")                    # sem "+00:00": o "+" viraria espaço na URL do filtro
        r = db.table(TABELA).update({"lease_dono": dono, "lease_ate": ate}).eq("id", True)\
              .or_(f"lease_dono.is.null,lease_dono.eq.{dono},lease_ate.lt.{agora_z}").execute().data
        return bool(r)
    except Exception as e:
        log.warning(f"Não consegui reservar o trabalho do robô ({type(e).__name__}): este ciclo não roda. "
                    "A migração 046 (tabela pipeline_status) foi aplicada no Supabase?")
        return False


def liberar(dono: str = DONO) -> None:
    """Devolve a reserva ao terminar (a próxima instância, ou este mesmo robô no ciclo seguinte, pega sem esperar o prazo)."""
    if MODO_SIMULACAO:
        return
    try:
        bd.conectar().table(TABELA).update({"lease_dono": None, "lease_ate": None}).eq("id", True).eq("lease_dono", dono).execute()
    except Exception as e:
        log.warning(f"Não consegui liberar a reserva do robô ({type(e).__name__})")
