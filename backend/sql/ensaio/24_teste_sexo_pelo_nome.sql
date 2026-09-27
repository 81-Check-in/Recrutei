-- Testes do SEXO ESTIMADO PELO NOME (041): a origem do sexo (informado / estimado pela IA / manual), a edição do RH que nunca é refeita
-- pela IA, a estimativa que não adia a sanitização e a view. Roda depois de 020–041. Tudo dentro de uma transação que termina em ROLLBACK.
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.como(p_usuario uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_usuario::text, ''), true);
  reset role;
  if p_usuario is not null then set local role authenticated; end if;
end $$;
create or replace function pg_temp.deve_falhar(p_sql text, p_trecho text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_trecho in sqlerrm) = 0 then
      raise exception 'falhou com a mensagem errada. Esperado conter [%], veio [%]', p_trecho, sqlerrm;
    end if;
    return;
  end;
  raise exception 'deveria ter falhado (esperado: %)', p_trecho;
end $$;

-- candidatos "de antes da 041": com sexo mas sem origem (o que o banco de produção tem hoje), um sem sexo, um estimado e um manual
create temp table t_c (papel text primary key, id uuid);
insert into t_c (papel, id)
select papel, (select id from candidatos where status_banco = 'ativo' order by id offset n limit 1)
  from (values ('antigo_com_sexo', 0), ('sem_sexo', 1), ('estimado', 2), ('manual', 3)) v(papel, n);
grant select on t_c to authenticated;

update candidatos set sexo = 'feminino', sexo_origem = null where id = (select id from t_c where papel = 'antigo_com_sexo');
update candidatos set sexo = null,       sexo_origem = null where id = (select id from t_c where papel = 'sem_sexo');
update candidatos set sexo = 'masculino', sexo_origem = 'ia_nome' where id = (select id from t_c where papel = 'estimado');
update candidatos set sexo = null,       sexo_origem = 'manual' where id = (select id from t_c where papel = 'manual');   -- o RH deixou em branco de propósito

\i /repo/backend/sql/041_sexo_pelo_nome.sql          -- reaplicar (o deploy repete tudo): completa só o que falta

do $$
declare
  beto constant uuid := '00000000-0000-0000-0000-0000000000b1';        -- gerente de RH
  antigo  uuid := (select id from t_c where papel = 'antigo_com_sexo');
  sem     uuid := (select id from t_c where papel = 'sem_sexo');
  estim   uuid := (select id from t_c where papel = 'estimado');
  manual  uuid := (select id from t_c where papel = 'manual');
  velho constant timestamptz := now() - interval '90 days';
  mov timestamptz; atu timestamptz;
begin
  -- ── a coluna e a migração dos dados ──
  assert (select sexo_origem from candidatos where id = antigo) = 'informado', 'quem já tinha sexo fica como "informado"';
  assert (select sexo_origem from candidatos where id = estim) = 'ia_nome', 'reaplicar não mexe no que já tem origem';
  assert (select sexo_origem is null from candidatos where id = sem), 'sem sexo continua sem origem';
  assert (select sexo is null and sexo_origem = 'manual' from candidatos where id = manual), 'o "em branco" do RH é preservado';
  assert (select count(*) from candidatos where sexo is not null and sexo_origem is null) = 0, 'nenhum sexo ficou sem origem';
  perform pg_temp.deve_falhar(format($f$update candidatos set sexo_origem = 'chute' where id = %L$f$, sem), 'sexo_origem_check');

  -- ── a view informa a origem ──
  assert (select sexo_origem from vw_banco_talentos where id = estim) = 'ia_nome', 'a view mostra a origem';
  assert (select sexo_origem from vw_banco_talentos where id = antigo) = 'informado';

  -- ── a estimativa da IA NÃO conta como movimentação (não adia a sanitização) ──
  update candidatos set ultima_movimentacao = velho, ultima_atualizacao = velho where id = sem;
  update candidatos set sexo = 'feminino', sexo_origem = 'ia_nome' where id = sem;            -- o robô completando o cadastro (service_role)
  select ultima_movimentacao, ultima_atualizacao into mov, atu from candidatos where id = sem;
  assert mov = velho and atu = velho, 'a estimativa não move o relógio da sanitização';
  -- ... mas um dado que veio do currículo, sim (como sempre foi)
  update candidatos set ultima_movimentacao = velho, ultima_atualizacao = velho, sexo = null, sexo_origem = null where id = sem;
  update candidatos set sexo = 'feminino', sexo_origem = 'informado' where id = sem;
  select ultima_movimentacao into mov from candidatos where id = sem;
  assert mov > velho, 'sexo informado pelo currículo continua contando como atualização';
  -- ... e outro campo alterado num candidato "estimado" também conta
  update candidatos set ultima_movimentacao = velho, sexo = 'feminino', sexo_origem = 'ia_nome' where id = sem;
  update candidatos set cidade = 'Outra Cidade' where id = sem;
  select ultima_movimentacao into mov from candidatos where id = sem;
  assert mov > velho, 'mudar a cidade conta, mesmo que o sexo seja estimado';

  -- ── o RH mexe no sexo: vira "manual" e vale sempre ──
  update candidatos set ultima_movimentacao = velho, ultima_atualizacao = velho, sexo = 'masculino', sexo_origem = 'ia_nome' where id = estim;
  perform pg_temp.como(beto);
  perform editar_candidato(estim, '{"sexo": "feminino"}');                                    -- a IA errou, o RH corrige
  assert (select sexo || '/' || sexo_origem from candidatos where id = estim) = 'feminino/manual', 'correção do RH vira manual';
  perform pg_temp.como(null);
  assert (select ultima_movimentacao > velho from candidatos where id = estim), 'a edição do RH conta como movimentação';

  perform pg_temp.como(beto);
  perform editar_candidato(estim, '{"cidade": "Ceilândia"}');                                 -- mexer em outro campo não muda a origem
  assert (select sexo_origem from candidatos where id = estim) = 'manual', 'outro campo não mexe na origem';
  perform editar_candidato(sem, '{"cidade": "Gama"}');
  assert (select sexo_origem from candidatos where id = sem) = 'ia_nome', 'editar outro campo de um estimado mantém "estimado"';

  perform editar_candidato(sem, '{"sexo": ""}');                                              -- "Não informado" no formulário
  assert (select sexo is null and sexo_origem = 'manual' from candidatos where id = sem), 'em branco pelo RH = decisão dele, não é refeita';
  perform pg_temp.deve_falhar(format($f$select editar_candidato(%L, '{"sexo": "outro"}')$f$, sem), 'Sexo deve ser masculino ou feminino');
  perform pg_temp.como(null);

  -- ── quem NÃO é o RH não escreve a origem pelo painel ──
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$update candidatos set sexo_origem = 'ia_nome' where id = %L$f$, sem), 'permission denied');
  assert (select count(*) from vw_banco_talentos where id in (antigo, sem, estim, manual)) = 4, 'o RH enxerga os candidatos na view';
  perform pg_temp.como(null);

  raise notice 'TESTE DO SEXO PELO NOME: tudo certo';
end $$;

rollback;
