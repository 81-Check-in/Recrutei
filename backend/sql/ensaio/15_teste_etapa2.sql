-- Testes da ETAPA 2 (027 + 029): requisito Diferencial, palavras-chave da IA e ranking de candidatos por vaga.
-- Roda depois de 020–029. Tudo dentro de uma transação que termina em ROLLBACK.
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.como(p_usuario uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_usuario::text, ''), true);
  reset role;
  if p_usuario is not null then set local role authenticated; end if;
end $$;

do $$
declare
  beto constant uuid := '00000000-0000-0000-0000-0000000000b1';
  dani constant uuid := '00000000-0000-0000-0000-0000000000c9';   -- usuária inativa
  setor uuid; vaga uuid; vaga_vazia uuid; outra_vaga uuid;
  a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; g uuid; h uuid; x uuid; y uuid; z uuid; k uuid;
  cf uuid; r record; s text; n int; ids uuid[]; nota_a int; nota_h int; nota_c int; nota_x int; nota_y int;

  -- cria um candidato já com uma análise (palavras-chave, cargo, área)
  novo uuid;
begin
  select id into setor from setores order by nome limit 1;
  select id into outra_vaga from vagas where status = 'ativo' order by titulo limit 1;

  -- ── requisito Diferencial existe como tipo ──
  assert 'diferencial' = any (enum_range(null::tipo_requisito)::text[]), 'tipo_requisito tem diferencial';

  -- ── vaga com os três tipos de requisito ──
  insert into vagas (setor_id, titulo, descricao, perfil_comportamental, quantidade)
    values (setor, 'Auxiliar Contábil', 'Rotinas contábeis e fiscais: lançamentos, conciliações e apoio ao fechamento mensal.',
            'Analítico, organizado e ético', 1) returning id into vaga;
  insert into requisitos (vaga_id, descricao, tipo, peso, ordem) values
    (vaga, 'Formação cursando ou concluída em Ciências Contábeis', 'obrigatorio', 2, 1),
    (vaga, 'Experiência em rotinas contábeis e fiscais',            'desejavel',   3, 2),
    (vaga, 'Domínio de Excel',                                       'desejavel',   2, 3),
    (vaga, 'Experiência com sistemas contábeis',                     'desejavel',   2, 4),
    (vaga, 'Registro no CRC',                                        'diferencial', 1, 5);
  assert (select count(*) from requisitos where vaga_id = vaga and tipo = 'diferencial') = 1, 'requisito diferencial gravado';

  -- termos da vaga: título e requisitos entram; palavras genéricas de RH não
  assert exists (select 1 from fn_termos_vaga(vaga) where termo like 'contab%'), 'radical de contábil/contabilidade';
  assert exists (select 1 from fn_termos_vaga(vaga) where termo = 'excel'), 'excel entra';
  assert not exists (select 1 from fn_termos_vaga(vaga) where termo like 'experi%'), '"experiência" é genérica e não entra';
  assert (select peso from fn_termos_vaga(vaga) where termo = 'excel') = 4, 'excel: desejável (2) × peso 2 = 4';
  assert (select peso from fn_termos_vaga(vaga) where termo = 'crc') = 1, 'crc: diferencial (1) × peso 1 = 1';
  assert (select max(peso) from fn_termos_vaga(vaga) where termo like 'contab%') >= 6, 'contábil: obrigatório (3) × peso 2 = 6 ou mais';

  -- ── candidatos ──
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand A', 'Ceilândia', 'DF', 'h-a') returning id into a;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia,
                           palavras_chave, pontos_positivos)
    values (a, 1, 'Financeiro', 'Auxiliar', 'pleno', 85, 't',
            array['auxiliar contábil', 'conciliação bancária', 'Excel avançado', 'sped', 'contabilidade'],
            array['3 anos em escritório de contabilidade']);
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand B', 'Gama', 'DF', 'h-b') returning id into b;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
    values (b, 1, 'Logística', 'Conferente', 'pleno', 80, 't', array['conferente', 'empilhadeira', 'expedição']);
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand C', 'Gama', 'DF', 'h-c') returning id into c;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
    values (c, 1, 'Atendimento', 'Atendente', 'junior', 70, 't', array['excel', 'atendimento ao cliente']);
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand H', 'Guará', 'DF', 'h-h') returning id into h;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
    values (h, 1, 'Financeiro', 'Assistente Contábil', 'junior', 75, 't', array['CRC', 'contabilidade']);

  -- os que NÃO podem aparecer, mesmo combinando: inativo, lista negra, reprovado nesta vaga, em processo (outra vaga)
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand D inativo', 'Gama', 'DF', 'h-d') returning id into d;
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand E lista negra', 'Gama', 'DF', 'h-e') returning id into e;
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand F reprovado aqui', 'Gama', 'DF', 'h-f') returning id into f;
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand G em processo', 'Gama', 'DF', 'h-g') returning id into g;
  foreach novo in array array[d, e, f, g] loop
    insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
      values (novo, 1, 'Financeiro', 'Auxiliar', 'pleno', 85, 't', array['auxiliar contábil', 'excel avançado', 'contabilidade']);
  end loop;
  update candidatos set status_banco = 'inativo', inativado_em = now() where id = d;
  update candidatos set lista_negra = true where id = e;       -- ainda 'ativo' de propósito: o ranking não pode depender só do status
  perform pg_temp.como(beto);
  cf := atribuir_candidato_vaga(f, vaga);
  perform atribuir_candidato_vaga(g, outra_vaga);
  perform pg_temp.como(null);
  update candidaturas set status = 'reprovado', resultado_final = 'não atendeu' where id = cf;
  assert (select status_banco from candidatos where id = f) = 'ativo', 'o reprovado voltou ao banco (a regra do descarte é que o exclui do ranking)';

  -- genéricos e sem relação
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand Z genérico', 'Gama', 'DF', 'h-z') returning id into z;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
    values (z, 1, 'Outros', 'Operador', 'junior', 60, 't', array['experiência', 'conhecimento', 'bom relacionamento']);

  -- ── gatilhos: texto de busca e cópia das palavras-chave para o candidato ──
  assert (select busca_tsv is not null from analises_ia where candidato_id = a), 'busca_tsv preenchido pelo gatilho';
  assert (select palavras_chave from candidatos where id = a) = array['auxiliar contábil', 'conciliação bancária', 'Excel avançado', 'sped', 'contabilidade'],
    'o candidato recebe as palavras-chave da análise vigente';
  assert (select array_length(palavras_chave, 1) from vw_banco_talentos where id = a) = 5, 'a view do banco informa as palavras-chave';

  -- ── ranking ──
  perform pg_temp.como(beto);
  select array_agg(candidato_id) into ids from ranking_candidatos_vaga(vaga, 100);
  assert (select candidato_id from ranking_candidatos_vaga(vaga) limit 1) = a, 'quem combina em tudo vem primeiro';
  assert a = any (ids) and c = any (ids) and h = any (ids), 'A, C e H combinam com alguma coisa';
  assert not (b = any (ids)), 'B (logística) não combina com nada e fica de fora';
  assert not (z = any (ids)), 'palavras genéricas ("experiência", "conhecimento") não casam com ninguém';
  assert not (d = any (ids)), 'inativo fora';
  assert not (e = any (ids)), 'lista negra fora';
  assert not (f = any (ids)), 'reprovado NESTA vaga fora, mesmo disponível no banco';
  assert not (g = any (ids)), 'em processo fora';

  select aderencia into nota_a from ranking_candidatos_vaga(vaga) where candidato_id = a;
  select aderencia into nota_h from ranking_candidatos_vaga(vaga) where candidato_id = h;
  select aderencia into nota_c from ranking_candidatos_vaga(vaga) where candidato_id = c;
  assert nota_a > nota_h and nota_a > nota_c, format('A (%s) acima de H (%s) e C (%s)', nota_a, nota_h, nota_c);
  assert nota_a between 1 and 100 and nota_c between 1 and 100, 'nota entre 1 e 100';

  select termos_casados into r from ranking_candidatos_vaga(vaga) where candidato_id = a;
  assert 'Excel avançado' = any (r.termos_casados) and 'contabilidade' = any (r.termos_casados), 'mostra as palavras-chave que casaram';
  assert not ('sped' = any (r.termos_casados)), 'o que não casou não aparece';

  -- Diferencial pesa menos que Desejável: só "crc" (diferencial) x só "excel" (desejável)
  perform pg_temp.como(null);
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand X só crc', 'Gama', 'DF', 'h-x') returning id into x;
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand Y só excel', 'Gama', 'DF', 'h-y') returning id into y;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
    values (x, 1, 'Outros', 'Operador', 'junior', 60, 't', array['crc']),
           (y, 1, 'Outros', 'Operador', 'junior', 60, 't', array['excel']);
  perform pg_temp.como(beto);
  select aderencia into nota_x from ranking_candidatos_vaga(vaga) where candidato_id = x;
  select aderencia into nota_y from ranking_candidatos_vaga(vaga) where candidato_id = y;
  assert nota_y > nota_x, format('desejável (%s) pesa mais que diferencial (%s)', nota_y, nota_x);
  assert nota_x >= 1, 'diferencial ainda soma pontos';

  -- caixa e acento não atrapalham; o radical junta contábil/contábeis/contabilidade
  perform pg_temp.como(null);
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand K', 'Gama', 'DF', 'h-k') returning id into k;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
    values (k, 1, 'Outros', 'Operador', 'junior', 60, 't', array['ROTINAS CONTABEIS', 'Fiscal']);
  perform pg_temp.como(beto);
  assert exists (select 1 from ranking_candidatos_vaga(vaga) where candidato_id = k), 'CONTABEIS casa com contábeis (caixa, acento e radical)';

  -- paginação estável
  n := (select count(*) from ranking_candidatos_vaga(vaga, 100));
  assert n >= 5, 'pelo menos 5 no ranking, got ' || n;
  assert (select array_agg(candidato_id) from ranking_candidatos_vaga(vaga, 2, 0))
       || (select array_agg(candidato_id) from ranking_candidatos_vaga(vaga, 2, 2))
       = (select array_agg(candidato_id) from ranking_candidatos_vaga(vaga, 4, 0)), 'páginas consecutivas = lista contínua';
  assert (select count(*) from ranking_candidatos_vaga(vaga, 1000, 1000)) = 0, 'além do fim: vazio';

  -- o total acompanha o ranking inteiro, não a página
  assert (select min(total) from ranking_candidatos_vaga(vaga, 2, 0)) = n and (select max(total) from ranking_candidatos_vaga(vaga, 2, 0)) = n,
    'total = todos os que combinam, mesmo pedindo só 2';

  -- vaga sem termos úteis (só palavras genéricas): ranking vazio, sem erro
  perform pg_temp.como(null);
  insert into vagas (setor_id, titulo, quantidade) values (setor, 'Experiência', 1) returning id into vaga_vazia;
  perform pg_temp.como(beto);
  assert (select count(*) from ranking_candidatos_vaga(vaga_vazia)) = 0, 'vaga sem termos úteis: ranking vazio';
  assert (select count(*) from ranking_candidatos_vaga(gen_random_uuid())) = 0, 'vaga inexistente: ranking vazio';

  -- a RLS vale: usuário inativo não enxerga candidato nenhum; anônimo nem executa
  perform pg_temp.como(dani);
  assert (select count(*) from ranking_candidatos_vaga(vaga)) = 0, 'usuário inativo não recebe ranking (RLS)';
  perform pg_temp.como(null);
  reset role;
  set local role anon;
  begin
    perform 1 from ranking_candidatos_vaga(vaga);
    raise exception 'anon não deveria executar o ranking';
  exception when insufficient_privilege then null;
  end;
  reset role;

  -- reanálise: a análise mais nova troca as palavras-chave do candidato e do ranking
  perform pg_temp.como(null);
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
    values (a, 2, 'Logística', 'Conferente', 'pleno', 80, 't', array['conferente', 'empilhadeira']);
  assert (select palavras_chave from candidatos where id = a) = array['conferente', 'empilhadeira'], 'palavras-chave da análise mais nova';
  perform pg_temp.como(beto);
  assert not exists (select 1 from ranking_candidatos_vaga(vaga) where candidato_id = a), 'depois da reanálise A já não combina';

  raise notice 'TESTE DA ETAPA 2: tudo certo';
end $$;

rollback;
