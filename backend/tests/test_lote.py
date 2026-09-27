"""
Testes da carga em lote (ia.py em modo lote e lote.py). Sem rede: Supabase e Claude são simulados.

    cd backend && .venv/bin/python -m unittest discover -s tests -v
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

for chave, valor in {
    "SUPABASE_URL": "http://supabase.test", "SUPABASE_SERVICE_KEY": "chave", "ANTHROPIC_API_KEY": "chave",
    "IMAP_USUARIO": "vagas@empresa.test", "IMAP_SENHA": "senha", "IDENTIDADE_CHAVE": "x" * 40,
}.items():
    os.environ[chave] = valor
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import ia    # noqa: E402
import lote  # noqa: E402

TEXTO = "JOÃO DA SILVA\nExperiência: caixa de supermercado por 3 anos.\nFormação: ensino médio completo.\n" * 5


class ModoLoteTest(unittest.TestCase):
    def setUp(self):
        ia._modo_lote = None
        ia.pedidos_coletados.clear()
        ia.respostas_lote.clear()
        ia.resetar_custo()
        self.addCleanup(setattr, ia, "_modo_lote", None)
        p = patch.object(ia.bd, "ia_pausada", return_value=False)
        p.start()
        self.addCleanup(p.stop)

    def test_modo_normal_vai_para_a_api(self):
        with patch.object(ia, "_chamar_api", return_value=({"a": 1}, {"modelo": "m"})) as api:
            self.assertEqual(ia._chamar("m", "sis", "msg", 50), ({"a": 1}, {"modelo": "m"}))
        api.assert_called_once_with("m", "sis", "msg", 50)

    def test_coletar_anota_o_pedido_e_interrompe_sem_chamar_a_api(self):
        ia._modo_lote = "coletar"
        with patch.object(ia, "_chamar_api") as api:
            with self.assertRaises(ia.PedidoColetado) as cm:
                ia._chamar("claude-sonnet-5", "sis", "msg", 1500)
        api.assert_not_called()
        chave = cm.exception.args[0]
        self.assertEqual(chave, ia.chave_do_pedido("claude-sonnet-5", "sis", "msg", 1500))
        corpo = ia.pedidos_coletados[chave]
        self.assertEqual(corpo["model"], "claude-sonnet-5")
        self.assertEqual(corpo["system"], "sis")
        self.assertEqual(corpo["messages"], [{"role": "user", "content": "msg"}])
        self.assertEqual(corpo["thinking"], {"type": "disabled"})     # os parâmetros do modelo vão junto, como na chamada direta
        self.assertEqual(len(chave), 64)                               # cabe no custom_id da Batch API

    def test_a_coleta_nao_e_engolida_por_except_exception(self):
        ia._modo_lote = "coletar"
        try:
            try:
                ia._chamar("m", "sis", "msg", 10)
            except Exception:
                self.fail("PedidoColetado não pode ser Exception")
        except ia.PedidoColetado:
            pass

    def test_repetir_devolve_a_resposta_do_lote_com_custo_pela_metade(self):
        chave = ia.chave_do_pedido("claude-haiku-4-5-20251001", "sis", "msg", 200)
        ia.respostas_lote[chave] = {"texto": '{"nome": "Ana"}', "tokens_entrada": 1_000_000, "tokens_saida": 0}
        ia._modo_lote = "repetir"
        resultado, uso = ia._chamar("claude-haiku-4-5-20251001", "sis", "msg", 200)
        self.assertEqual(resultado, {"nome": "Ana"})
        self.assertEqual((uso["tokens_entrada"], uso["tokens_saida"], uso["modelo"]), (1_000_000, 0, "claude-haiku-4-5-20251001"))
        self.assertAlmostEqual(ia.custo_total["usd"], 0.5)             # US$ 1,00 por milhão de entrada, com 50% de desconto

    def test_repetir_sem_resposta_nao_e_defeito_do_email(self):
        ia._modo_lote = "repetir"
        with self.assertRaises(ia.IAPausada) as cm:                    # o pipeline já trata IAPausada: não registra exceção, não marca lido
            ia._chamar("m", "sis", "msg", 10)
        self.assertIsInstance(cm.exception, ia.RespostaDeLoteAusente)

    def test_pausa_de_emergencia_vale_tambem_no_lote(self):
        ia._modo_lote = "coletar"
        with patch.object(ia.bd, "ia_pausada", return_value=True):
            with self.assertRaises(ia.IAPausada):
                ia._chamar("m", "sis", "msg", 10)
        self.assertEqual(ia.pedidos_coletados, {})

    def test_o_pedido_coletado_pela_identificacao_e_o_que_o_pipeline_repete(self):
        """Coletar e repetir usam as mesmas funções de ia.py: a chave tem de bater, senão a resposta do lote nunca é achada."""
        chave = lote._coletar(ia.identificar_curriculo, TEXTO, "claude-haiku-4-5-20251001", ["Ceilândia"])
        ia.respostas_lote[chave] = {"texto": '{"e_curriculo": true, "nome_candidato": "João da Silva"}',
                                    "tokens_entrada": 900, "tokens_saida": 40}
        ia._modo_lote = "repetir"
        ident, _ = ia.identificar_curriculo(TEXTO, "claude-haiku-4-5-20251001", ["Ceilândia"])
        self.assertTrue(ident["e_curriculo"])
        self.assertEqual(ident["nome_candidato"], "João da Silva")
        ia._modo_lote = "repetir"
        with self.assertRaises(ia.RespostaDeLoteAusente):              # regiões diferentes = outro prompt = outra chave
            ia.identificar_curriculo(TEXTO, "claude-haiku-4-5-20251001", ["Gama"])


class SelecaoDaEtapa1Test(unittest.TestCase):
    def rec(self, uid, hash_, texto="texto de currículo", msgid=None, **extra):
        return {"uid": uid, "message_id": msgid or f"m{uid}", "hash": hash_, "texto": texto, "erro": None, **extra}

    def test_so_identifica_o_que_o_pipeline_nao_resolve_de_graca(self):
        selecao = [{"uid": u} for u in range(1, 9)]
        prep = {
            1: self.rec(1, "A"),                                   # novo
            2: self.rec(2, "A"),                                   # mesmo arquivo do 1: repetido na seleção
            3: self.rec(3, "B", msgid="ja"),                       # Message-ID já no banco
            4: self.rec(4, "C"),                                   # arquivo já no banco
            5: self.rec(5, "D", erro=["sem_anexo", "x"]),          # sem texto: o pipeline registra a exceção sem IA
            6: self.rec(6, "E", texto=None),                       # extração vazia
            7: self.rec(7, "F"),                                   # novo
            8: {"uid": 8, "pular": True},                          # sem remetente
        }
        banco = {"msgids": {"ja"}, "hashes": {"C"}, "pessoas": set()}
        novos = lote.candidatos_da_etapa_1(prep, selecao, banco)
        self.assertEqual([r["uid"] for r in novos], [1, 7])

    def test_o_mais_antigo_e_o_original(self):
        selecao = [{"uid": 10}, {"uid": 20}]
        prep = {10: self.rec(10, "A"), 20: self.rec(20, "A")}
        novos = lote.candidatos_da_etapa_1(prep, selecao, {"msgids": set(), "hashes": set(), "pessoas": set()})
        self.assertEqual([r["uid"] for r in novos], [10])

    def test_indicio_de_anexo_na_estrutura_mime(self):
        self.assertTrue(lote._tem_indicio_de_anexo('BODYSTRUCTURE (("application" "pdf" ("name" "cv.pdf") NIL NIL "base64" 100) "mixed")'))
        self.assertFalse(lote._tem_indicio_de_anexo('BODYSTRUCTURE (("text" "plain" ("charset" "utf-8") NIL NIL "7bit" 20 1) "alternative")'))


class CompletarTest(unittest.TestCase):
    """_completar decide o que vai à Batch API e, portanto, o que se paga: cada pedido é enviado uma vez, e só se ainda não tem resposta."""

    def setUp(self):
        self.pasta = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.pasta, ignore_errors=True))
        self.enviados = []           # um item por lote enviado: as chaves dele
        self.ok = True               # False: o lote volta com erro em tudo
        self.sem_saldo = False
        self.estado = {"lotes": {}, "custo_usd": 0.0}
        self.pedidos = {f"k{i}": {"model": "m"} for i in range(5)}

        def enviar(pedidos):
            self.enviados.append(list(pedidos))
            return f"lote{len(self.enviados)}"

        def baixar(lote_id, caminho):
            chaves = self.enviados[int(lote_id[4:]) - 1]
            with open(caminho, "a", encoding="utf-8") as f:
                for k in chaves:
                    if self.ok:
                        f.write(json.dumps({"chave": k, "texto": "{}", "tokens_entrada": 1, "tokens_saida": 1, "modelo": "m"}) + "\n")
            return {"custo_usd": 1.0, "ok": len(chaves) if self.ok else 0, "erros": {}, "exemplos": [], "sem_saldo": self.sem_saldo}

        for alvo, falso in (("_enviar", enviar), ("_baixar", baixar), ("_aguardar", lambda *a: None)):
            p = patch.object(lote, alvo, falso)
            p.start()
            self.addCleanup(p.stop)

    def completar(self, tamanho=100, teto=100.0, fase="analise"):
        return lote._completar(self.estado, self.pasta, fase, self.pedidos, tamanho, teto)

    def test_envia_tudo_uma_vez_e_soma_o_custo_real(self):
        self.assertIsNone(self.completar(tamanho=2))
        self.assertEqual([len(l) for l in self.enviados], [2, 2, 1])
        self.assertEqual(self.estado["custo_usd"], 3.0)

    def test_rodar_de_novo_nao_envia_o_que_ja_tem_resposta(self):
        self.completar()
        self.completar()
        self.assertEqual(len(self.enviados), 1)

    def test_pedido_novo_vai_sozinho_num_lote_novo(self):
        self.completar()
        self.pedidos["k9"] = {"model": "m"}
        self.completar()
        self.assertEqual(self.enviados[1], ["k9"])

    def test_lote_em_voo_e_esperado_e_nao_reenviado(self):
        self.estado["lotes"]["analise_1"] = {"id": "lote1", "pedidos": 5}       # enviado antes de a carga ser interrompida
        self.enviados.append(list(self.pedidos))
        self.completar()
        self.assertEqual(len(self.enviados), 1)
        self.assertIn("resumo", self.estado["lotes"]["analise_1"])

    def test_pedido_que_o_servidor_recusa_e_tentado_so_duas_vezes(self):
        self.ok = False
        for _ in range(4):
            self.completar()
        self.assertEqual(len(self.enviados), lote.MAX_TENTATIVAS_POR_PEDIDO)

    def test_teto_de_gasto_impede_o_lote_seguinte(self):
        motivo = self.completar(tamanho=2, teto=1.0 + lote.CUSTO_ESTIMADO_POR_PEDIDO["analise"] * 2 - 0.0001)
        self.assertIn("teto", motivo)
        self.assertEqual(len(self.enviados), 1)

    def test_falta_de_saldo_para_a_fase(self):
        self.sem_saldo = True
        self.assertIn("saldo", self.completar(tamanho=2))
        self.assertEqual(len(self.enviados), 1)


if __name__ == "__main__":
    unittest.main()
