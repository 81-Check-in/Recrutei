-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · PASSO 1 de 6: valores novos nos tipos existentes
--
--  Ordem de execução (cada arquivo em uma execução separada, nesta ordem):
--    020_banco_talentos_tipos.sql        ← este
--    021_banco_talentos_modelo.sql       tabelas novas, colunas novas, índices, RLS
--    022_banco_talentos_regras.sql       gatilhos e funções (atribuir, devolver ao banco, editar…)
--    023_banco_talentos_sanitizacao.sql  sugestões de sanitização + parâmetros
--    024_banco_talentos_views.sql        views e a função de busca
--    025_banco_talentos_migracao_dados.sql  migra o que existe hoje (atômico, com verificações)
--  Leia backend/README.md ("Banco de Talentos — como aplicar") antes de rodar.
--
--  Por que um arquivo só para isto: o Postgres não deixa USAR, na mesma transação, um valor
--  de enum recém-adicionado. Rodando este arquivo sozinho, os valores já valem nos próximos.
--  Pode rodar de novo sem problema (if not exists).
-- ════════════════════════════════════════════════════════════════════════

-- Status da candidatura (vínculo candidato ↔ vaga)
--   aguardando = o RH atribuiu o candidato à vaga; ainda sem entrevista (antes: "selecionado")
--   cancelado  = a candidatura foi encerrada sem reprovação (vaga fechada, desistência, vínculo desfeito)
alter type public.status_candidatura add value if not exists 'aguardando';
alter type public.status_candidatura add value if not exists 'cancelado';

-- Ações que passam a ser registradas na trilha de auditoria (logs_auditoria)
alter type public.acao_auditoria add value if not exists 'atribuicao_candidato';
alter type public.acao_auditoria add value if not exists 'retorno_banco_talentos';
alter type public.acao_auditoria add value if not exists 'alteracao_candidato';
alter type public.acao_auditoria add value if not exists 'sanitizacao_geracao';
alter type public.acao_auditoria add value if not exists 'sanitizacao_decisao';
