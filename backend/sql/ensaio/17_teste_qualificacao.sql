-- Testes da QUALIFICAÇÃO DO CURRÍCULO (031): níveis, funções por setor e os três campos gravados no currículo.
-- Roda depois de 020–031. Tudo dentro de uma transação que termina em ROLLBACK.
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
  dani constant uuid := '00000000-0000-0000-0000-0000000000c9';   -- usuária inativa
  setor uuid; cand uuid; curr uuid; n int;
begin
  -- ── níveis ──
  assert (select count(*) from niveis_funcao) = 5, 'cinco níveis';
  assert (select array_agg(codigo order by ordem) from niveis_funcao) = array['jovem_aprendiz', 'trainee', 'junior', 'pleno', 'senior'],
    'os níveis do modelo real, do mais iniciante ao mais sênior (Estágio virou Trainee; Liderança deixou de ser nível)';
  assert (select bool_and(descricao is not null) from niveis_funcao), 'todo nível traz o critério que a IA recebe';
  perform pg_temp.deve_falhar($f$insert into niveis_funcao (codigo, nome, ordem) values ('master', 'Master', 6)$f$, 'niveis_funcao_codigo_check');
  perform pg_temp.deve_falhar($f$insert into niveis_funcao (codigo, nome, ordem) values ('lideranca', 'Liderança', 6)$f$, 'niveis_funcao_codigo_check');
  perform pg_temp.deve_falhar($f$update candidatos set nivel_sugerido = 'lideranca'$f$, 'candidatos_nivel_sugerido_check');
  perform pg_temp.deve_falhar($f$update analises_ia set nivel_sugerido = 'estagio'$f$, 'analises_ia_nivel_sugerido_check');

  -- ── funções: só existem dentro de um setor, sem repetir ──
  select id into setor from setores where nome = 'Logística';
  assert setor is not null, 'o ensaio tem o setor Logística';
  assert (select count(*) from funcoes_setor where setor_id = setor) > 0, 'a carga inicial cobre os setores que existem';
  -- o modelo real (BRMODELO - SETORES E CARGOS): 13 setores, 51 pares setor/cargo
  assert (select count(*) from setores where nome in ('Loja', 'Logística', 'Auditoria', 'DP', 'RH', 'TI', 'Financeiro', 'Cadastro',
                                                      'Recepção', 'Controladoria', 'CR', 'Marketing', 'Compras')) = 13, 'os 13 setores do modelo existem';
  assert (select count(*) from funcoes_setor) = 51, 'o modelo tem 51 pares setor/cargo';
  assert (select array_agg(s.nome || '/' || f.nome order by s.nome) from funcoes_setor f join setores s on s.id = f.setor_id where f.aceita_iniciante)
         = array['DP/Auxiliar', 'Logística/Auxiliar', 'Loja/Repositor', 'RH/Auxiliar'],
    'Jovem Aprendiz e Trainee só nestes quatro cargos';
  assert not exists (select 1 from funcoes_setor f join setores s on s.id = f.setor_id where s.nome = 'Serviços Gerais' or f.nome in ('Conferente', 'Atendente')),
    'sem setores e cargos que não existem no modelo (Serviços Gerais, Conferente, Atendente)';
  assert (select count(*) from funcoes_setor f join setores s on s.id = f.setor_id where s.nome = 'Recepção' and f.nome = 'Recepcionista') = 1, 'Recepcionista é da Recepção';
  assert (select count(*) from funcoes_setor f join setores s on s.id = f.setor_id where s.nome = 'Logística' and f.nome = 'Supervisor') = 1, 'Supervisor em Logística';
  perform pg_temp.deve_falhar(format($f$insert into funcoes_setor (setor_id, nome) values (%L, 'Supervisor')$f$, setor), 'uq_funcao_setor');
  perform pg_temp.deve_falhar(format($f$insert into funcoes_setor (setor_id, nome) values (%L, '   ')$f$, setor), 'funcoes_setor_nome_check');
  perform pg_temp.deve_falhar($f$insert into funcoes_setor (setor_id, nome) values (gen_random_uuid(), 'Fantasma')$f$, 'foreign key');
  -- a mesma função em setores diferentes é permitida (Vendedor em Loja e em CR, Auxiliar em vários)
  insert into funcoes_setor (setor_id, nome) select id, 'Função Repetida' from setores where nome in ('Logística', 'Loja');
  assert (select count(*) from funcoes_setor where nome = 'Função Repetida') = 2, 'mesma função em dois setores';

  -- ── o resultado no currículo ──
  insert into candidatos (nome, hash_identidade) values ('Teste Qualificação', 'hash-qualificacao') returning id into cand;
  insert into curriculos (candidato_id, origem, texto_extraido, setor_adequado, funcao_setor, nivel_funcao)
    values (cand, 'anexo_pdf', 'Supervisor há 4 anos em centro de distribuição.', 'Logística', 'Supervisor', 'pleno')
    returning id into curr;
  assert (select setor_adequado = 'Logística' and funcao_setor = 'Supervisor' and nivel_funcao = 'pleno' from curriculos where id = curr),
    'os três campos gravam';
  perform pg_temp.deve_falhar(format($f$update curriculos set nivel_funcao = 'master' where id = %L$f$, curr), 'curriculos_nivel_funcao_fkey');
  -- currículo sem qualificação continua válido (é o caso de todos os anteriores a esta migração)
  update curriculos set setor_adequado = null, funcao_setor = null, nivel_funcao = null where id = curr;
  update curriculos set setor_adequado = 'Logística', funcao_setor = 'Supervisor', nivel_funcao = 'pleno' where id = curr;

  -- mudar o texto (currículo reprocessado) não apaga a qualificação; esvaziar o texto (expurgo) apaga
  update curriculos set texto_extraido = 'Supervisor há 5 anos.' where id = curr;
  assert (select nivel_funcao from curriculos where id = curr) = 'pleno', 'texto novo: a qualificação fica (o pipeline regrava)';
  update curriculos set nome_arquivo = 'outro.pdf' where id = curr;
  assert (select setor_adequado from curriculos where id = curr) = 'Logística', 'outra coluna: a qualificação fica';
  update curriculos set texto_extraido = null where id = curr;
  assert (select setor_adequado is null and funcao_setor is null and nivel_funcao is null from curriculos where id = curr),
    'texto esvaziado (expurgo): a qualificação sai junto';

  -- o nível some do cadastro: o currículo perde o nível, não a linha
  update curriculos set texto_extraido = 'x', nivel_funcao = 'senior' where id = curr;
  delete from niveis_funcao where codigo = 'senior';
  assert (select nivel_funcao is null from curriculos where id = curr), 'apagar o nível não apaga o currículo';
  assert exists (select 1 from curriculos where id = curr), 'o currículo continua lá';

  -- ── sanitização: sem confiança registrada não é "dado incompleto" (o prompt atual não devolve confiança) ──
  insert into analises_ia (candidato_id, sequencia, versao_modelo_ia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca)
    values (cand, 1, 'teste', 'Logística', 'Supervisor', 'pleno', null);
  assert (select ia_confianca is null and nivel_sugerido = 'pleno' from candidatos where id = cand), 'a análise sem confiança chega ao candidato';
  assert not exists (select 1 from fn_sanitizacao_avaliar(fn_sanitizacao_parametros()) where candidato_id = cand),
    'classificado e sem confiança registrada: não entra na sanitização';
  insert into analises_ia (candidato_id, sequencia, versao_modelo_ia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca)
    values (cand, 2, 'teste', 'Logística', 'Supervisor', 'pleno', 20);
  assert exists (select 1 from fn_sanitizacao_avaliar(fn_sanitizacao_parametros()) where candidato_id = cand and 'dados_incompletos' = any(motivos)),
    'confiança registrada e baixa continua contando';
  insert into analises_ia (candidato_id, sequencia, versao_modelo_ia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca)
    values (cand, 3, 'teste', 'Logística', null, 'pleno', null);
  assert exists (select 1 from fn_sanitizacao_avaliar(fn_sanitizacao_parametros()) where candidato_id = cand and 'dados_incompletos' = any(motivos)),
    'sem função classificada: dado incompleto, com ou sem confiança';

  -- ── acesso: leitura para usuário ativo; nada de escrita pelo painel ──
  perform pg_temp.como(beto);
  assert (select count(*) from niveis_funcao) = 4, 'RH ativo lê os níveis';
  assert (select count(*) from funcoes_setor) > 0, 'RH ativo lê as funções';
  perform pg_temp.deve_falhar($f$insert into funcoes_setor (setor_id, nome) values (gen_random_uuid(), 'x')$f$, 'permission denied');
  perform pg_temp.deve_falhar($f$update niveis_funcao set nome = 'x'$f$, 'permission denied');
  perform pg_temp.deve_falhar($f$delete from funcoes_setor$f$, 'permission denied');
  perform pg_temp.como(dani);
  assert (select count(*) from niveis_funcao) = 0 and (select count(*) from funcoes_setor) = 0, 'usuário inativo não vê nada';
  perform pg_temp.como(null);
  set local role anon;
  begin
    perform 1 from funcoes_setor;
    raise exception 'anon não deveria ler funcoes_setor';
  exception when insufficient_privilege then null;
  end;
  reset role;

  raise notice 'TESTE DA QUALIFICAÇÃO: tudo certo';
end $$;

rollback;
