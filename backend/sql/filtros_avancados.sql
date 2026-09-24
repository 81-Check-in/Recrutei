-- ════════════════════════════════════════════════════════════════════════
--  ⚠ OBSOLETO desde o Banco de Talentos (backend/sql/020 a 025) — NÃO RODE ESTE ARQUIVO.
--
--  A Triagem virou o Banco de Talentos: vw_triagem e filtrar_triagem (abaixo) foram removidas na 024, e
--  os mesmos filtros (palavras-chave, local, rotatividade + idade, escolaridade, experiência, CNH) passaram a
--  ser feitos por filtrar_banco_talentos() e por colunas indexadas de "candidatos". Rodar este arquivo agora
--  falha (vw_triagem não existe mais). norm_busca() continua existindo — a 021 a recria.
--  Mantido só como histórico do que rodava até a versão 1.8.1.
-- ════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Filtros avançados da Triagem
--
--  Rode UMA vez: Supabase → SQL Editor → New query → cole este arquivo → Run.
--  Pode rodar de novo sem problema (create or replace). Não altera tabelas,
--  colunas nem dados: só cria duas funções.
--
--  Sem isto a Triagem continua funcionando; só os filtros de palavras-chave,
--  localização, idade, escolaridade, experiência, CNH e rotatividade avisam
--  que precisam desta atualização.
-- ════════════════════════════════════════════════════════════════════════

-- Texto em minúsculas e sem acento: buscar "brasilia" acha "Brasília".
create or replace function public.norm_busca(t text)
returns text
language sql immutable parallel safe
as $$
  select translate(lower(coalesce(t, '')),
                   'áàâãäéèêëíìîïóòôõöúùûüçñ',
                   'aaaaaeeeeiiiiooooouuuucn')
$$;


-- Devolve as linhas de vw_triagem (as mesmas que a tela lista) que atendem aos filtros
-- que a view não consegue expressar. O painel aplica por cima os filtros comuns
-- (vaga, status, nota, datas...) e a ordenação, como faz na view.
--
-- filtros (jsonb, todos opcionais):
--   palavras          ["empilhadeira", "cnh b"]   termos (frase inteira conta como um termo)
--   palavras_modo     "todas" | "qualquer"        padrão: todas
--   palavras_onde     "curriculo" | "analise" | "ambos"   padrão: curriculo
--   local             "samambaia"                 cidade/bairro/endereço
--   excluir_locais    ["planaltina", "itapoa"]    remove quem mora nesses lugares
--   idade_min, idade_max                          em anos
--   escolaridade_min  "medio" | "tecnico" | "superior" | "pos" | ...
--   experiencia_min   2                           anos
--   cnh               true                        só quem informa CNH
--   rotatividade      "alta" | "baixa" | "sem_alta"
--   incluir_sem_info  true|false                  mantém quem não informa idade/escolaridade/
--                                                 experiência (padrão: true)
--
-- Localização: procura na cidade extraída e no início do currículo (1.500 caracteres, onde
-- fica o endereço), para uma experiência antiga "em Planaltina" não excluir quem mora em
-- outro lugar.
-- Rotatividade: a IA registra a etiqueta "Alta rotatividade: ..." em lacunas e
-- "Baixa rotatividade: ..." em pontos fortes (backend/ia.py).
create or replace function public.filtrar_triagem(filtros jsonb default '{}'::jsonb)
returns setof public.vw_triagem
language sql stable
set search_path = public
as $$
  with f as (
    select
      array(select public.norm_busca(x)
              from jsonb_array_elements_text(coalesce(filtros->'palavras', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as palavras,
      coalesce(filtros->>'palavras_modo', 'todas')                   as modo,
      coalesce(filtros->>'palavras_onde', 'curriculo')               as onde,
      nullif(btrim(public.norm_busca(filtros->>'local')), '')        as local,
      array(select public.norm_busca(x)
              from jsonb_array_elements_text(coalesce(filtros->'excluir_locais', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as excluir,
      (filtros->>'idade_min')::int                                   as idade_min,
      (filtros->>'idade_max')::int                                   as idade_max,
      case filtros->>'escolaridade_min'
        when 'nenhuma' then 0 when 'fundamental' then 1 when 'medio' then 2
        when 'tecnico' then 3 when 'superior' then 4 when 'pos' then 5 end as esc_min,
      (filtros->>'experiencia_min')::numeric                         as exp_min,
      coalesce((filtros->>'cnh')::boolean, false)                    as exige_cnh,
      filtros->>'rotatividade'                                       as rot,
      coalesce((filtros->>'incluir_sem_info')::boolean, true)        as sem_info
  )
  select v.*
  from f
  cross join public.vw_triagem v
  join public.candidaturas c on c.id = v.id
  left join lateral (
    select cu.texto_extraido
      from public.curriculos cu
     where cu.candidatura_id = c.id
     limit 1
  ) cu on true
  cross join lateral (
    select
      public.norm_busca(cu.texto_extraido)                           as cv,
      public.norm_busca(concat_ws(' ', v.resumo_ia, v.resumo_nota,
             array_to_string(v.pontos_fortes, ' '),
             array_to_string(v.lacunas, ' '),
             array_to_string(v.requisitos_faltantes, ' ')))          as analise,
      public.norm_busca(concat_ws(' ', c.dados_pessoais->>'cidade',
             c.dados_pessoais->>'uf', left(cu.texto_extraido, 1500))) as local_txt,
      case when c.dados_pessoais->>'idade' ~ '^[0-9]{1,3}$'
           then (c.dados_pessoais->>'idade')::int end                 as idade,
      case c.dados_pessoais->>'escolaridade'
        when 'nenhuma' then 0 when 'fundamental' then 1 when 'medio' then 2
        when 'tecnico' then 3 when 'superior' then 4 when 'pos' then 5 end as esc,
      case when c.dados_pessoais->>'anos_experiencia' ~ '^[0-9]+(\.[0-9]+)?$'
           then (c.dados_pessoais->>'anos_experiencia')::numeric end  as exp
  ) t
  cross join lateral (
    select case f.onde when 'analise' then t.analise
                       when 'ambos'   then t.cv || ' ' || t.analise
                       else t.cv end                                  as alvo
  ) a
  where
    -- palavras-chave
    (cardinality(f.palavras) = 0
     or case f.modo
          when 'qualquer' then exists (select 1 from unnest(f.palavras) p where position(p in a.alvo) > 0)
          else not exists (select 1 from unnest(f.palavras) p where position(p in a.alvo) = 0)
        end)
    -- localização
    and (f.local is null or position(f.local in t.local_txt) > 0)
    and not exists (select 1 from unnest(f.excluir) e where position(e in t.local_txt) > 0)
    -- idade
    and ((f.idade_min is null and f.idade_max is null)
         or (t.idade is null and f.sem_info)
         or (t.idade is not null
             and (f.idade_min is null or t.idade >= f.idade_min)
             and (f.idade_max is null or t.idade <= f.idade_max)))
    -- escolaridade e experiência
    and (f.esc_min is null or (t.esc is null and f.sem_info) or t.esc >= f.esc_min)
    and (f.exp_min is null or (t.exp is null and f.sem_info) or t.exp >= f.exp_min)
    -- CNH
    and (not f.exige_cnh or coalesce(c.dados_pessoais->>'cnh', '') <> '')
    -- rotatividade
    and (f.rot is null
         or (f.rot = 'alta'     and exists (select 1 from unnest(v.lacunas) x where x like 'Alta rotatividade%'))
         or (f.rot = 'baixa'    and exists (select 1 from unnest(v.pontos_fortes) x where x like 'Baixa rotatividade%'))
         or (f.rot = 'sem_alta' and not exists (select 1 from unnest(v.lacunas) x where x like 'Alta rotatividade%')))
$$;

-- Só usuários logados no painel (nunca a chave pública sem login).
revoke all on function public.norm_busca(text)          from public, anon;
revoke all on function public.filtrar_triagem(jsonb)    from public, anon;
grant execute on function public.norm_busca(text)       to authenticated;
grant execute on function public.filtrar_triagem(jsonb) to authenticated;
