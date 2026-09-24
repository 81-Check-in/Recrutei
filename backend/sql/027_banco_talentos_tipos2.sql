-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · 2ª leva: valores novos nos tipos existentes
--
--  Ordem (cada arquivo em uma execução separada):
--    027_banco_talentos_tipos2.sql          ← este (precisa rodar sozinho)
--    028_banco_talentos_etapa1.sql          reincidência, lista negra, descarte por vaga
--    029_banco_talentos_etapa2.sql          requisito Diferencial, palavras-chave, ranking de candidatos por vaga
--    030_banco_talentos_etapa3.sql          lojas × regiões (distância) e considerações da entrevista
--
--  Por que um arquivo só para isto: o Postgres não deixa USAR, na mesma transação, um valor de enum
--  recém-adicionado (mesmo motivo da 020). Pode rodar de novo sem problema (if not exists).
-- ════════════════════════════════════════════════════════════════════════

-- Requisitos da vaga: além de Obrigatório (elimina) e Desejável (pontua), o Diferencial soma pontos
-- extras e nunca penaliza quem não tem.
alter type public.tipo_requisito add value if not exists 'diferencial';

-- Trilha de auditoria (logs_auditoria)
alter type public.acao_auditoria add value if not exists 'lista_negra_bloqueio';
alter type public.acao_auditoria add value if not exists 'lista_negra_desbloqueio';
alter type public.acao_auditoria add value if not exists 'consideracao_registrada';
