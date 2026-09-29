-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — "Cidade onde mora" com várias cidades na Seleção de CVs (062)
--
--  Rodar depois da 061. Pode rodar de novo sem problema.
--
--  Mesma função da 049; a única diferença é p_cidade: aceita várias cidades separadas por "|" (cada uma, um prefixo do
--  nome normalizado; basta bater uma). Com uma só cidade, ou nula, o resultado é o de antes.
-- ════════════════════════════════════════════════════════════════════════

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
       and (p_cidade is null
            or exists (select 1 from unnest(string_to_array(p_cidade, '|')) as t(cidade)
                        where t.cidade <> '' and c.cidade_norm like t.cidade || '%'))
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

revoke execute on function
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text, jsonb, jsonb, text)
from public, anon, authenticated;
grant execute on function
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text, jsonb, jsonb, text)
to authenticated, service_role;
