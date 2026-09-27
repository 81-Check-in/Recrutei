-- Testes da PAUSA DE EMERGÊNCIA DA IA e do horário da rotina (040): a linha do interruptor existe e começa desligada, reaplicar a migração
-- NÃO desliga uma pausa em vigor, e só o administrador ativa ou desativa (o painel só faz UPDATE). Roda depois de 020–040.
-- Tudo dentro de uma transação que termina em ROLLBACK.
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.como(p_usuario uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_usuario::text, ''), true);
  reset role;
  if p_usuario is not null then set local role authenticated; end if;
end $$;

-- o horário existe em produção (o ensaio não o semeia): cria com a descrição antiga para ver a 040 reescrevê-la
insert into configuracoes (chave, valor, descricao) values
  ('horario_execucao_pipeline', '"05:00"', 'Horário diário de leitura da caixa de e-mail (America/Sao_Paulo).')
on conflict (chave) do nothing;

\i /repo/backend/sql/040_horario_e_pausa_da_ia.sql

do $$
declare
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';   -- gerente de RH
  dani  constant uuid := '00000000-0000-0000-0000-0000000000c9';   -- usuária inativa
  n int;
begin
  -- a linha existe, desligada, e o horário tem a descrição nova
  assert (select valor from configuracoes where chave = 'ia_pausada') = 'false'::jsonb, 'começa desligada';
  assert (select descricao from configuracoes where chave = 'horario_execucao_pipeline') like '%HH:MM%janela de 2 horas%',
    'a descrição do horário diz como ele funciona';

  -- reaplicar a migração (o deploy repete tudo) não desliga uma pausa em vigor
  perform pg_temp.como(admin);
  update configuracoes set valor = 'true'::jsonb, updated_by = admin where chave = 'ia_pausada';
  perform pg_temp.como(null);
  perform 1;
end $$;

\i /repo/backend/sql/040_horario_e_pausa_da_ia.sql

do $$
declare
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  dani  constant uuid := '00000000-0000-0000-0000-0000000000c9';
  n int;
begin
  assert (select valor from configuracoes where chave = 'ia_pausada') = 'true'::jsonb, 'reaplicar a 040 não desfaz a pausa';
  assert (select count(*) from configuracoes where chave = 'ia_pausada') = 1, 'uma linha só';

  -- todo usuário ativo LÊ o interruptor (o painel mostra o estado)
  perform pg_temp.como(beto);
  assert (select valor from configuracoes where chave = 'ia_pausada') = 'true'::jsonb, 'o gerente de RH vê o estado da pausa';

  -- mas só o administrador o muda: o gerente atualiza 0 linhas (a RLS filtra, não dá erro) e a pausa fica como estava
  update configuracoes set valor = 'false'::jsonb where chave = 'ia_pausada';
  get diagnostics n = row_count;
  assert n = 0, 'gerente de RH não desfaz a pausa';
  perform pg_temp.como(dani);
  update configuracoes set valor = 'false'::jsonb where chave = 'ia_pausada';
  get diagnostics n = row_count;
  assert n = 0, 'usuário inativo não desfaz a pausa';
  perform pg_temp.como(admin);
  assert (select valor from configuracoes where chave = 'ia_pausada') = 'true'::jsonb, 'continua pausada';

  -- o administrador desfaz e refaz (é o que o botão do painel faz), registrando quem foi
  update configuracoes set valor = 'false'::jsonb, updated_by = admin where chave = 'ia_pausada';
  get diagnostics n = row_count;
  assert n = 1, 'o administrador desativa';
  assert (select updated_by from configuracoes where chave = 'ia_pausada') = admin, 'fica registrado quem mexeu';
  update configuracoes set valor = 'true'::jsonb, updated_by = admin where chave = 'ia_pausada';
  assert (select valor from configuracoes where chave = 'ia_pausada') = 'true'::jsonb, 'e ativa de novo';

  -- ninguém cria nem apaga a linha pelo painel (sem política de INSERT/DELETE): o interruptor não some
  perform pg_temp.como(admin);
  begin
    insert into configuracoes (chave, valor, descricao) values ('ia_pausada_2', 'true'::jsonb, 'x');
    raise exception 'o administrador conseguiu criar uma configuração pelo painel';
  exception when insufficient_privilege then null;
  end;
  delete from configuracoes where chave = 'ia_pausada';
  get diagnostics n = row_count;
  assert n = 0, 'o painel não apaga o interruptor';

  raise notice 'TESTE DA PAUSA DA IA: tudo certo';
end $$;

rollback;
