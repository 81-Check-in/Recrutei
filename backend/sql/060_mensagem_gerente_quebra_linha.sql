-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Mensagem ao gerente: quebra de linha antes do link (060)
--
--  Rodar depois da 059. Pode rodar de novo sem problema.
--
--  A 055 gravou o "\n" como dois caracteres (barra + n), e a mensagem saía "achou:\nhttps://...".
--  Troca por quebra de linha de verdade só onde ainda existe o "\n" literal (mensagem já editada pelo RH sem ele não muda).
-- ════════════════════════════════════════════════════════════════════════

update public.configuracoes
   set valor = to_jsonb(replace(valor #>> '{}', E'\\n', E'\n'))
 where chave = 'mensagem_gerente_padrao'
   and jsonb_typeof(valor) = 'string'
   and position(E'\\n' in (valor #>> '{}')) > 0;
