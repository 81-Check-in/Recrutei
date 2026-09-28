-- Teste de "Já passou pelo RH" no Banco de Talentos (052): total_historico, o popup (historico_do_candidato) e o
-- filtro "Com passagem pelo RH" (fn_bate_colunas_avancadas). Roda depois de 020–052.
-- Tudo dentro de uma transação que termina em ROLLBACK: não deixa nada no banco.
\set ON_ERROR_STOP on
begin;

do $$
declare
  por_id     uuid;   -- casa por candidato_id (linha "nova", origem sistema)
  por_nome   uuid;   -- casa só pelo nome (planilha antiga, sem candidato_id, telefone diferente)
  por_tel    uuid;   -- casa só pelo telefone (planilha antiga, sem candidato_id, "55" na frente de um lado só, nome diferente)
  sem_match  uuid;   -- não tem nada no histórico
  n int; ok boolean; qtd int;
begin
  insert into candidatos (nome, telefone, telefone_e164, cidade, uf, hash_identidade)
    values ('Fulano Teste Historico', '61999990001', '5561999990001', 'Brasília', 'DF', 'hash-hist-id') returning id into por_id;
  insert into candidatos (nome, telefone, telefone_e164, cidade, uf, hash_identidade)
    values ('Ciclana Teste Historico', '61999990002', '5561999990002', 'Brasília', 'DF', 'hash-hist-nome') returning id into por_nome;
  insert into candidatos (nome, telefone, telefone_e164, cidade, uf, hash_identidade)
    values ('Beltrano Teste Historico', '61999990003', '5561999990003', 'Brasília', 'DF', 'hash-hist-tel') returning id into por_tel;
  insert into candidatos (nome, telefone, telefone_e164, cidade, uf, hash_identidade)
    values ('Sicrano Teste Historico', '61999990004', '5561999990004', 'Brasília', 'DF', 'hash-hist-nenhum') returning id into sem_match;

  -- casa por candidato_id (não precisa nome/telefone bater)
  insert into historico_candidatos (candidato_id, nome, data_evento, status, origem)
    values (por_id, 'Fulano Teste Historico', current_date - 30, 'nao_compareceu', 'sistema');
  insert into historico_candidatos (candidato_id, nome, data_evento, status, origem)
    values (por_id, 'Fulano Teste Historico', current_date - 10, 'reprovado', 'sistema');

  -- planilha antiga: sem candidato_id, nome igual (normalizado) mas telefone diferente
  insert into historico_candidatos (nome, telefone, data_evento, status, origem)
    values ('CICLANA teste HISTORICO', '61 3333-4444', current_date - 400, 'sem_interesse', 'planilha');

  -- planilha antiga: sem candidato_id, telefone igual (com "55" na frente, ao contrário do cadastro) mas nome diferente
  insert into historico_candidatos (nome, telefone, data_evento, status, origem)
    values ('Nome Bem Diferente', '5561999990003', current_date - 500, 'aprovado', 'planilha');

  -- ── total_historico na view ──
  select total_historico into n from vw_banco_talentos where id = por_id;
  assert n = 2, 'candidato_id: conta as linhas do candidato, got ' || n;

  select total_historico into n from vw_banco_talentos where id = por_nome;
  assert n = 1, 'planilha antiga sem candidato_id: casa só pelo nome, got ' || n;

  select total_historico into n from vw_banco_talentos where id = por_tel;
  assert n = 1, 'planilha antiga sem candidato_id: casa só pelo telefone (com/sem "55"), got ' || n;

  select total_historico into n from vw_banco_talentos where id = sem_match;
  assert n = 0, 'sem nada em comum: total_historico = 0, got ' || n;

  -- ── o popup (historico_do_candidato): mesma regra de casamento ──
  assert (select count(*) from historico_do_candidato(por_id)) = 2, 'popup: candidato_id traz as 2 linhas';
  assert (select status from historico_do_candidato(por_nome) limit 1) = 'sem_interesse', 'popup: casa pelo nome';
  assert (select status from historico_do_candidato(por_tel) limit 1) = 'aprovado', 'popup: casa pelo telefone';
  assert (select count(*) from historico_do_candidato(sem_match)) = 0, 'popup: nada pra quem não tem histórico';

  -- ── filtro "Com passagem pelo RH" (fn_bate_colunas_avancadas), usado no Banco e em "Selecionar CVs" ──
  assert fn_bate_colunas_avancadas(por_id,    '{"tem_historico":true}'::jsonb), 'filtro: candidato_id bate';
  assert fn_bate_colunas_avancadas(por_nome,  '{"tem_historico":true}'::jsonb), 'filtro: nome bate';
  assert fn_bate_colunas_avancadas(por_tel,   '{"tem_historico":true}'::jsonb), 'filtro: telefone bate';
  assert not fn_bate_colunas_avancadas(sem_match, '{"tem_historico":true}'::jsonb), 'filtro: sem histórico não bate';
  assert fn_bate_colunas_avancadas(sem_match, '{}'::jsonb), 'sem o filtro (padrão), todo mundo bate';

  raise notice 'historico_no_banco: ok';
end $$;

rollback;
