-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Ver o e-mail direto na Fila de exceções
--
--  Rode UMA vez: Supabase → SQL Editor → New query → cole este arquivo → Run.
--  Só adiciona duas colunas em "excecoes" (nenhuma tabela existente perde dado).
--
--  O que isso habilita: o botão "Ver e-mail" na Fila de exceções mostra o corpo
--  do e-mail original e, quando existiu, o texto que foi extraído do anexo antes
--  da IA decidir que não era currículo — sem precisar abrir o webmail.
--
--  Só vale para exceções criadas (ou reprocessadas) DEPOIS desta atualização.
--  As exceções antigas mostram "sem conteúdo salvo"; clique "Reprocessar" nelas
--  para preencher também (backend/sql/017_reprocessar_excecoes.sql).
-- ════════════════════════════════════════════════════════════════════════

alter table public.excecoes
  add column if not exists email_corpo text,
  add column if not exists texto_extraido text;

comment on column public.excecoes.email_corpo is
  'Corpo do e-mail original, sem formatação. Guardado a partir desta atualização.';
comment on column public.excecoes.texto_extraido is
  'Texto extraído do anexo/link antes da IA classificar (só quando a extração deu certo,
   mas a IA decidiu "não é currículo" ou "vaga indefinida"). Null quando a própria
   extração falhou — aí não há texto para mostrar.';
