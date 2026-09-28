-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — "Selecionar CVs" ganha os mesmos filtros do Banco de Talentos
--
--  Até aqui, a tela de seleção (Vagas → "Selecionar CVs") só filtrava por sexo e por distância: o resto do painel
--  "Mais filtros" (palavras-chave, endereço, e-mail, telefone, cargos com experiência, idade, escolaridade,
--  experiência, revisão manual, rotatividade e cidade) só existia no Banco de Talentos "normal". Esta migração
--  estende selecionar_curriculos_vaga() para aceitar os mesmos filtros, com o MESMO significado.
--
--  Como: os filtros de TEXTO (palavras/local/excluir_locais/rotatividade/email/telefone/cargos_experiencia) já
--  tinham a lógica pronta dentro de filtrar_banco_talentos(); ela sai de lá para uma função própria,
--  fn_bate_filtros_avancados(candidato, filtros), que passa a ser usada nos dois lugares (filtrar_banco_talentos
--  continua se comportando exatamente igual — é só a mesma conta, sem repetir o texto da função duas vezes).
--  Palavras-chave sempre casa "qualquer uma delas" (não há mais escolha de "todas") e busca sempre no currículo
--  E na análise da IA juntos (não há mais escolha de "onde") — sem seletor na tela, sempre o resultado mais
--  abrangente; um termo só (sem vírgula) continua funcionando como busca de frase, em sequência.
--  Os filtros de COLUNA (idade/escolaridade/experiência/revisão) o Banco de Talentos aplica no PostgREST
--  (.gte/.or encadeado na consulta, em banco-talentos.js); a seleção não tem essa consulta para encadear em cima,
--  então ganham a função nova fn_bate_colunas_avancadas(candidato, colunas), com a MESMA regra de cada campo
--  (git blame de aplicarColunasAvancadas() no painel, se um dia divergir, é ali que está o padrão).
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  1) Filtros de texto: extraídos de filtrar_banco_talentos(), palavra por palavra — o comportamento dela não muda
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_bate_filtros_avancados(p_candidato_id uuid, filtros jsonb default '{}'::jsonb)
returns boolean
language sql stable
set search_path to 'public'
as $$
  with f as (
    select
      array(select public.norm_busca(x)
              from jsonb_array_elements_text(coalesce(filtros -> 'palavras', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as palavras,
      nullif(btrim(public.norm_busca(filtros ->> 'local')), '')      as local,
      array(select public.norm_busca(x)
              from jsonb_array_elements_text(coalesce(filtros -> 'excluir_locais', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as excluir,
      filtros ->> 'rotatividade'                                     as rot,
      nullif(btrim(public.norm_busca(filtros ->> 'email')), '')      as email,
      nullif(regexp_replace(coalesce(filtros ->> 'telefone', ''), '\D', '', 'g'), '') as fone,
      array(select btrim(public.norm_busca(x))
              from jsonb_array_elements_text(coalesce(filtros -> 'cargos_experiencia', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as cargos
  ),
  v as (select * from public.vw_banco_talentos where id = p_candidato_id),
  cu as (select texto_extraido from public.curriculos where candidato_id = p_candidato_id and atual limit 1),
  t as (
    select
      public.norm_busca(cu.texto_extraido)                                        as cv,
      public.norm_busca(concat_ws(' ', v.resumo_ia,
             array_to_string(v.pontos_positivos, ' '),
             array_to_string(v.pontos_negativos, ' ')))                           as analise,
      public.norm_busca(concat_ws(' ', v.cidade, v.uf, left(cu.texto_extraido, 1500))) as local_txt
    from v, cu
  ),
  -- palavras-chave: sempre "qualquer uma delas" (não "todas"), sempre no currículo E na análise da IA juntos —
  -- sem escolha na tela, é o resultado mais abrangente (um só termo continua funcionando como busca de frase)
  a as (
    select t.cv || ' ' || t.analise as alvo
    from t
  )
  select
    (cardinality(f.palavras) = 0
     or exists (select 1 from unnest(f.palavras) p where position(p in a.alvo) > 0))
    and (f.local is null or position(f.local in t.local_txt) > 0)
    and not exists (select 1 from unnest(f.excluir) e where position(e in t.local_txt) > 0)
    and (f.rot is null
         or (f.rot = 'alta'     and exists (select 1 from unnest(v.pontos_negativos) x where x like 'Alta rotatividade%'))
         or (f.rot = 'baixa'    and exists (select 1 from unnest(v.pontos_positivos) x where x like 'Baixa rotatividade%'))
         or (f.rot = 'sem_alta' and not exists (select 1 from unnest(v.pontos_negativos) x where x like 'Alta rotatividade%')))
    and (f.email is null
         or position(f.email in public.norm_busca(v.email)) > 0
         or exists (select 1 from public.curriculos ce
                     where ce.candidato_id = v.id and position(f.email in public.norm_busca(ce.email_envio)) > 0))
    and (f.fone is null
         or position(f.fone in regexp_replace(coalesce(v.telefone_e164, ''), '\D', '', 'g')) > 0
         or position(f.fone in regexp_replace(coalesce(v.telefone, ''), '\D', '', 'g')) > 0)
    and (cardinality(f.cargos) = 0
         or exists (select 1 from unnest(f.cargos) c
                     where case when position(c in t.cv) = 0 then false
                                else position(c in public.trecho_de_experiencia(t.cv)) > 0 end))
  from f, v, t, a
$$;

-- filtrar_banco_talentos passa a chamar a função extraída acima; o resultado é idêntico a antes
create or replace function public.filtrar_banco_talentos(filtros jsonb default '{}'::jsonb)
returns setof vw_banco_talentos
language sql stable
set search_path = public
as $$
  select v.* from public.vw_banco_talentos v
  where public.fn_bate_filtros_avancados(v.id, filtros)
$$;

-- ───────────────────────────────────────────────────────────────────────
--  2) Filtros de coluna: mesma regra de aplicarColunasAvancadas() (banco-talentos.js), em SQL
--     colunas: {idade_min, idade_max, escolaridade_min, experiencia_min, revisao, incluir_sem_info}
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_bate_colunas_avancadas(p_candidato_id uuid, colunas jsonb default '{}'::jsonb)
returns boolean
language sql stable
set search_path to 'public'
as $$
  with c as (
    select coalesce((colunas ->> 'incluir_sem_info')::boolean, true)      as sem,
           nullif(colunas ->> 'idade_min', '')::int                       as idade_min,
           nullif(colunas ->> 'idade_max', '')::int                       as idade_max,
           nullif(colunas ->> 'escolaridade_min', '')                     as escolaridade_min,
           nullif(colunas ->> 'experiencia_min', '')::numeric             as experiencia_min,
           coalesce((colunas ->> 'revisao')::boolean, false)              as revisao
  ),
  k as (select * from public.candidatos where id = p_candidato_id)
  select
    -- idade: as duas pontas (quando informadas) valem juntas; "incluir sem info" deixa passar nascimento_ref nulo.
    -- Todo o "ou" fica entre parênteses: sem isso, o "e" dos filtros seguintes (precedência maior que "ou" em SQL)
    -- grudaria só no último ramo, e qualquer chamada sem filtro de idade (o caso comum) deixaria passar todo mundo,
    -- ignorando escolaridade/experiência/CNH/revisão.
    (
      (c.idade_min is null and c.idade_max is null)
      or (c.sem and k.nascimento_ref is null)
      or (
        (c.idade_min is null or k.nascimento_ref <= current_date - (c.idade_min::text || ' years')::interval)
        and
        (c.idade_max is null or k.nascimento_ref >= current_date - ((c.idade_max + 1)::text || ' years')::interval + interval '1 day')
      )
    )
  and (
    c.escolaridade_min is null
    or (c.sem and k.escolaridade_ord is null)
    or k.escolaridade_ord >= case c.escolaridade_min
         when 'fundamental' then 1 when 'medio' then 2 when 'tecnico' then 3 when 'superior' then 4 when 'pos' then 5 else 0 end
  )
  and (
    c.experiencia_min is null
    or (c.sem and k.anos_experiencia is null)
    or k.anos_experiencia >= c.experiencia_min
  )
  and (not c.revisao or k.revisao_manual)
  from c, k
$$;

-- ───────────────────────────────────────────────────────────────────────
--  3) selecionar_curriculos_vaga: os três parâmetros novos (com p_filtros/p_colunas em '{}' e p_cidade nulo, o
--     comportamento é exatamente o de antes desta migração)
-- ───────────────────────────────────────────────────────────────────────
drop function if exists public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text);
create or replace function public.selecionar_curriculos_vaga(
  p_vaga_id uuid, p_limite integer default 50, p_deslocamento integer default 0,
  p_ordem text default 'nota', p_km_max numeric default null, p_lojas text[] default null, p_sexo text default null,
  p_filtros jsonb default '{}'::jsonb, p_colunas jsonb default '{}'::jsonb, p_cidade text default null)
returns table(candidato_id uuid, nota integer, total integer, km_mais_proxima numeric, loja_mais_proxima text)
language sql stable
set search_path to 'public'
as $$
  with lojas as (select * from public.fn_lojas_referencia(p_vaga_id, p_lojas)),
  base as (
    select f.candidato_id, f.nota, f.ultima_movimentacao, rc.latitude as lat, rc.longitude as lon
      from public.fn_curriculos_da_vaga(p_vaga_id) f
      join public.candidatos c on c.id = f.candidato_id
      left join public.regioes_df rc on rc.id = c.regiao_id
     where (coalesce(p_sexo, '') = ''
            or (p_sexo = 'nao_informado' and c.sexo is null)
            or c.sexo = p_sexo)
       and (p_cidade is null or c.cidade_norm like p_cidade || '%')
       and public.fn_bate_colunas_avancadas(f.candidato_id, p_colunas)
       and public.fn_bate_filtros_avancados(f.candidato_id, p_filtros)
  ),
  perto as (
    select b.*, d.km, d.sigla
      from base b
      left join lateral (
        select min(public.distancia_km(b.lat, b.lon, l.lat, l.lon)) as km,
               (array_agg(l.sigla order by public.distancia_km(b.lat, b.lon, l.lat, l.lon), l.sigla))[1] as sigla
          from lojas l where b.lat is not null
      ) d on true
     where p_km_max is null or d.km <= p_km_max
  )
  select x.candidato_id, x.nota::integer, (count(*) over ())::integer, x.km, x.sigla
    from perto x
   order by case when p_ordem = 'distancia' then x.km end asc nulls last,
            x.nota desc nulls last, x.ultima_movimentacao asc, x.candidato_id
   limit greatest(p_limite, 1) offset greatest(p_deslocamento, 0)
$$;

revoke execute on function public.fn_bate_filtros_avancados(uuid, jsonb) from public, anon;
revoke execute on function public.fn_bate_colunas_avancadas(uuid, jsonb) from public, anon;
grant execute on function public.fn_bate_filtros_avancados(uuid, jsonb) to authenticated, service_role;
grant execute on function public.fn_bate_colunas_avancadas(uuid, jsonb) to authenticated, service_role;

revoke execute on function
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text, jsonb, jsonb, text)
from public, anon, authenticated;
grant execute on function
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text, jsonb, jsonb, text)
to authenticated, service_role;
