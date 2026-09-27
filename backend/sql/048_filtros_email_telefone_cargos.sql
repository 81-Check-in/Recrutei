-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos: três filtros novos em "Mais filtros" (048)
--
--  Vão para filtrar_banco_talentos() (a função dos filtros de TEXTO; a 024 a criou). O resto da função é o da 024, sem mudança.
--
--    email               "maria", "gmail.com", "maria@gmail.com"  — pedaço do e-mail, sem diferenciar maiúsculas de minúsculas.
--                        Procura no e-mail do cadastro (candidatos.email, o que está no currículo) E no endereço de quem
--                        ENVIOU o currículo (curriculos.email_envio) — de qualquer um dos currículos do candidato, não só do atual:
--                        quem reenviou de outro endereço é achado pelos dois.
--    telefone            "(61) 99999-1234", "999991234", "1234"    — só os números contam (parênteses, espaços e hífen são
--                        ignorados); pedaço do número serve (o final, o DDD…). Procura no telefone digitado e no normalizado
--                        (com DDI), então dá igual escrever com ou sem o 55.
--    cargos_experiencia  ["repositor", "operador de caixa"]        — cargos em que a pessoa TEM experiência; aparece quem tiver
--                        QUALQUER um deles. Sem diferenciar maiúsculas nem acentos, e pedaço da palavra serve (repositor acha
--                        repositora). Procura no currículo a partir do título de experiência ("Experiência profissional",
--                        "Histórico profissional", "Experiências de trabalho"…): o que vem ANTES dele (objetivo, resumo, dados
--                        pessoais) não conta — quem só QUER ser repositor não entra. Currículo sem esse título é procurado inteiro.
--                        O recorte é feito por trecho_de_experiencia() (busca de posição, rápida em volume).
--
--  Sem mudança de tabela nem de índice: com o volume atual (milhares de candidatos) a busca é instantânea; o de 50 mil
--  currículos já é ensaiado em 20_teste_desempenho.sql.
--
--  Pode rodar de novo sem problema.
-- ════════════════════════════════════════════════════════════════════════

-- Recorte do currículo (já normalizado por norm_busca) a partir do PRIMEIRO título de experiência que aparecer; sem título, o
-- texto todo. É busca de posição, não expressão regular: uma regex com "^.*?" custava ~1 ms por currículo (48 s com 50 mil).
create or replace function public.trecho_de_experiencia(p_cv text)
returns text
language sql immutable parallel safe
set search_path to ''
as $$
  select case when p.ini is null then p_cv else substr(p_cv, p.ini) end
    from (select least(
            nullif(position('experiencia profissional'  in p_cv), 0),
            nullif(position('experiencias profissionais' in p_cv), 0),
            nullif(position('experiencia de trabalho'   in p_cv), 0),
            nullif(position('experiencias de trabalho'  in p_cv), 0),
            nullif(position('experiencia anterior'      in p_cv), 0),
            nullif(position('experiencias anteriores'   in p_cv), 0),
            nullif(position('historico profissional'    in p_cv), 0),
            nullif(position('historico de trabalho'     in p_cv), 0),
            nullif(position('trajetoria profissional'   in p_cv), 0),
            nullif(position('atividades profissionais'  in p_cv), 0),
            nullif(position('vida profissional'         in p_cv), 0),
            nullif(position('empregos anteriores'       in p_cv), 0)) as ini) p
$$;
revoke all on function public.trecho_de_experiencia(text) from public, anon;
grant execute on function public.trecho_de_experiencia(text) to authenticated, service_role;

create or replace function public.filtrar_banco_talentos(filtros jsonb default '{}'::jsonb)
returns setof public.vw_banco_talentos
language sql stable
set search_path = public
as $$
  with f as (
    select
      array(select public.norm_busca(x)
              from jsonb_array_elements_text(coalesce(filtros -> 'palavras', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as palavras,
      coalesce(filtros ->> 'palavras_modo', 'todas')                 as modo,
      coalesce(filtros ->> 'palavras_onde', 'curriculo')             as onde,
      nullif(btrim(public.norm_busca(filtros ->> 'local')), '')      as local,
      array(select public.norm_busca(x)
              from jsonb_array_elements_text(coalesce(filtros -> 'excluir_locais', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as excluir,
      filtros ->> 'rotatividade'                                     as rot,
      -- 048: e-mail (pedaço), telefone (só os números) e cargos com experiência (qualquer um)
      nullif(btrim(public.norm_busca(filtros ->> 'email')), '')      as email,
      nullif(regexp_replace(coalesce(filtros ->> 'telefone', ''), '\D', '', 'g'), '') as fone,
      array(select btrim(public.norm_busca(x))
              from jsonb_array_elements_text(coalesce(filtros -> 'cargos_experiencia', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as cargos
  )
  select v.*
  from f
  cross join public.vw_banco_talentos v
  left join lateral (
    select cu.texto_extraido from public.curriculos cu
     where cu.candidato_id = v.id and cu.atual limit 1
  ) cu on true
  cross join lateral (
    select
      public.norm_busca(cu.texto_extraido)                                        as cv,
      public.norm_busca(concat_ws(' ', v.resumo_ia,
             array_to_string(v.pontos_positivos, ' '),
             array_to_string(v.pontos_negativos, ' ')))                           as analise,
      public.norm_busca(concat_ws(' ', v.cidade, v.uf, left(cu.texto_extraido, 1500))) as local_txt
  ) t
  cross join lateral (
    select case f.onde when 'analise' then t.analise
                       when 'ambos'   then t.cv || ' ' || t.analise
                       else t.cv end                                              as alvo
  ) a
  where
    (cardinality(f.palavras) = 0
     or case f.modo
          when 'qualquer' then exists (select 1 from unnest(f.palavras) p where position(p in a.alvo) > 0)
          else not exists (select 1 from unnest(f.palavras) p where position(p in a.alvo) = 0)
        end)
    and (f.local is null or position(f.local in t.local_txt) > 0)
    and not exists (select 1 from unnest(f.excluir) e where position(e in t.local_txt) > 0)
    and (f.rot is null
         or (f.rot = 'alta'     and exists (select 1 from unnest(v.pontos_negativos) x where x like 'Alta rotatividade%'))
         or (f.rot = 'baixa'    and exists (select 1 from unnest(v.pontos_positivos) x where x like 'Baixa rotatividade%'))
         or (f.rot = 'sem_alta' and not exists (select 1 from unnest(v.pontos_negativos) x where x like 'Alta rotatividade%')))
    -- e-mail: o do cadastro (o que está no currículo) OU o de quem enviou, de qualquer currículo do candidato
    and (f.email is null
         or position(f.email in public.norm_busca(v.email)) > 0
         or exists (select 1 from public.curriculos ce
                     where ce.candidato_id = v.id and position(f.email in public.norm_busca(ce.email_envio)) > 0))
    -- telefone: só os números; no telefone como veio e no normalizado (com DDI)
    and (f.fone is null
         or position(f.fone in regexp_replace(coalesce(v.telefone_e164, ''), '\D', '', 'g')) > 0
         or position(f.fone in regexp_replace(coalesce(v.telefone, ''), '\D', '', 'g')) > 0)
    -- cargos com experiência: qualquer um deles, do título de experiência em diante (sem título: o currículo todo).
    -- O texto do currículo é normalizado UMA vez por candidato ("offset 0" impede o planner de repetir a expressão em cada uso)
    -- e só quando há cargo digitado. O CASE garante a ordem: primeiro a checagem barata (o cargo aparece em algum lugar do
    -- currículo?) e só então o recorte.
    and (cardinality(f.cargos) = 0
         or exists (select 1
                      from (select public.norm_busca(cu.texto_extraido) as cv offset 0) x
                     cross join unnest(f.cargos) c
                     where case when position(c in x.cv) = 0 then false
                                else position(c in public.trecho_de_experiencia(x.cv)) > 0 end))
$$;

revoke all on function public.filtrar_banco_talentos(jsonb) from public, anon;
grant execute on function public.filtrar_banco_talentos(jsonb) to authenticated, service_role;
