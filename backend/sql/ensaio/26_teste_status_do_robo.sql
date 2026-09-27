-- Testes do STATUS DO ROBÔ e da janela de leitura (046): a linha única existe e começa ociosa, reaplicar a migração não zera o andamento
-- nem as configurações do administrador, as configurações novas existem e as antigas somem, e as permissões: usuário ativo só LÊ; nenhum
-- perfil do painel escreve; usuário inativo nem lê. Roda depois de 020–046. Tudo em uma transação que termina em ROLLBACK.
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.como(p_usuario uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_usuario::text, ''), true);
  reset role;
  if p_usuario is not null then set local role authenticated; end if;
end $$;

-- em produção as duas chaves antigas existem: cria para ver a 046 apagá-las
insert into configuracoes (chave, valor, descricao) values
  ('horario_execucao_pipeline', '"05:00"', 'Horário diário antigo.'),
  ('pipeline_ultima_execucao_diaria', '"2026-09-25"', 'Marcador antigo.')
on conflict (chave) do nothing;

\i /repo/backend/sql/046_status_do_robo.sql

do $$
declare
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';   -- gerente de RH
  dani  constant uuid := '00000000-0000-0000-0000-0000000000c9';   -- usuária inativa
  n int;
begin
  -- a linha única existe, ociosa e sem andamento
  assert (select count(*) from pipeline_status) = 1, 'uma linha só';
  assert (select estado from pipeline_status) = 'ocioso', 'começa ociosa';
  assert (select processando_total from pipeline_status) = 0, 'sem andamento';
  begin
    insert into pipeline_status (id) values (false);
    assert false, 'a linha "false" não pode existir';
  exception when check_violation then null; end;
  begin
    update pipeline_status set estado = 'dormindo';
    assert false, 'estado desconhecido não pode';
  exception when check_violation then null; end;

  -- as configurações da janela existem com os padrões pedidos (seg a sáb, 07:30 às 18:00, a cada 10 min) e as antigas sumiram
  assert (select valor from configuracoes where chave = 'leitura_intervalo_minutos') = '10'::jsonb, 'intervalo padrão';
  assert (select valor from configuracoes where chave = 'leitura_hora_inicio') = '"07:30"'::jsonb, 'início padrão';
  assert (select valor from configuracoes where chave = 'leitura_hora_fim') = '"18:00"'::jsonb, 'fim padrão';
  assert (select valor from configuracoes where chave = 'leitura_dias_semana') = '[1,2,3,4,5,6]'::jsonb, 'dias padrão';
  assert not exists (select 1 from configuracoes where chave in ('horario_execucao_pipeline', 'pipeline_ultima_execucao_diaria')),
    'as chaves da leitura diária única foram apagadas';

  -- o administrador muda o intervalo; o robô registra andamento; reaplicar a migração não desfaz nada disso
  perform pg_temp.como(admin);
  update configuracoes set valor = '15'::jsonb, updated_by = admin where chave = 'leitura_intervalo_minutos';
  perform pg_temp.como(null);
  update pipeline_status set estado = 'processando', processando_total = 12, processando_feitos = 5, nao_lidos = 7;
end $$;

\i /repo/backend/sql/046_status_do_robo.sql

do $$
declare
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  dani  constant uuid := '00000000-0000-0000-0000-0000000000c9';
  n int;
begin
  assert (select valor from configuracoes where chave = 'leitura_intervalo_minutos') = '15'::jsonb, 'reaplicar não desfaz a configuração';
  assert (select processando_feitos from pipeline_status) = 5 and (select estado from pipeline_status) = 'processando',
    'reaplicar não zera o andamento';

  -- usuário ativo LÊ o status (a tela Status é de todo o RH)
  perform pg_temp.como(beto);
  select count(*) into n from pipeline_status;
  assert n = 1, 'o RH lê o status';
  assert (select nao_lidos from pipeline_status) = 7, 'e vê os números';

  -- mas nenhum perfil do painel escreve: quem escreve é o robô, com a chave de serviço
  begin
    update pipeline_status set estado = 'ocioso';
    assert false, 'o RH não pode alterar o status';
  exception when insufficient_privilege then null; end;
  begin
    delete from pipeline_status;
    assert false, 'o RH não pode apagar o status';
  exception when insufficient_privilege then null; end;
  perform pg_temp.como(admin);
  begin
    update pipeline_status set estado = 'ocioso';
    assert false, 'nem o administrador altera o status pelo painel';
  exception when insufficient_privilege then null; end;

  -- usuário inativo (e quem nem está logado) não vê nada
  perform pg_temp.como(dani);
  select count(*) into n from pipeline_status;
  assert n = 0, 'usuário inativo não lê o status';
  perform pg_temp.como(null);
  reset role;
  set local role anon;
  begin
    perform 1 from pipeline_status;
    assert false, 'anônimo não lê o status';
  exception when insufficient_privilege then null; end;
  reset role;

  raise notice 'TESTES 046 (status do robô e janela de leitura): OK';
end $$;

rollback;
