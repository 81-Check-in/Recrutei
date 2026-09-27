#!/usr/bin/env python3
"""
RECRUTEI — ponto de entrada.

Uso:
  python main.py                 executa o pipeline completo, agora
  python main.py --continuo      o robô em tempo (quase) real, sempre ligado: pedidos do RH (tentar de novo, currículo enviado, reanálise)
                                 em até ~30 s e leitura dos e-mails a cada 10 min, de seg a sáb, das 07:30 às 18:00 (tudo em Configurações).
                                 É o comando do serviço do Railway (deixe o Cron Schedule vazio)
  python main.py --agendada      um único ciclo do mesmo robô, para quem prefere o Cron Schedule do Railway (mínimo de 5 em 5 minutos)
  python main.py --testar        testa conexões (IMAP, Supabase, Claude)
  python main.py --simular       roda sem gravar nada
  python main.py --limite 5      processa no máximo 5 e-mails
  python main.py --desde 2026-09-18   só e-mails recebidos a partir da data (o mesmo que IMAP_DESDE, só nesta execução)
  python main.py --reler-caixa --desde 2026-09-18   relê a caixa (lidos e não lidos) e recarrega o Banco de Talentos;
                                 não marca nada como lido e pode ser repetido (e-mail já importado é ignorado)
  python main.py --manutencao    só a manutenção (partições da auditoria, expurgo dos inativos vencidos e arquivos de dados excluídos)
  python main.py --reanalisar    só as (re)análises da IA pedidas: candidatos migrados, currículo reenviado, botão do painel
  python main.py --reavaliar     só as avaliações para vaga pedidas ao atribuir candidatos no painel
  python main.py --reprocessar-excecoes   só as exceções marcadas para tentar de novo no painel
  python main.py --uploads-manuais        só os currículos enviados manualmente no painel
  python main.py --sexo-pelo-nome         estima (pelo primeiro nome) o sexo de quem está no banco sem sexo; só para estatística.
                                 Com --limite N faz só N; com --simular só conta. Pode ser repetido
  python main.py --sanitizacao   gera a lista de sugestões de sanitização se o intervalo venceu (e avisa o RH)
  python main.py --sanitizacao --forcar   gera agora, mesmo antes do prazo
"""
import sys
import argparse


def testar_conexoes() -> bool:
    print("\n" + "=" * 56)
    print("  TESTE DE CONEXÕES")
    print("=" * 56 + "\n")

    ok = True

    # Supabase
    print("Supabase…", end=" ", flush=True)
    try:
        import database as bd
        cfg = bd.carregar_configuracoes()
        vagas = bd.listar_vagas_abertas()
        print(f"OK — {len(cfg)} configurações, {len(vagas)} vaga(s) aberta(s)")
        for v in vagas:
            print(f"    • {v['titulo']}: "
                  f"{len(v['obrigatorios'])} obrigatório(s), "
                  f"{len(v['desejaveis'])} desejável(is), "
                  f"{len(v['diferenciais'])} diferencial(is)")
    except Exception as e:
        print(f"FALHOU\n    {e}")
        ok = False

    # IMAP
    print("\nE-mail (IMAP)…", end=" ", flush=True)
    try:
        import leitor_email as mail
        if mail.testar_conexao():
            print("OK")
        else:
            ok = False
    except Exception as e:
        print(f"FALHOU\n    {e}")
        ok = False

    # Claude
    print("\nClaude API…", end=" ", flush=True)
    try:
        import ia
        import database as bd
        if bd.ia_pausada():
            print("PAUSADA no painel (Configurações → Zona de perigo) — não testada")
        else:
            r = ia.cliente.messages.create(
                model="claude-haiku-4-5-20251001",
                max_tokens=20,
                messages=[{"role": "user", "content": "Responda apenas: ok"}],
            )
            print(f"OK — {r.usage.input_tokens + r.usage.output_tokens} tokens")
    except Exception as e:
        print(f"FALHOU\n    {e}")
        ok = False

    print("\n" + "=" * 56)
    print("  TUDO PRONTO" if ok else "  CORRIJA OS ERROS ACIMA")
    print("=" * 56 + "\n")
    return ok


def main() -> int:
    p = argparse.ArgumentParser(description="Recrutei — Banco de Talentos")
    p.add_argument("--testar", action="store_true", help="testa conexões e sai")
    p.add_argument("--continuo", action="store_true",
                   help="robô sempre ligado: pedidos do RH em até ~30 s e leitura dos e-mails no intervalo e na janela de Configurações "
                        "(padrão: a cada 10 min, seg a sáb, 07:30 às 18:00). Para o serviço do Railway sem Cron Schedule")
    p.add_argument("--agendada", action="store_true",
                   help="um único ciclo do robô (o mesmo do --continuo) e sai. Para o Cron Schedule do Railway (mínimo de 5 em 5 minutos)")
    p.add_argument("--simular", action="store_true", help="não grava nada")
    p.add_argument("--limite", type=int, help="máximo de e-mails a processar")
    p.add_argument("--desde", metavar="AAAA-MM-DD",
                   help="só e-mails recebidos a partir desta data (o mesmo que IMAP_DESDE, só nesta execução)")
    p.add_argument("--reler-caixa", action="store_true",
                   help="relê a caixa (lidos e não lidos) desde --desde e põe no Banco de Talentos o que ainda não está lá; "
                        "não marca nada como lido e pode ser repetido. Para recarregar o banco depois de zerá-lo")
    p.add_argument("--ate-uid", type=int, metavar="N",
                   help="com --reler-caixa: não passa deste UID (o marcador de progresso da execução diária "
                        "é o limite natural: relê só o que o pipeline já tinha lido)")
    p.add_argument("--manutencao", action="store_true",
                   help="só a manutenção (partições da auditoria, expurgo dos inativos vencidos e arquivos de dados excluídos)")
    p.add_argument("--reanalisar", action="store_true",
                   help="só as (re)análises da IA pedidas (candidatos migrados, currículo reenviado, botão do painel)")
    p.add_argument("--reavaliar", action="store_true",
                   help="só as avaliações para vaga pedidas ao atribuir candidatos no painel")
    p.add_argument("--reprocessar-excecoes", action="store_true",
                   help="só as exceções marcadas para tentar de novo no painel")
    p.add_argument("--uploads-manuais", action="store_true",
                   help="só os currículos enviados manualmente no painel (botão \"Enviar currículo\")")
    p.add_argument("--sexo-pelo-nome", action="store_true",
                   help="estima, pelo primeiro nome, o sexo de quem está no banco sem sexo (só estatística de cadastro; "
                        "o RH corrige à mão e a correção nunca é refeita). Com --limite N faz só N")
    p.add_argument("--sanitizacao", action="store_true",
                   help="gera a lista de sugestões de sanitização se o intervalo venceu, e avisa o RH")
    p.add_argument("--forcar", action="store_true",
                   help="com --sanitizacao: gera a lista agora, mesmo antes do prazo")
    args = p.parse_args()

    if args.continuo and args.agendada:
        p.error("--continuo e --agendada são modos diferentes: escolha um")
    if (args.continuo or args.agendada) and (args.testar or args.manutencao or args.sanitizacao or args.reler_caixa or args.reanalisar
                          or args.reavaliar or args.reprocessar_excecoes or args.uploads_manuais or args.sexo_pelo_nome):
        p.error("--continuo e --agendada são só para o robô completo: não combinam com os outros modos")

    if args.simular:
        import os
        os.environ["MODO_SIMULACAO"] = "true"
    if args.limite:
        import os
        os.environ["LIMITE_EMAILS"] = str(args.limite)
    if args.desde:
        import os
        os.environ["IMAP_DESDE"] = args.desde

    if args.testar:
        return 0 if testar_conexoes() else 1

    if args.manutencao:
        import database as bd
        import sanitizacao
        from config import log
        r = bd.executar_manutencao()
        sanitizacao.registrar_expurgo(r.get("expurgo"))
        log.info(f"Arquivos removidos do Storage: {r.get('arquivos_removidos', 0)} | "
                 f"Sugestões de sanitização pendentes: {r.get('sanitizacao_pendentes', 0)}")
        return 0

    if args.sanitizacao:
        import sanitizacao
        sanitizacao.verificar_e_gerar(forcar=args.forcar, origem="manual" if args.forcar else "job")
        return 0

    if args.forcar:
        p.error("--forcar só faz sentido junto com --sanitizacao")

    if args.continuo:
        import robo
        return robo.continuo()

    if args.agendada:
        import robo
        robo.uma_batida()
        return 0

    import pipeline
    if args.reler_caixa:
        try:
            pipeline.reler_caixa(limite=args.limite or 0, ate_uid=args.ate_uid or 0)
        except RuntimeError as e:
            p.error(str(e))
        return 0
    if args.ate_uid:
        p.error("--ate-uid só faz sentido junto com --reler-caixa")

    if args.reanalisar:
        pipeline.reanalisar()
        return 0

    if args.reavaliar:
        pipeline.reavaliar()
        return 0

    if args.reprocessar_excecoes:
        pipeline.reprocessar_excecoes()
        return 0

    if args.uploads_manuais:
        pipeline.processar_uploads_manuais()
        return 0

    if args.sexo_pelo_nome:
        pipeline.preencher_sexo_pelo_nome(limite=args.limite or 0)
        return 0

    pipeline.executar()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrompido pelo usuário")
        sys.exit(130)
    except RuntimeError as e:
        print(f"\nErro de configuração: {e}")
        sys.exit(1)
