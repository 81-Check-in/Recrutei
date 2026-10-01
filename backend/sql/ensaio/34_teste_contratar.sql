-- Testes de "Contratar" (070). Roda depois de 020–070.
-- Tudo dentro de uma transação que termina em ROLLBACK: não deixa nada no banco.
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

do $$
declare
  beto constant uuid := '00000000-0000-0000-0000-0000000000b1';
  loja uuid; vaga uuid; cand uuid; c uuid;
  s text;
begin
  select id into loja from setores where nome = 'Loja';
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao)
    values (loja, 'V-Contratar Vendedor', 1, 'Vendedor', 'junior') returning id into vaga;
  insert into candidatos (nome, cidade, uf, hash_identidade)
    values ('Teste Contratar Um', 'Brasília', 'DF', 'hash-contratar-1') returning id into cand;

  perform pg_temp.como(beto);
  c := atribuir_candidato_vaga(cand, vaga);

  -- ainda não aprovado: não contrata
  perform pg_temp.deve_falhar(format($f$select contratar_candidatura(%L)$f$, c), 'candidato aprovado');

  perform encaminhar_ao_gerente(c);
  perform aprovar_candidatura_gerente(c);
  assert (select total_contratados from vw_vagas_resumo where id = vaga) = 0, 'aprovado ainda não conta como contratado';

  -- contratar: fecha a candidatura, o candidato sai do banco (inativo, retenção permanente) e a vaga conta 1
  perform contratar_candidatura(c);
  select ca.status::text || '/' || (ca.encerrada_em is not null) || '/' || k.status_banco::text || '/' || k.retencao_permanente
    into s from candidaturas ca join candidatos k on k.id = ca.candidato_id where ca.id = c;
  assert s = 'contratado/true/inativo/true', 'contratar fecha e tira do banco, got ' || s;
  assert (select total_contratados from vw_vagas_resumo where id = vaga) = 1, 'a vaga conta o contratado';
  assert (select count(*) from vw_candidatos where id = c and status = 'contratado') = 1, 'contratado aparece na lista da vaga';

  -- não contrata duas vezes
  perform pg_temp.deve_falhar(format($f$select contratar_candidatura(%L)$f$, c), 'já foi encerrada');

  raise notice 'contratar: ok';
end $$;

rollback;
