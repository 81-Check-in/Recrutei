"""
Testes do robô em tempo (quase) real: a janela de leitura (agenda.py), o andamento para a tela Status (status_robo.py), o ciclo e o laço
(robo.py), a contagem de não lidos (leitor_email.py) e o que mudou em pipeline.executar. Sem rede: Supabase, IMAP e Claude são simulados.

    cd backend && .venv/bin/python -m unittest discover -s tests -v
"""
import os
import sys
import unittest
from contextlib import contextmanager
from datetime import datetime, time, timedelta, timezone
from unittest.mock import MagicMock, patch

for chave, valor in {
    "SUPABASE_URL": "http://supabase.test", "SUPABASE_SERVICE_KEY": "chave", "ANTHROPIC_API_KEY": "chave",
    "IMAP_USUARIO": "vagas@empresa.test", "IMAP_SENHA": "senha", "IDENTIDADE_CHAVE": "x" * 40,
}.items():
    os.environ[chave] = valor
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import agenda          # noqa: E402
import leitor_email    # noqa: E402
import pipeline        # noqa: E402
import robo            # noqa: E402
import status_robo     # noqa: E402

BR = agenda.FUSO


def br(dia, hora, minuto=0, segundo=0):
    """Setembro de 2026: 26 é sábado, 27 é domingo, 28 é segunda."""
    return datetime(2026, 9, dia, hora, minuto, segundo, tzinfo=BR)


PADRAO = agenda.janela_configurada({})


class TestJanelaDeLeitura(unittest.TestCase):
    def setUp(self):
        agenda._invalidos_avisados.clear()

    def test_padrao_e_o_pedido_seg_a_sab_0730_as_1800_a_cada_10_min(self):
        j = agenda.janela_configurada({})
        self.assertEqual((j.inicio, j.fim), (time(7, 30), time(18, 0)))
        self.assertEqual(j.dias, frozenset({1, 2, 3, 4, 5, 6}))
        self.assertEqual(j.intervalo, timedelta(minutes=10))
        self.assertEqual(j.descricao(), "seg, ter, qua, qui, sex, sáb, 07:30 às 18:00, a cada 10 min")

    def test_configuracoes_do_painel_valem(self):
        j = agenda.janela_configurada({"leitura_hora_inicio": "08:00", "leitura_hora_fim": "17:30",
                                       "leitura_dias_semana": [1, 2, 3, 4, 5], "leitura_intervalo_minutos": 15})
        self.assertEqual((j.inicio, j.fim, j.dias, j.intervalo), (time(8, 0), time(17, 30), frozenset({1, 2, 3, 4, 5}), timedelta(minutes=15)))

    def test_cada_campo_estragado_cai_no_padrao_sozinho(self):
        j = agenda.janela_configurada({"leitura_hora_inicio": "de manhã", "leitura_hora_fim": "17:30",
                                       "leitura_dias_semana": [], "leitura_intervalo_minutos": "muito"})
        self.assertEqual(j.inicio, time(7, 30))                    # o inválido volta ao padrão
        self.assertEqual(j.fim, time(17, 30))                      # o válido é mantido
        self.assertEqual(j.dias, frozenset({1, 2, 3, 4, 5, 6}))
        self.assertEqual(j.intervalo, timedelta(minutes=10))

    def test_janela_invertida_ou_vazia_volta_ao_padrao_dos_dois_horarios(self):
        for inicio, fim in (("18:00", "07:30"), ("09:00", "09:00")):
            j = agenda.janela_configurada({"leitura_hora_inicio": inicio, "leitura_hora_fim": fim})
            self.assertEqual((j.inicio, j.fim), (time(7, 30), time(18, 0)), (inicio, fim))

    def test_aviso_de_configuracao_invalida_sai_uma_vez_so_e_faltar_nao_avisa(self):
        with patch.object(agenda, "log") as log:
            for _ in range(5):
                agenda.janela_configurada({"leitura_intervalo_minutos": "xis"})
            self.assertEqual(log.warning.call_count, 1)             # o ciclo roda a cada 30 s: sem repetir o aviso
        with patch.object(agenda, "log") as log:
            agenda.janela_configurada({})                           # configuração ausente usa o padrão em silêncio
            log.warning.assert_not_called()

    def test_interpretar_horario(self):
        self.assertEqual(agenda.interpretar_horario("07:30"), time(7, 30))
        self.assertEqual(agenda.interpretar_horario(" 8:05 "), time(8, 5))
        for ruim in ("", None, "7", "07:5", "24:00", "12:60", "meio-dia", "07-30"):
            with self.assertRaises(ValueError, msg=repr(ruim)):
                agenda.interpretar_horario(ruim)

    def test_interpretar_dias(self):
        self.assertEqual(agenda.interpretar_dias([1, 2, 3]), frozenset({1, 2, 3}))
        self.assertEqual(agenda.interpretar_dias(["1", 7]), frozenset({1, 7}))
        for ruim in ([], None, [0], [8], "1,2", [True], [1.5], ["x"], 3):
            with self.assertRaises(ValueError, msg=repr(ruim)):
                agenda.interpretar_dias(ruim)

    def test_interpretar_intervalo(self):
        self.assertEqual([agenda.interpretar_intervalo(v) for v in (10, "10", 10.0, 1, 240)], [10, 10, 10, 1, 240])
        for ruim in (0, 241, -5, "abc", 7.5, None, True, ""):
            with self.assertRaises(ValueError, msg=repr(ruim)):
                agenda.interpretar_intervalo(ruim)

    def test_dentro_da_janela_nas_bordas(self):
        self.assertFalse(agenda.dentro_da_janela(br(26, 7, 29, 59), PADRAO))
        self.assertTrue(agenda.dentro_da_janela(br(26, 7, 30), PADRAO))          # sábado abre 07:30
        self.assertTrue(agenda.dentro_da_janela(br(26, 17, 59, 59), PADRAO))
        self.assertFalse(agenda.dentro_da_janela(br(26, 18, 0), PADRAO))         # 18:00 já não lê
        self.assertFalse(agenda.dentro_da_janela(br(27, 10, 0), PADRAO))         # domingo não
        self.assertTrue(agenda.dentro_da_janela(br(28, 7, 30), PADRAO))          # segunda sim
        self.assertFalse(agenda.dentro_da_janela(br(28, 3, 0), PADRAO))          # madrugada não

    def test_o_relogio_do_servidor_pode_estar_em_utc(self):
        utc = lambda h, m: datetime(2026, 9, 26, h, m, tzinfo=timezone.utc)
        self.assertTrue(agenda.dentro_da_janela(utc(10, 30), PADRAO))            # 10:30 UTC = 07:30 em Brasília
        self.assertFalse(agenda.dentro_da_janela(utc(10, 29), PADRAO))
        self.assertFalse(agenda.dentro_da_janela(utc(21, 0), PADRAO))            # 21:00 UTC = 18:00 em Brasília

    def test_so_dias_uteis_quando_o_painel_tira_o_sabado(self):
        j = agenda.janela_configurada({"leitura_dias_semana": [1, 2, 3, 4, 5]})
        self.assertFalse(agenda.dentro_da_janela(br(26, 10, 0), j))
        self.assertTrue(agenda.dentro_da_janela(br(28, 10, 0), j))

    def test_leitura_devida_respeita_o_intervalo_com_uma_folga_pequena(self):
        agora = br(26, 10, 0)
        self.assertTrue(agenda.leitura_devida(agora, None, PADRAO))                          # nunca leu
        self.assertFalse(agenda.leitura_devida(agora, agora - timedelta(minutes=9, seconds=30), PADRAO))
        self.assertTrue(agenda.leitura_devida(agora, agora - timedelta(minutes=9, seconds=45), PADRAO))   # dentro da folga de 20 s
        self.assertTrue(agenda.leitura_devida(agora, agora - timedelta(minutes=10), PADRAO))
        self.assertFalse(agenda.leitura_devida(br(27, 10, 0), None, PADRAO))                 # fora da janela nunca é devida
        self.assertFalse(agenda.leitura_devida(br(26, 18, 0), br(26, 9, 0), PADRAO))

    def test_folga_maior_para_o_cron(self):
        agora = br(26, 10, 0)
        ultima = agora - timedelta(minutes=8, seconds=30)
        self.assertFalse(agenda.leitura_devida(agora, ultima, PADRAO))
        self.assertTrue(agenda.leitura_devida(agora, ultima, PADRAO, timedelta(minutes=2)))

    def test_proxima_leitura(self):
        self.assertEqual(agenda.proxima_leitura(br(26, 10, 0), br(26, 9, 55), PADRAO), br(26, 10, 5))     # fim do intervalo
        self.assertEqual(agenda.proxima_leitura(br(26, 10, 0), None, PADRAO), br(26, 10, 0))              # nunca leu: agora
        self.assertEqual(agenda.proxima_leitura(br(26, 10, 30), br(26, 10, 0), PADRAO), br(26, 10, 30))   # atrasada: agora
        self.assertEqual(agenda.proxima_leitura(br(26, 17, 58), br(26, 17, 55), PADRAO), br(28, 7, 30))   # 18:05 já é fora: segunda 07:30
        self.assertEqual(agenda.proxima_leitura(br(26, 20, 0), br(26, 17, 50), PADRAO), br(28, 7, 30))    # sábado à noite → segunda
        self.assertEqual(agenda.proxima_leitura(br(27, 12, 0), None, PADRAO), br(28, 7, 30))              # domingo → segunda
        self.assertEqual(agenda.proxima_leitura(br(28, 5, 0), None, PADRAO), br(28, 7, 30))               # madrugada → hoje 07:30
        quarta = agenda.janela_configurada({"leitura_dias_semana": [3]})                                  # 30/09/2026 é quarta
        self.assertEqual(agenda.proxima_leitura(br(28, 9, 0), None, quarta), br(30, 7, 30))


class TestStatusDoRobo(unittest.TestCase):
    def setUp(self):
        self.gravado = []
        p = patch.object(status_robo, "_gravar", side_effect=self.gravado.append)
        p.start()
        self.addCleanup(p.stop)

    def test_sinal_fora_de_processando_zera_o_andamento(self):
        status_robo.sinal("ocioso", proxima_leitura=br(26, 10, 5))
        c = self.gravado[-1]
        self.assertEqual((c["estado"], c["processando_total"], c["processando_feitos"], c["processando_desde"]), ("ocioso", 0, 0, None))
        self.assertIn("2026-09-26T13:05:00", c["proxima_leitura_em"])           # 10:05 em Brasília = 13:05 UTC

    def test_processando_e_avancar(self):
        status_robo.processando(12, "Lendo os e-mails da caixa")
        self.assertEqual((self.gravado[-1]["estado"], self.gravado[-1]["processando_total"], self.gravado[-1]["processando_feitos"]),
                         ("processando", 12, 0))
        status_robo.avancar(5)
        self.assertEqual(self.gravado[-1], {"processando_feitos": 5})

    def test_concluir_com_sucesso_e_com_erro(self):
        status_robo.concluir({"emails_lidos": 3}, None, None)
        c = self.gravado[-1]
        self.assertEqual((c["estado"], c["ultima_leitura_sucesso"], c["ultimo_erro"], c["ultima_leitura_resumo"]), ("ocioso", True, None, {"emails_lidos": 3}))
        status_robo.concluir({"emails_lidos": 1}, "IMAP caiu", None)
        c = self.gravado[-1]
        self.assertEqual((c["estado"], c["ultima_leitura_sucesso"], c["ultimo_erro"]), ("erro", False, "IMAP caiu"))
        self.assertIsNotNone(c["ultimo_erro_em"])

    def test_ultima_checagem_lida_do_banco(self):
        with patch.object(status_robo, "ler", return_value={"ultima_checagem_em": "2026-09-26T13:00:00+00:00"}):
            self.assertEqual(status_robo.ultima_checagem(), datetime(2026, 9, 26, 13, 0, tzinfo=timezone.utc))
        with patch.object(status_robo, "ler", return_value={}):
            self.assertIsNone(status_robo.ultima_checagem())
        with patch.object(status_robo, "ler", return_value={"ultima_checagem_em": "lixo"}):
            self.assertIsNone(status_robo.ultima_checagem())

    def test_checagem_e_leitura_sao_campos_diferentes(self):
        status_robo.marcar_checagem(br(26, 10, 0))
        self.assertEqual(list(self.gravado[-1]), ["ultima_checagem_em"])       # olhar a caixa não apaga o resultado da última leitura
        status_robo.marcar_leitura(br(26, 10, 0))
        self.assertEqual(list(self.gravado[-1]), ["ultima_leitura_em"])


class TestGravacaoDoStatus(unittest.TestCase):
    """_gravar de verdade (com o banco simulado): melhor esforço, nunca derruba o robô."""

    def test_falha_do_banco_nao_levanta(self):
        with patch.object(status_robo.bd, "conectar", side_effect=RuntimeError("banco fora")):
            status_robo._gravar({"estado": "ocioso"})                   # não pode levantar
            self.assertEqual(status_robo.ler(), {})

    def test_simulacao_nao_grava(self):
        with patch.object(status_robo, "MODO_SIMULACAO", True), patch.object(status_robo.bd, "conectar") as conectar:
            status_robo._gravar({"estado": "ocioso"})
            self.assertTrue(status_robo.reservar())
            status_robo.liberar()
        conectar.assert_not_called()

    def test_grava_com_upsert_na_linha_unica(self):
        db = MagicMock()
        with patch.object(status_robo.bd, "conectar", return_value=db):
            status_robo._gravar({"estado": "processando"})
        tabela = db.table.return_value
        self.assertEqual(db.table.call_args.args, ("pipeline_status",))
        linha = tabela.upsert.call_args.args[0]
        self.assertEqual((linha["id"], linha["estado"]), (True, "processando"))
        self.assertIn("verificado_em", linha)                            # todo gravar é sinal de vida
        self.assertEqual(tabela.upsert.call_args.kwargs, {"on_conflict": "id"})


class TestReservaDoTrabalho(unittest.TestCase):
    def _db(self, linhas=None, erro=None):
        db = MagicMock()
        atualizar = db.table.return_value.update.return_value.eq.return_value.or_.return_value.execute
        if erro:
            atualizar.side_effect = erro
        else:
            atualizar.return_value.data = linhas
        return db

    def test_pega_a_reserva_livre(self):
        db = self._db([{"id": True}])
        with patch.object(status_robo.bd, "conectar", return_value=db):
            self.assertTrue(status_robo.reservar(dono="robo-1"))
        filtro = db.table.return_value.update.return_value.eq.return_value.or_.call_args.args[0]
        self.assertIn("lease_dono.is.null", filtro)
        self.assertIn("lease_dono.eq.robo-1", filtro)                    # a própria instância renova a reserva
        self.assertIn("lease_ate.lt.", filtro)                           # reserva vencida vale como livre
        self.assertNotIn("+", filtro)                                    # o "+" do fuso viraria espaço na URL
        gravado = db.table.return_value.update.call_args.args[0]
        self.assertEqual(gravado["lease_dono"], "robo-1")

    def test_reserva_de_outra_instancia_bloqueia(self):
        with patch.object(status_robo.bd, "conectar", return_value=self._db([])):
            self.assertFalse(status_robo.reservar(dono="robo-2"))

    def test_na_duvida_nao_trabalha(self):
        with patch.object(status_robo.bd, "conectar", return_value=self._db(erro=RuntimeError("sem banco"))):
            self.assertFalse(status_robo.reservar())

    def test_liberar_so_a_propria_reserva(self):
        db = MagicMock()
        with patch.object(status_robo.bd, "conectar", return_value=db):
            status_robo.liberar(dono="robo-1")
        cadeia = db.table.return_value.update.return_value.eq
        self.assertEqual(db.table.return_value.update.call_args.args[0], {"lease_dono": None, "lease_ate": None})
        cadeia.return_value.eq.assert_called_once_with("lease_dono", "robo-1")


class CicloBase(unittest.TestCase):
    """Roda robo.ciclo com o banco, a caixa, o status e o pipeline simulados."""

    def setUp(self):
        self.bd = MagicMock()
        self.bd.carregar_configuracoes.return_value = {}
        self.bd.ia_pausada.return_value = False
        self.bd.listar_excecoes_para_reprocessar.return_value = []
        self.bd.listar_uploads_manuais_pendentes.return_value = []
        self.bd.listar_reanalises.return_value = []
        self.bd.obter_cursor_imap.return_value = (195303, 1)
        self.status = MagicMock()
        self.status.ultima_checagem.return_value = None
        self.status.reservar.return_value = True
        self.pipeline = MagicMock()
        self.pipeline.executar.return_value = {"emails_lidos": 4, "curriculos_processados": 3, "excecoes_geradas": 1,
                                               "duplicados_detectados": 0, "custo_estimado_usd": 0.06, "erro": None, "interrompida": False}
        self.mail = MagicMock()
        self.mail.contar_nao_lidos.side_effect = [6, 2]                 # antes e depois da leitura
        for alvo, falso in (("bd", self.bd), ("status_robo", self.status), ("pipeline", self.pipeline), ("mail", self.mail),
                            ("LIMITE_EMAILS", 0)):                      # sem a variável do Railway; o .env de quem roda os testes não vaza
            p = patch.object(robo, alvo, falso)
            p.start()
            self.addCleanup(p.stop)
        agenda._invalidos_avisados.clear()

    def ciclo(self, agora, estado=None, **k):
        estado = estado or robo.Estado()
        return robo.ciclo(estado, agora, **k), estado


class TestCicloDoRobo(CicloBase):
    def test_ia_pausada_so_da_sinal(self):
        self.bd.ia_pausada.return_value = True
        resultado, _ = self.ciclo(br(26, 10, 0))
        self.assertEqual(resultado, "pausado")
        self.assertEqual(self.status.sinal.call_args.args[0], "pausado")
        self.pipeline.executar.assert_not_called()
        self.status.reservar.assert_not_called()

    def test_fora_da_janela_nao_le_nada_e_avisa_a_proxima_leitura(self):
        for agora in (br(27, 10, 0), br(26, 18, 0), br(28, 6, 0)):
            self.status.sinal.reset_mock()
            resultado, _ = self.ciclo(agora)
            self.assertEqual(resultado, "fora_do_horario", agora)
            self.assertEqual(self.status.sinal.call_args.args[0], "fora_do_horario")
        self.assertEqual(self.status.sinal.call_args.kwargs["proxima_leitura"], br(28, 7, 30))
        self.pipeline.executar.assert_not_called()
        self.mail.contar_nao_lidos.assert_not_called()                  # nem abre a caixa fora do horário
        self.bd.listar_excecoes_para_reprocessar.assert_not_called()   # nem os pedidos do RH: fora do horário nada roda

    def test_dentro_da_janela_sem_nada_a_fazer_fica_ocioso(self):
        estado = robo.Estado(ultima_leitura=br(26, 9, 58), carregado=True)          # leu há 2 min: ainda não é hora
        resultado, _ = self.ciclo(br(26, 10, 0), estado)
        self.assertEqual(resultado, "ocioso")
        self.status.reservar.assert_not_called()                        # sem trabalho, nem reserva
        self.pipeline.executar.assert_not_called()

    def test_leitura_devida_le_a_caixa_e_publica_tudo(self):
        resultado, estado = self.ciclo(br(26, 10, 0))
        self.assertEqual(resultado, "leitura")
        self.pipeline.executar.assert_called_once_with(manutencao=True, limite=50)     # a primeira leitura do dia faz a manutenção
        self.status.marcar_checagem.assert_called_once_with(br(26, 10, 0))
        self.status.marcar_leitura.assert_called_once_with(br(26, 10, 0))
        self.assertEqual([c.args[0] for c in self.status.nao_lidos.call_args_list], [6, 2])   # aguardando antes e depois
        resumo, erro, proxima = self.status.concluir.call_args.args
        self.assertEqual((resumo["emails_lidos"], resumo["curriculos_processados"], erro), (4, 3, None))
        self.assertGreater(proxima, br(26, 10, 0))
        self.status.liberar.assert_called_once()
        self.assertEqual(estado.ultima_leitura, br(26, 10, 0))
        self.assertEqual(estado.ultima_manutencao, br(26, 10, 0).date())

    def test_manutencao_so_na_primeira_leitura_do_dia(self):
        estado = robo.Estado()
        self.mail.contar_nao_lidos.side_effect = [3, 0, 3, 0, 3, 0]     # antes e depois de cada leitura
        self.ciclo(br(26, 10, 0), estado)
        self.ciclo(br(26, 10, 10), estado)
        self.ciclo(br(28, 8, 0), estado)                                # outro dia: de novo
        self.assertEqual([c.kwargs["manutencao"] for c in self.pipeline.executar.call_args_list], [True, False, True])

    def test_sem_nada_na_caixa_nao_abre_execucao_nem_apaga_o_ultimo_resultado(self):
        estado = robo.Estado(ultima_manutencao=br(26, 7, 30).date())    # a manutenção de hoje já foi feita
        self.mail.contar_nao_lidos.side_effect = [0]
        resultado, estado = self.ciclo(br(26, 10, 0), estado)
        self.assertEqual(resultado, "leitura")
        self.pipeline.executar.assert_not_called()                      # nenhuma linha "0 e-mails" no histórico de execuções
        self.status.marcar_checagem.assert_called_once()                # mas o intervalo conta daqui
        self.status.marcar_leitura.assert_not_called()
        self.status.concluir.assert_not_called()                        # o resultado da última leitura real segue na tela
        self.assertEqual(self.status.nao_lidos.call_args.args[0], 0)
        self.assertEqual(self.status.sinal.call_args.args[0], "ocioso")
        self.assertEqual(estado.ultima_leitura, br(26, 10, 0))

    def test_primeira_checagem_do_dia_roda_mesmo_sem_e_mail_para_fazer_a_manutencao(self):
        self.mail.contar_nao_lidos.side_effect = [0, 0]
        self.ciclo(br(26, 10, 0))
        self.pipeline.executar.assert_called_once()
        self.assertTrue(self.pipeline.executar.call_args.kwargs["manutencao"])

    def test_caixa_que_nao_responde_nao_impede_a_leitura(self):
        self.mail.contar_nao_lidos.side_effect = RuntimeError("IMAP fora")
        estado = robo.Estado(ultima_manutencao=br(26, 7, 30).date())
        self.ciclo(br(26, 10, 0), estado)
        self.pipeline.executar.assert_called_once()                     # sem contagem, na dúvida lê

    def test_limite_de_e_mails_por_leitura(self):
        self.ciclo(br(26, 10, 0))
        self.assertEqual(self.pipeline.executar.call_args.kwargs["limite"], 50)     # padrão do modo contínuo: 50 por vez
        self.pipeline.executar.reset_mock()
        self.mail.contar_nao_lidos.side_effect = [4, 0]
        with patch.object(robo, "LIMITE_EMAILS", 20):
            self.ciclo(br(28, 8, 0))
        self.assertEqual(self.pipeline.executar.call_args.kwargs["limite"], 20)     # LIMITE_EMAILS (variável do Railway) manda

    def test_leitura_com_erro_publica_o_erro_e_repete_a_manutencao(self):
        self.pipeline.executar.return_value = {"emails_lidos": 0, "erro": "IMAP caiu", "interrompida": False}
        _, estado = self.ciclo(br(26, 10, 0))
        self.assertEqual(self.status.concluir.call_args.args[1], "IMAP caiu")
        self.assertIsNone(estado.ultima_manutencao)                     # a manutenção não conta como feita

    def test_contagem_de_nao_lidos_com_a_caixa_fora_do_ar_nao_derruba_o_ciclo(self):
        self.mail.contar_nao_lidos.side_effect = RuntimeError("IMAP fora")
        resultado, _ = self.ciclo(br(26, 10, 0))
        self.assertEqual(resultado, "leitura")
        self.status.nao_lidos.assert_not_called()                       # a tela fica com o número antigo e a hora dele
        self.pipeline.executar.assert_called_once()

    def test_outra_instancia_com_o_trabalho(self):
        self.status.reservar.return_value = False
        resultado, _ = self.ciclo(br(26, 10, 0))
        self.assertEqual(resultado, "ocupado")
        self.pipeline.executar.assert_not_called()
        self.status.liberar.assert_not_called()

    def test_liberar_a_reserva_mesmo_com_erro_no_meio(self):
        self.pipeline.executar.side_effect = RuntimeError("estourou")
        with self.assertRaises(RuntimeError):
            self.ciclo(br(26, 10, 0))
        self.status.liberar.assert_called_once()

    def test_reinicio_do_robo_nao_repete_a_leitura_na_hora(self):
        self.status.ultima_checagem.return_value = br(26, 9, 58).astimezone(timezone.utc)   # o banco lembra: olhou a caixa há 2 min
        resultado, _ = self.ciclo(br(26, 10, 0))
        self.assertEqual(resultado, "ocioso")
        self.pipeline.executar.assert_not_called()

    def test_sinal_repetido_nao_vai_ao_banco_a_cada_30_s(self):
        estado = robo.Estado(ultima_leitura=br(26, 9, 58), carregado=True)
        self.ciclo(br(26, 10, 0), estado)
        self.ciclo(br(26, 10, 0, 30), estado)                           # 30 s depois, mesmo estado
        self.assertEqual(self.status.sinal.call_count, 1)
        self.ciclo(br(26, 10, 1, 5), estado)                            # passou de 55 s
        self.assertEqual(self.status.sinal.call_count, 2)

    def test_janela_do_painel_muda_o_comportamento(self):
        self.bd.carregar_configuracoes.return_value = {"leitura_dias_semana": [1, 2, 3, 4, 5]}     # tirou o sábado
        resultado, _ = self.ciclo(br(26, 10, 0))
        self.assertEqual(resultado, "fora_do_horario")


class TestPedidosDoRH(CicloBase):
    """Exceção "tentar de novo", currículo enviado à mão e reanálise: tratados na hora, sem esperar o intervalo da caixa."""

    def _ocioso(self):
        return robo.Estado(ultima_leitura=br(26, 9, 58), carregado=True)          # a caixa só será lida às 10:08

    def test_tentar_de_novo_e_tratado_na_hora(self):
        self.bd.listar_excecoes_para_reprocessar.return_value = [{"id": "e1"}, {"id": "e2"}]
        resultado, _ = self.ciclo(br(26, 10, 0), self._ocioso())
        self.assertEqual(resultado, "pedidos")
        self.pipeline.reprocessar_excecoes.assert_called_once()
        self.pipeline.processar_uploads_manuais.assert_not_called()
        self.pipeline.reanalisar.assert_not_called()
        self.pipeline.executar.assert_not_called()                      # a caixa não foi lida: ainda não deu o intervalo
        self.assertEqual(self.status.processando.call_args.args[0], 2)
        self.assertEqual(self.status.sinal.call_args.args[0], "ocioso")   # e depois volta a ocioso
        self.status.liberar.assert_called_once()

    def test_envio_manual_de_curriculo(self):
        self.bd.listar_uploads_manuais_pendentes.return_value = [{"id": "u1"}]
        resultado, _ = self.ciclo(br(26, 10, 0), self._ocioso())
        self.assertEqual(resultado, "pedidos")
        self.pipeline.processar_uploads_manuais.assert_called_once()

    def test_reanalise_pedida_e_tratada_na_hora_e_libera_a_espera_quando_deu_certo(self):
        self.bd.listar_reanalises.side_effect = [[{"id": "c1"}], []]    # havia um pedido; depois da tentativa não sobrou nenhum
        resultado, estado = self.ciclo(br(26, 10, 0), self._ocioso())
        self.assertEqual(resultado, "pedidos")
        self.pipeline.reanalisar.assert_called_once()
        self.assertIsNone(estado.reanalise_liberada_em)

    def test_reanalise_que_falhou_espera_10_minutos_para_nao_gastar_ia_a_cada_30_s(self):
        self.bd.listar_reanalises.return_value = [{"id": "c1"}]           # continua pendente depois da tentativa
        _, estado = self.ciclo(br(26, 10, 0), self._ocioso())
        self.assertEqual(estado.reanalise_liberada_em, br(26, 10, 10))
        self.pipeline.reanalisar.reset_mock()
        self.bd.listar_reanalises.reset_mock()
        resultado, _ = self.ciclo(br(26, 10, 0, 30), estado)              # 30 s depois: não tenta
        self.assertEqual(resultado, "ocioso")
        self.pipeline.reanalisar.assert_not_called()
        self.bd.listar_reanalises.assert_not_called()
        estado.ultima_leitura = br(26, 10, 5)                             # (a caixa foi lida às 10:05: não está devida às 10:10)
        resultado, _ = self.ciclo(br(26, 10, 10), estado)                 # passados os 10 min: tenta de novo
        self.assertEqual(resultado, "pedidos")
        self.pipeline.reanalisar.assert_called_once()

    def test_pedidos_e_leitura_no_mesmo_ciclo(self):
        self.bd.listar_excecoes_para_reprocessar.return_value = [{"id": "e1"}]
        resultado, _ = self.ciclo(br(26, 10, 0))                          # a leitura também está devida
        self.assertEqual(resultado, "leitura")
        self.pipeline.reprocessar_excecoes.assert_called_once()
        self.pipeline.executar.assert_called_once()

    def test_fora_do_horario_os_pedidos_esperam(self):
        self.bd.listar_excecoes_para_reprocessar.return_value = [{"id": "e1"}]
        resultado, _ = self.ciclo(br(27, 10, 0))                          # domingo
        self.assertEqual(resultado, "fora_do_horario")
        self.pipeline.reprocessar_excecoes.assert_not_called()


class TestLacoContinuo(unittest.TestCase):
    def setUp(self):
        agenda.encerrar.clear()
        self.addCleanup(agenda.encerrar.clear)
        for alvo in (patch.object(robo.signal, "signal"), patch.object(robo, "status_robo")):
            self.addCleanup(alvo.stop)
            alvo.start()

    def test_erro_num_ciclo_nao_mata_o_robo_e_avisa_a_tela(self):
        chamadas = []

        def ciclo(estado):
            chamadas.append(1)
            if len(chamadas) == 1:
                raise RuntimeError("banco piscou")
            agenda.encerrar.set()                                         # o segundo ciclo pede para parar

        with patch.object(robo, "ciclo", side_effect=ciclo), patch.object(agenda.encerrar, "wait") as espera:
            self.assertEqual(robo.continuo(), 0)
        self.assertEqual(len(chamadas), 2)                                # o laço sobreviveu ao erro
        self.assertEqual(robo.status_robo.sinal.call_args.args[0], "erro")
        self.assertGreater(espera.call_args_list[0].args[0], 30)          # espera crescente depois de falhar

    def test_sigterm_encerra_com_educacao(self):
        with patch.object(robo, "ciclo", side_effect=lambda e: None), \
             patch.object(agenda.encerrar, "wait", side_effect=lambda s: agenda.encerrar.set()):
            self.assertEqual(robo.continuo(), 0)
        instalados = {c.args[0] for c in robo.signal.signal.call_args_list}
        import signal as sinais
        self.assertEqual(instalados, {sinais.SIGTERM, sinais.SIGINT})

    def test_uma_batida_faz_um_ciclo_com_folga_maior(self):
        with patch.object(robo, "ciclo", return_value="ocioso") as ciclo:
            self.assertEqual(robo.uma_batida(), "ocioso")
        self.assertEqual(ciclo.call_args.kwargs["tolerancia"], timedelta(minutes=2))


class TestContagemDeNaoLidos(unittest.TestCase):
    @contextmanager
    def _caixa(self, ids=b"5 6 7", status="OK", validade=b"1"):
        conn = MagicMock()
        conn.uid.return_value = (status, [ids])
        conn.response.return_value = (None, [validade])

        @contextmanager
        def conexao():
            yield conn
        with patch.object(leitor_email, "conexao_imap", conexao):
            yield conn

    def test_conta_os_nao_lidos_depois_do_marcador(self):
        with self._caixa(b"5 6 7 8") as conn:
            self.assertEqual(leitor_email.contar_nao_lidos(0), 4)
            self.assertEqual(leitor_email.contar_nao_lidos(6, 1), 2)      # só 7 e 8
        self.assertEqual(conn.uid.call_args.args[0], "SEARCH")
        conn.select.assert_called_with(leitor_email.IMAP_PASTA_ENTRADA, readonly=True)   # só leitura: nada é marcado como lido

    def test_o_maior_uid_que_o_imap_sempre_devolve_nao_conta_se_estiver_abaixo_do_marcador(self):
        with self._caixa(b"195000") as _:                                 # "UID n:*" devolve o último mesmo abaixo de n
            self.assertEqual(leitor_email.contar_nao_lidos(195303, 1), 0)

    def test_caixa_reindexada_ignora_o_marcador(self):
        with self._caixa(b"5 6 7", validade=b"99") as _:
            self.assertEqual(leitor_email.contar_nao_lidos(6, 1), 3)      # UIDVALIDITY mudou: conta tudo

    def test_falha_do_servidor_levanta(self):
        with self._caixa(status="NO"), self.assertRaises(RuntimeError):
            leitor_email.contar_nao_lidos(0)


class TestExecutarNoModoContinuo(unittest.TestCase):
    """O que mudou em pipeline.executar: manutenção opcional, andamento para a tela Status, pedido de encerramento e retorno com o erro."""

    def setUp(self):
        agenda.encerrar.clear()
        self.addCleanup(agenda.encerrar.clear)
        self.bd = MagicMock()
        self.bd.ia_pausada.return_value = False
        self.bd.listar_reanalises.return_value = []
        self.bd.listar_uploads_manuais_pendentes.return_value = []
        self.bd.obter_cursor_imap.return_value = (0, 0)
        self.bd.executar_manutencao.return_value = {}
        self.status = MagicMock()
        self.mensagens = [{"uid": str(i).encode()} for i in (1, 2, 3)]

    def _executar(self, tratar=None, **k):
        with patch.object(pipeline, "bd", self.bd), patch.object(pipeline, "status_robo", self.status), \
             patch.object(pipeline.mail, "buscar_novos", return_value=(self.mensagens, 7)), \
             patch.object(pipeline.mail, "marcar_como_lidas") as marcar, \
             patch.object(pipeline, "processar_mensagem", side_effect=tratar or (lambda *a, **kw: True)) as tratada, \
             patch.object(pipeline.sanitizacao, "verificar_e_gerar") as sanitizar:
            resultado = pipeline.executar(**k)
        return resultado, marcar, tratada, sanitizar

    def test_sem_manutencao_nao_mexe_no_banco_alem_da_leitura(self):
        _, _, _, sanitizar = self._executar(manutencao=False)
        self.bd.executar_manutencao.assert_not_called()
        sanitizar.assert_not_called()

    def test_com_manutencao_faz_como_sempre(self):
        _, _, _, sanitizar = self._executar()
        self.bd.executar_manutencao.assert_called_once()
        sanitizar.assert_called_once()

    def test_limite_da_leitura(self):
        with patch.object(pipeline, "bd", self.bd), patch.object(pipeline, "status_robo", self.status), \
             patch.object(pipeline.mail, "buscar_novos", return_value=([], 7)) as busca, \
             patch.object(pipeline, "LIMITE_EMAILS", 10), patch.object(pipeline.sanitizacao, "verificar_e_gerar"):
            pipeline.executar(manutencao=False)
            self.assertEqual(busca.call_args.args[0], 10)                     # sem limite explícito vale LIMITE_EMAILS
            pipeline.executar(manutencao=False, limite=50)
            self.assertEqual(busca.call_args.args[0], 50)
            pipeline.executar(manutencao=False, limite=0)
            self.assertEqual(busca.call_args.args[0], 0)                      # 0 = todos

    def test_publica_o_andamento_para_a_tela_status(self):
        self._executar(manutencao=False)
        self.status.processando.assert_called_once_with(3, "Lendo os e-mails da caixa")
        self.assertEqual([c.args[0] for c in self.status.avancar.call_args_list], [1, 2, 3])

    def test_sem_mensagens_nao_publica_andamento(self):
        self.mensagens = []
        self._executar(manutencao=False)
        self.status.processando.assert_not_called()

    def test_pedido_de_encerramento_para_entre_dois_emails_e_deixa_o_resto_nao_lido(self):
        def tratar(msg, *a, **k):
            if msg["uid"] == b"1":
                agenda.encerrar.set()                                     # o deploy pediu para parar durante o primeiro e-mail
            return True
        resultado, marcar, tratada, _ = self._executar(tratar, manutencao=False)
        self.assertEqual(tratada.call_count, 1)                           # o segundo e o terceiro nem começaram
        marcar.assert_called_once_with([b"1"])                            # só o que foi tratado vira lido
        self.assertTrue(resultado["interrompida"])

    def test_retorno_traz_os_numeros_e_o_erro(self):
        resultado, _, _, _ = self._executar(manutencao=False)
        self.assertEqual(resultado["emails_lidos"], 3)
        self.assertIsNone(resultado["erro"])
        self.assertFalse(resultado["interrompida"])
        self.bd.obter_cursor_imap.side_effect = RuntimeError("banco fora")
        resultado, _, _, _ = self._executar(manutencao=False)
        self.assertEqual(resultado["erro"], "banco fora")                 # o robô publica o erro na tela em vez de morrer


if __name__ == "__main__":
    unittest.main()
