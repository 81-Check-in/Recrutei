-- Testes de "Encaminhar ao gerente" (vagas do setor Loja) — 050/051. Roda depois de 020–051.
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
  beto        constant uuid := '00000000-0000-0000-0000-0000000000b1';
  loja        uuid; logistica uuid;
  vaga_loja   uuid; vaga_outra uuid;
  cand1 uuid; cand2 uuid; cand3 uuid;
  c1 uuid; c2 uuid; c3 uuid;
  s text;
begin
  select id into loja      from setores where nome = 'Loja';
  select id into logistica from setores where nome = 'Logística';

  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao)
    values (loja, 'V-Gerente Repositor', 1, 'Repositor', 'junior') returning id into vaga_loja;
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao)
    values (logistica, 'V-Gerente Logistica', 1, 'Auxiliar', 'junior') returning id into vaga_outra;

  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Teste Gerente Um',   'Brasília', 'DF', 'hash-gerente-1') returning id into cand1;
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Teste Gerente Dois',  'Brasília', 'DF', 'hash-gerente-2') returning id into cand2;
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Teste Gerente Tres',  'Brasília', 'DF', 'hash-gerente-3') returning id into cand3;

  perform pg_temp.como(beto);
  c1 := atribuir_candidato_vaga(cand1, vaga_loja);
  c2 := atribuir_candidato_vaga(cand2, vaga_loja);
  c3 := atribuir_candidato_vaga(cand3, vaga_outra);

  -- só vale para vagas do setor Loja
  perform pg_temp.deve_falhar(format($f$select encaminhar_ao_gerente(%L)$f$, c3), 'setor Loja');

  -- aprovar antes de encaminhar: não está aguardando o gerente
  perform pg_temp.deve_falhar(format($f$select aprovar_candidatura_gerente(%L)$f$, c1), 'aguardando a decisão do gerente');

  -- encaminhar: muda a fase e carimba quem/quando; aparece em vw_candidatos (a tela "Em processo")
  perform encaminhar_ao_gerente(c1);
  select status::text || '/' || (encaminhado_gerente_em is not null) || '/' || (encaminhado_gerente_por = beto)
    into s from candidaturas where id = c1;
  assert s = 'aguardando_gerente/true/true', 'encaminhar muda o status e carimba quem/quando, got ' || s;
  assert (select count(*) from vw_candidatos where id = c1) = 1, 'aguardando_gerente aparece em vw_candidatos';

  -- não dá para encaminhar de novo
  perform pg_temp.deve_falhar(format($f$select encaminhar_ao_gerente(%L)$f$, c1), 'já foi encaminhado');

  -- aprovar: status vira aprovado, a candidatura continua ABERTA (igual à aprovação por entrevista)
  perform aprovar_candidatura_gerente(c1);
  select status::text || '/' || (encerrada_em is null) || '/' || resultado_final
    into s from candidaturas where id = c1;
  assert s = 'aprovado/true/Aprovado pelo gerente da loja', 'aprovar pelo gerente, got ' || s;

  -- reprovar (depois de encaminhado) usa a mesma encerrar_candidatura de sempre: fecha e devolve ao banco
  perform encaminhar_ao_gerente(c2);
  perform encerrar_candidatura(c2, 'reprovado', 'Reprovado pelo gerente da loja');
  select ca.status::text || '/' || (ca.encerrada_em is not null) || '/' || ca.resultado_final || '/' || c.status_banco::text
    into s from candidaturas ca join candidatos c on c.id = ca.candidato_id where ca.id = c2;
  assert s = 'reprovado/true/Reprovado pelo gerente da loja/ativo', 'reprovar pelo gerente devolve ao banco, got ' || s;

  raise notice 'gerente_loja: ok';
end $$;

rollback;
