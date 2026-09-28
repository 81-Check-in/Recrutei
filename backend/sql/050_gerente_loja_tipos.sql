-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Encaminhar ao gerente da loja: valor novo no tipo (050)
--
--  Rodar sozinho, antes da 051 (o Postgres não deixa USAR, na mesma transação, um valor de enum recém-
--  adicionado — mesmo motivo da 020). Pode rodar de novo sem problema.
--
--  aguardando_gerente = o RH encaminhou o candidato ao gerente da loja (fora do sistema: WhatsApp, e-mail…)
--  e espera a decisão dele. É a "última fase" das vagas do setor Loja: dali só sai aprovado ou reprovado
--  (051_gerente_loja.sql).
-- ════════════════════════════════════════════════════════════════════════

alter type public.status_candidatura add value if not exists 'aguardando_gerente';
