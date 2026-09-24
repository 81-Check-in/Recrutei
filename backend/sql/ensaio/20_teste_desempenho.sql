-- Desempenho da busca do Banco de Talentos com 50 mil candidatos SINTÉTICOS (roda depois de 020–025).
-- Confere que o planner usa os índices de 021 nas buscas típicas da tela e mede o tempo de cada uma.
-- Não altera nada que importe: rode num banco de ensaio (o ensaio.sh usa uma cópia).
\set ON_ERROR_STOP on
\timing off
\if :{?linhas} \else \set linhas 50000 \endif   -- para testar em escala maior: psql -v linhas=500000 ...
-- SSD, como no Supabase (o padrão do Postgres, 4.0, foi feito para disco giratório e favorece varredura sequencial)
set random_page_cost = 1.1;

-- ── carga: distribuição parecida com a real (nomes brasileiros, cidades do DF/GO, 8 áreas) ──
insert into candidatos
  (nome, sexo, data_nascimento, idade_informada, idade_informada_em, cidade, uf, telefone_e164, email,
   escolaridade, anos_experiencia, status_banco, origem_entrada, data_entrada, ultima_atualizacao, ultima_movimentacao,
   area_sugerida, cargo_sugerido, nivel_sugerido, ia_confianca, revisao_manual)
select
  (array['Maria','João','Ana','José','Antônio','Francisca','Carlos','Paulo','Pedro','Lucas','Juliana','Fernanda','Marcos','Rafael','Camila',
         'Gabriel','Aline','Bruno','Patrícia','Wanderley','Thiago','Larissa','Ricardo','Vanessa','Eduardo'])[1 + (g * 7) % 25] || ' ' ||
  (array['Silva','Santos','Oliveira','Souza','Pereira','Lima','Costa','Ribeiro','Almeida','Nascimento','Ferreira','Rodrigues','Carvalho',
         'Gomes','Martins','Araújo','Barbosa','Rocha','Dias','Monteiro'])[1 + (g * 13) % 20] || ' ' || g,
  case g % 10 when 0 then null when 1 then null when 2 then 'masculino' when 3 then 'feminino' when 4 then 'masculino'
              when 5 then 'feminino' when 6 then 'masculino' when 7 then 'feminino' when 8 then 'masculino' else 'feminino' end,
  case when g % 5 <= 1 then current_date - (18 * 365 + (g * 37) % (42 * 365)) end,           -- 40%: data exata (18–60 anos)
  case when g % 5 > 1 then 18 + (g * 11) % 42 end,                                            -- 60%: só a idade
  case when g % 5 > 1 then current_date end,
  (array['Taguatinga','Ceilândia','Samambaia','Brasília','Gama','Planaltina','Sobradinho','Águas Lindas de Goiás','Valparaíso de Goiás',
         'Santa Maria','Recanto das Emas','Guará','Sobradinho II','Novo Gama','Luziânia'])[1 + (g * 17) % 15],
  case when (g * 17) % 15 in (7, 8, 13, 14) then 'GO' else 'DF' end,
  '5561' || (900000000 + g)::text, 'cand' || g || '@mail.test',
  (array['fundamental','medio','tecnico','superior','pos'])[1 + (g * 3) % 5], (g % 20) + 0.5,
  case when g % 20 = 0 then 'inativo'::status_banco_talentos else 'ativo'::status_banco_talentos end, 'email',
  now() - ((g * 53) % 1000 || ' days')::interval, now() - ((g * 53) % 1000 || ' days')::interval,
  now() - ((g * 29) % 900 || ' days')::interval,
  (array['Logística','Vendas','Financeiro','Administrativo','Recursos Humanos','Tecnologia','Produção','Atendimento'])[1 + (g * 5) % 8],
  (array['Auxiliar','Assistente','Analista','Conferente','Operador','Vendedor'])[1 + (g * 7) % 6],
  (array['jovem_aprendiz','trainee','junior','pleno','senior'])[1 + (g * 3) % 5],
  30 + (g * 13) % 70, g % 9 = 0
from generate_series(1, :linhas) g;

analyze public.candidatos;
select 'candidatos no banco: ' || count(*) from public.candidatos;

create or replace function pg_temp.plano(q text) returns text language plpgsql as $$
declare l text; r text := '';
begin
  for l in execute 'explain (analyze, timing off, costs off, summary on) ' || q loop r := r || l || E'\n'; end loop;
  return r;
end $$;

-- Consultas como o painel as faz (PostgREST sobre a view; ver frontend/js/banco-talentos.js).
-- Duas verificações por consulta:
--   1. o índice é UTILIZÁVEL: com a varredura sequencial proibida, o plano usa um índice idx_candidatos_*
--      (prova que o tipo de índice e a operadora servem para aquele filtro — ex.: LIKE '%x%' só com trigrama)
--   2. o tempo com o plano que o planner escolhe sozinho cabe no orçamento (250 ms)
do $teste$
declare
  q record; plano text; ms numeric; ms_forcado numeric; usado text;
  orcamento_ms constant numeric := 250;
begin
  for q in select * from (values
    ('nome parcial (termo raro)',     $$select * from vw_banco_talentos where nome_norm like '%wanderley%' and nome_norm like '%rocha 1%' order by data_entrada desc limit 50$$),
    ('nome parcial (termo comum)',    $$select * from vw_banco_talentos where nome_norm like '%maria%' order by data_entrada desc limit 50$$),
    ('cidade (prefixo) + área',       $$select * from vw_banco_talentos where cidade_norm like 'taguat%' and area_sugerida = 'Logística' order by data_entrada desc limit 50$$),
    ('cidade + UF',                   $$select * from vw_banco_talentos where cidade_norm like 'valpara%' and uf = 'GO' limit 50$$),
    ('faixa etária estreita + área',  $$select * from vw_banco_talentos where nascimento_ref between current_date - interval '29 years' and current_date - interval '28 years' and area_sugerida = 'Vendas' limit 50$$),
    ('status + área + nível',         $$select * from vw_banco_talentos where status_banco = 'ativo' and area_sugerida = 'Logística' and nivel_sugerido = 'pleno' order by data_entrada desc limit 50$$),
    ('cargo + status',                $$select * from vw_banco_talentos where cargo_sugerido = 'Conferente' and status_banco = 'ativo' limit 50$$),
    ('sexo + cidade + área',          $$select * from vw_banco_talentos where sexo = 'feminino' and cidade_norm like 'ceil%' and area_sugerida = 'Financeiro' limit 50$$),
    ('revisão manual (fila)',         $$select * from vw_banco_talentos where revisao_manual and status_banco = 'ativo' order by data_entrada limit 50$$),
    ('contagem da lista (paginação)', $$select count(*) from vw_banco_talentos where status_banco = 'ativo' and area_sugerida = 'Logística'$$)
  ) as t(nome, consulta)
  loop
    plano := pg_temp.plano(q.consulta);
    ms := substring(plano from 'Execution Time: ([0-9.]+) ms')::numeric;

    set local enable_seqscan = off;
    plano := pg_temp.plano(q.consulta);
    reset enable_seqscan;
    ms_forcado := substring(plano from 'Execution Time: ([0-9.]+) ms')::numeric;
    usado := (regexp_match(plano, '(idx_candidatos_[a-z_]+)'))[1];

    raise notice '% | %ms (planner) | %ms (com índice: %)', rpad(q.nome, 32), lpad(ms::text, 8), lpad(ms_forcado::text, 8), coalesce(usado, 'NENHUM');
    if usado is null then
      raise exception 'A consulta "%" não consegue usar nenhum índice idx_candidatos_*:%', q.nome, E'\n' || plano;
    end if;
    if ms > orcamento_ms then
      raise exception 'A consulta "%" levou % ms (orçamento: % ms) com % candidatos', q.nome, ms, orcamento_ms, (select count(*) from candidatos);
    end if;
  end loop;
end $teste$;

-- Sanitização em volume: a lista completa de sugestões para 50 mil candidatos
do $$
declare t0 timestamptz := clock_timestamp(); n int;
begin
  select count(*) into n from public.fn_sanitizacao_avaliar(public.fn_sanitizacao_parametros());
  raise notice '% ms  sanitização (cálculo das sugestões): % candidatos sugeridos',
    lpad((extract(epoch from clock_timestamp() - t0) * 1000)::int::text, 9), n;
end $$;

-- ── Ranking de candidatos por vaga (Etapa 2) em volume ──
-- Cada um dos 50 mil ganha uma análise com 8 palavras-chave de um vocabulário de 40 termos (o gatilho monta o texto de busca).
do $$
declare
  vocab constant text[] := array['excel','contabilidade','conciliação bancária','conferente','empilhadeira','vendas','atendimento ao cliente','caixa',
    'estoque','expedição','recebimento','sap','office','word','cnh b','motorista','auxiliar administrativo','faturamento','contas a pagar',
    'contas a receber','fiscal','folha de pagamento','recrutamento','tecnologia','suporte técnico','redes','python','sql','marketing','logística',
    'picking','separação','inventário','loja','varejo','atacado','supervisão','liderança','negociação','compras'];
  t0 timestamptz := clock_timestamp();
begin
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
  select c.id, 1, c.area_sugerida, c.cargo_sugerido, c.nivel_sugerido, c.ia_confianca, 'carga',
         array(select vocab[1 + (c.g * m) % 40] from unnest(array[3, 7, 11, 13, 17, 19, 23, 29]) m)
    from (select id, area_sugerida, cargo_sugerido, nivel_sugerido, ia_confianca, row_number() over () as g
            from candidatos where analise_atual_id is null) c;
  raise notice '% ms  carga das análises com palavras-chave (%)', lpad((extract(epoch from clock_timestamp() - t0) * 1000)::int::text, 9),
    (select count(*) from analises_ia);
end $$;
analyze public.analises_ia;
analyze public.candidatos;

do $teste$
declare
  vaga uuid; plano text; ms numeric; n int; primeiro int; ultimo int; setor uuid;
  orcamento_ms constant numeric := 1000;
begin
  select id into setor from setores order by nome limit 1;
  insert into vagas (setor_id, titulo, descricao, quantidade)
    values (setor, 'Auxiliar Contábil e Fiscal', 'Rotinas contábeis e fiscais, conciliações e faturamento', 1) returning id into vaga;
  insert into requisitos (vaga_id, descricao, tipo, peso, ordem) values
    (vaga, 'Domínio de Excel', 'desejavel', 2, 1), (vaga, 'Conciliação bancária', 'obrigatorio', 2, 2),
    (vaga, 'Contas a pagar e a receber', 'desejavel', 2, 3), (vaga, 'Conhecimento fiscal', 'desejavel', 1, 4),
    (vaga, 'Faturamento', 'diferencial', 1, 5), (vaga, 'Cursando Ciências Contábeis', 'obrigatorio', 2, 6);

  -- a mesma consulta que o painel faz: 1ª página do ranking
  plano := pg_temp.plano(format('select * from ranking_candidatos_vaga(%L, 50, 0)', vaga));
  ms := substring(plano from 'Execution Time: ([0-9.]+) ms')::numeric;
  select count(*), max(aderencia), min(aderencia) into n, primeiro, ultimo from ranking_candidatos_vaga(vaga, 50, 0);
  raise notice 'ranking por vaga (1ª página)         | %ms | % linhas, aderência %% de % a % | total combinando: %', lpad(ms::text, 8), n, primeiro, ultimo,
    (select total from ranking_candidatos_vaga(vaga, 1, 0));
  if n <> 50 then raise exception 'esperava 50 linhas na 1ª página do ranking, vieram %', n; end if;
  if primeiro < ultimo then raise exception 'a página do ranking não está em ordem decrescente de aderência'; end if;
  -- O índice GIN do texto de busca é UTILIZÁVEL. (A função tem SET search_path, então o EXPLAIN dela mostra só "Function
  -- Scan": a checagem é na consulta equivalente. Olhado por dentro com auto_explain, numa vaga seletiva o plano usa
  -- "Bitmap Index Scan on idx_analises_busca_tsv". Com este vocabulário de 40 termos a consulta casa com 75% da base e
  -- o planner, corretamente, prefere varrer.)
  set local enable_seqscan = off;
  plano := pg_temp.plano($q$select 1 from analises_ia where busca_tsv @@ to_tsquery('simple', '''excel'' | ''contab''')$q$);
  reset enable_seqscan;
  if plano !~ 'idx_analises_busca_tsv' then
    raise exception E'o índice GIN do texto de busca não serve para a consulta do ranking:\n%', plano;
  end if;
  if ms > orcamento_ms then
    raise exception 'O ranking levou % ms (orçamento: % ms) com % candidatos', ms, orcamento_ms, (select count(*) from candidatos);
  end if;
end $teste$;
