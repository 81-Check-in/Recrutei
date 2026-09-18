#!/usr/bin/env python3
"""
RECRUTEI — ponto de entrada.

Uso:
  python main.py                 executa o pipeline completo
  python main.py --testar        testa conexões (IMAP, Supabase, Claude)
  python main.py --simular       roda sem gravar nada
  python main.py --limite 5      processa no máximo 5 e-mails
  python main.py --manutencao    só inativação e expurgo
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
                  f"{len(v['desejaveis'])} desejável(is)")
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
    p = argparse.ArgumentParser(description="Recrutei — triagem de currículos")
    p.add_argument("--testar", action="store_true", help="testa conexões e sai")
    p.add_argument("--simular", action="store_true", help="não grava nada")
    p.add_argument("--limite", type=int, help="máximo de e-mails a processar")
    p.add_argument("--manutencao", action="store_true",
                   help="só inativação e expurgo")
    args = p.parse_args()

    if args.simular:
        import os
        os.environ["MODO_SIMULACAO"] = "true"
    if args.limite:
        import os
        os.environ["LIMITE_EMAILS"] = str(args.limite)

    if args.testar:
        return 0 if testar_conexoes() else 1

    if args.manutencao:
        import database as bd
        from config import log
        r = bd.executar_manutencao()
        log.info(f"Inativadas: {r.get('inativadas', 0)} | "
                 f"Expurgadas: {r.get('expurgadas', 0)}")
        return 0

    import pipeline
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
