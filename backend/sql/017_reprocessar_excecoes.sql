-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Reprocessar exceções
--
--  Rode UMA vez: Supabase → SQL Editor → New query → cole este arquivo → Run.
--  Só adiciona duas colunas em "excecoes" (nenhuma tabela existente perde dado).
--
--  O que isso habilita: o botão "Reprocessar" na Fila de exceções. O painel só
--  marca a exceção (grava quem pediu e quando); quem busca o e-mail original de
--  novo e tenta classificar/avaliar é o pipeline Python, na próxima execução
--  com  python main.py --reprocessar-excecoes
--
--  Sem isto: o botão "Reprocessar" ainda não aparece habilitado — a tela avisa
--  que precisa desta atualização, do mesmo jeito que os filtros avançados avisam
--  em backend/sql/filtros_avancados.sql.
-- ════════════════════════════════════════════════════════════════════════

alter table public.excecoes
  add column if not exists reprocessar_solicitado_em timestamptz,
  add column if not exists reprocessar_solicitado_por uuid references public.usuarios(id);

comment on column public.excecoes.reprocessar_solicitado_em is
  'Quando o RH pediu para tentar de novo (busca o e-mail original pelo Message-ID). Null = sem pedido pendente.';
comment on column public.excecoes.reprocessar_solicitado_por is
  'Quem pediu o reprocessamento.';
