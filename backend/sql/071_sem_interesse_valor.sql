-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — "Sem interesse" como resultado da entrevista (071)
--
--  Rodar ANTES da 072, e SOZINHA (um valor novo de enum só pode ser usado depois de gravado).
--  Pode rodar de novo sem problema.
-- ════════════════════════════════════════════════════════════════════════
alter type public.resultado_entrevista add value if not exists 'sem_interesse';
