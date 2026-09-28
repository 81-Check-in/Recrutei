-- Testes de "Selecionar CVs" com os mesmos filtros do Banco de Talentos (049).
-- fn_bate_filtros_avancados (texto: palavras/local/email/telefone/cargos/rotatividade) já é testado a fundo em 28,
-- via filtrar_banco_talentos (que passou a delegar para ela); aqui só confirma que selecionar_curriculos_vaga
-- também usa a MESMA função. fn_bate_colunas_avancadas (idade/escolaridade/experiência/cnh/revisão) é NOVA: testada
-- a fundo aqui, espelhando aplicarColunasAvancadas() (frontend/js/banco-talentos.js). Roda depois de 020–049.
-- Cada grupo usa a sua própria vaga para não misturar candidatos de um teste com o filtro de outro. Termina em ROLLBACK.
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.cand(
  p_nome text, p_nota int, p_vaga uuid,
  p_nascimento date default null, p_escolaridade text default null, p_anos_exp numeric default null,
  p_cnh text default null, p_revisao boolean default false,
  p_cidade text default null, p_email text default null, p_telefone text default null, p_texto text default null
) returns uuid language plpgsql as $$
declare v uuid; v_setor text; v_funcao text; v_nivel text;
begin
  select s.nome, vg.funcao_setor, vg.nivel_funcao into v_setor, v_funcao, v_nivel
    from vagas vg join setores s on s.id = vg.setor_id where vg.id = p_vaga;
  insert into candidatos (nome, cidade, data_nascimento, escolaridade, anos_experiencia, cnh, revisao_manual, email, telefone)
    values (p_nome, p_cidade, p_nascimento, p_escolaridade, p_anos_exp, p_cnh, p_revisao, p_email, p_telefone)
    returning id into v;
  insert into curriculos (candidato_id, origem, texto_extraido, setor_adequado, funcao_setor, nivel_funcao, nota_classificacao)
    values (v, 'anexo_pdf', coalesce(p_texto, 'Currículo de ' || p_nome), v_setor, v_funcao, v_nivel, p_nota);
  return v;
end $$;

-- nomes na ordem que a seleção devolveu (nota desc, como sempre)
create or replace function pg_temp.ordem(p_vaga uuid, p_filtros jsonb default '{}'::jsonb, p_colunas jsonb default '{}'::jsonb, p_cidade text default null)
returns text[] language sql as $$
  select coalesce(array_agg(c.nome order by t.ord), '{}')
    from selecionar_curriculos_vaga(p_vaga, 50, 0, 'nota', null, null, null, p_filtros, p_colunas, p_cidade)
           with ordinality t(candidato_id, nota, total, km, loja, ord)
    join candidatos c on c.id = t.candidato_id
$$;

do $$
declare
  logistica uuid;
  v_idade uuid; v_escol uuid; v_exp uuid; v_revisao uuid; v_palavras uuid; v_texto uuid; v_cidade uuid; v_combo uuid;
  a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; g uuid; h uuid; i uuid; j uuid; k uuid; m uuid;
  n uuid; o uuid; p uuid; q uuid; r uuid; s uuid; t1 uuid; t2 uuid; t3 uuid; a_ia uuid;
begin
  select id into logistica from setores where nome = 'Logística';

  -- ── IDADE (nascimento_ref): duas pontas + "incluir quem não informou" ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'V49 Idade', 1, 'Supervisor', 'pleno') returning id into v_idade;
  a := pg_temp.cand('Sel49 A25', 90, v_idade, (current_date - interval '25 years')::date);
  b := pg_temp.cand('Sel49 B40', 80, v_idade, (current_date - interval '40 years')::date);
  c := pg_temp.cand('Sel49 CSemIdade', 70, v_idade, null);

  assert pg_temp.ordem(v_idade) = array['Sel49 A25', 'Sel49 B40', 'Sel49 CSemIdade'], 'sem filtro de coluna: comportamento de sempre';
  assert pg_temp.ordem(v_idade, '{}', '{"idade_min":30}') = array['Sel49 B40', 'Sel49 CSemIdade'],
    'idade mínima: exclui quem tem menos; "incluir sem info" (padrão true) deixa passar quem não informou';
  assert pg_temp.ordem(v_idade, '{}', '{"idade_min":30,"incluir_sem_info":false}') = array['Sel49 B40'], 'sem incluir quem não informou';
  assert pg_temp.ordem(v_idade, '{}', '{"idade_max":30}') = array['Sel49 A25', 'Sel49 CSemIdade'], 'idade máxima';
  assert pg_temp.ordem(v_idade, '{}', '{"idade_max":30,"incluir_sem_info":false}') = array['Sel49 A25'], 'idade máxima, sem incluir quem não informou';
  assert pg_temp.ordem(v_idade, '{}', '{"idade_min":20,"idade_max":30}') = array['Sel49 A25', 'Sel49 CSemIdade'], 'as duas pontas juntas';
  assert pg_temp.ordem(v_idade, '{}', '{"idade_min":100}') = array['Sel49 CSemIdade'], 'ninguém tem 100+ anos: só quem não informou (padrão) fica';

  -- ── ESCOLARIDADE (escolaridade_ord) ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'V49 Escolaridade', 1, 'Supervisor', 'senior') returning id into v_escol;
  d := pg_temp.cand('Sel49 DMedio', 60, v_escol, null, 'medio');
  e := pg_temp.cand('Sel49 ESuperior', 50, v_escol, null, 'superior');
  f := pg_temp.cand('Sel49 FSemInfo', 40, v_escol, null, null);

  assert pg_temp.ordem(v_escol, '{}', '{"escolaridade_min":"tecnico"}') = array['Sel49 ESuperior', 'Sel49 FSemInfo'],
    'exige pelo menos técnico: médio fica de fora, sem info entra (padrão)';
  assert pg_temp.ordem(v_escol, '{}', '{"escolaridade_min":"tecnico","incluir_sem_info":false}') = array['Sel49 ESuperior'], 'sem incluir quem não informou';
  assert pg_temp.ordem(v_escol, '{}', '{"escolaridade_min":"medio"}') = array['Sel49 DMedio', 'Sel49 ESuperior', 'Sel49 FSemInfo'], 'médio também atende "pelo menos médio"';

  -- ── EXPERIÊNCIA (anos_experiencia) ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'V49 Experiencia', 1, 'Supervisor', 'junior') returning id into v_exp;
  g := pg_temp.cand('Sel49 G1Ano', 30, v_exp, null, null, 1);
  h := pg_temp.cand('Sel49 H5Anos', 20, v_exp, null, null, 5);
  i := pg_temp.cand('Sel49 ISemInfo', 10, v_exp, null, null, null);

  assert pg_temp.ordem(v_exp, '{}', '{"experiencia_min":3}') = array['Sel49 H5Anos', 'Sel49 ISemInfo'], 'experiência mínima: sem info entra (padrão)';
  assert pg_temp.ordem(v_exp, '{}', '{"experiencia_min":3,"incluir_sem_info":false}') = array['Sel49 H5Anos'], 'sem incluir quem não informou';

  -- ── REVISÃO MANUAL ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'V49 Revisao', 1, 'Encarregado', 'pleno') returning id into v_revisao;
  j := pg_temp.cand('Sel49 JSemRevisao', 90, v_revisao, null, null, null, null, false);
  k := pg_temp.cand('Sel49 KRevisao', 80, v_revisao, null, null, null, null, true);

  assert pg_temp.ordem(v_revisao, '{}', '{"revisao":true}') = array['Sel49 KRevisao'], 'só revisão manual pendente';
  assert pg_temp.ordem(v_revisao) = array['Sel49 JSemRevisao', 'Sel49 KRevisao'], 'sem filtro: todos';

  -- ── PALAVRAS-CHAVE: sempre "qualquer uma delas" e sempre no currículo E na análise da IA juntos (049, sem seletor na tela) ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'V49 Palavras', 1, 'Auxiliar', 'pleno') returning id into v_palavras;
  t1 := pg_temp.cand('Sel49 T1Empilhadeira', 90, v_palavras, null, null, null, null, false, null, null, null, 'Currículo com a palavra empilhadeira');
  t2 := pg_temp.cand('Sel49 T2OutraCoisa', 80, v_palavras, null, null, null, null, false, null, null, null, 'Currículo sobre outra coisa qualquer');
  assert pg_temp.ordem(v_palavras, '{"palavras":["empilhadeira","outra coisa"]}') = array['Sel49 T1Empilhadeira', 'Sel49 T2OutraCoisa'],
    'sempre "qualquer uma": T1 tem só a 1ª, T2 só a 2ª, os dois entram';

  -- T3: a palavra só está no resumo da IA, não no currículo — sem seletor de "onde", tem que achar mesmo assim
  t3 := pg_temp.cand('Sel49 T3SoNaAnalise', 70, v_palavras, null, null, null, null, false, null, null, null, 'Currículo sem nenhuma palavra-chave especial');
  insert into analises_ia (candidato_id, sequencia, texto_resumo_ia, versao_modelo_ia)
    values (t3, 1, 'Perfil forte para operar paleteira e outros equipamentos', 'teste') returning id into a_ia;
  update candidatos set analise_atual_id = a_ia where id = t3;
  assert pg_temp.ordem(v_palavras, '{"palavras":["paleteira"]}') = array['Sel49 T3SoNaAnalise'],
    'sempre busca também na análise da IA, sem precisar escolher "onde"';

  -- ── FILTROS DE TEXTO (p_filtros): confirma que a seleção usa fn_bate_filtros_avancados, sem repetir os casos de 28 ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'V49 Texto', 1, 'Encarregado', 'senior') returning id into v_texto;
  n := pg_temp.cand('Sel49 NComEmail', 90, v_texto, null, null, null, null, false, null, 'nina49@empresa.com',
        null, E'Experiência profissional\nMotorista de caminhão (2019-2023)');
  o := pg_temp.cand('Sel49 OSemEmail', 80, v_texto, null, null, null, null, false, null, 'outra@empresa.com', null,
        E'Objetivo: motorista\nExperiência profissional\nAuxiliar de estoque (2020-2022)');

  assert pg_temp.ordem(v_texto, '{"email":"nina49"}') = array['Sel49 NComEmail'], 'p_filtros chega até a função (e-mail)';
  assert pg_temp.ordem(v_texto, '{"cargos_experiencia":["motorista"]}') = array['Sel49 NComEmail'],
    'p_filtros chega até a função (cargo com experiência; N foi motorista, O só QUER ser)';
  assert pg_temp.ordem(v_texto, '{"palavras":["estoque"]}') = array['Sel49 OSemEmail'], 'p_filtros chega até a função (palavras-chave)';

  -- ── CIDADE (p_cidade): prefixo, sem diferenciar maiúsculas/acentos (norm_busca) ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'V49 Cidade', 1, 'Encarregado', 'junior') returning id into v_cidade;
  p := pg_temp.cand('Sel49 PBrasilia', 90, v_cidade, null, null, null, null, false, 'Brasília');
  q := pg_temp.cand('Sel49 QGoiania', 80, v_cidade, null, null, null, null, false, 'Goiânia');

  -- p_cidade chega CRU na função (quem normaliza antes de mandar é o JS, como o resto do painel já faz);
  -- o prefixo sem acento funciona porque cidade_norm já é gerada normalizada na origem.
  assert pg_temp.ordem(v_cidade, '{}', '{}', 'brasi') = array['Sel49 PBrasilia'], 'prefixo da cidade, sem acento';
  assert pg_temp.ordem(v_cidade) = array['Sel49 PBrasilia', 'Sel49 QGoiania'], 'sem p_cidade: todos';

  -- ── COMBINADO: p_filtros + p_colunas + p_cidade juntos, como o painel manda ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'V49 Combo', 1, 'Auxiliar', 'pleno') returning id into v_combo;
  r := pg_temp.cand('Sel49 RCombina', 90, v_combo, (current_date - interval '35 years')::date, 'superior', 5, 'AB', false, 'Brasília', 'rita49@x.com');
  s := pg_temp.cand('Sel49 SFalhaIdade', 80, v_combo, (current_date - interval '18 years')::date, 'superior', 5, 'AB', false, 'Brasília', 'sara49@x.com');
  assert pg_temp.ordem(v_combo, '{"email":"49@x.com"}', '{"idade_min":30,"escolaridade_min":"superior"}', 'brasi')
    = array['Sel49 RCombina'], 'todos os filtros juntos: só quem atende a todos';

  -- ── permissões: como as outras funções do painel (usuário logado executa; anônimo não) ──
  assert has_function_privilege('authenticated', 'public.fn_bate_colunas_avancadas(uuid, jsonb)', 'execute'), 'usuário logado executa';
  assert not has_function_privilege('anon', 'public.fn_bate_colunas_avancadas(uuid, jsonb)', 'execute'), 'anônimo não executa';
  assert has_function_privilege('authenticated', 'public.fn_bate_filtros_avancados(uuid, jsonb)', 'execute'), 'usuário logado executa';
  assert not has_function_privilege('anon', 'public.fn_bate_filtros_avancados(uuid, jsonb)', 'execute'), 'anônimo não executa';
  assert has_function_privilege('authenticated',
    'public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text, jsonb, jsonb, text)', 'execute'), 'usuário logado executa';
  assert not has_function_privilege('anon',
    'public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text, jsonb, jsonb, text)', 'execute'), 'anônimo não executa';

  raise notice 'TESTE DA SELEÇÃO COM OS FILTROS DO BANCO DE TALENTOS (049): tudo certo';
end $$;

rollback;
