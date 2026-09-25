-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · SELEÇÃO DE CVs: distância em relação às lojas que o RH escolher
--
--  Rodar depois da 037. Pode rodar de novo sem problema.
--
--  Até aqui a distância da seleção (Vagas → "Selecionar CVs") era sempre até a loja mais próxima entre as lojas da PRÓPRIA
--  vaga. Agora o RH escolhe em relação a quais lojas quer medir (uma, várias ou todas), sem depender das lojas cadastradas
--  na vaga. Vale para o limite de km, para a ordem "mais perto da loja" e para o "X km da CFC" do card.
--
--    • selecionar_curriculos_vaga(..., p_lojas text[])  — siglas das lojas de referência (nulo ou vazio = as lojas da vaga,
--      como era antes)
--    • fn_lojas_referencia()                            — resolve p_lojas para os pontos (latitude/longitude) das lojas
-- ════════════════════════════════════════════════════════════════════════

-- As lojas de referência da distância: as escolhidas pelo RH (maiúsculas ou minúsculas tanto faz; sigla que não existe,
-- loja inativa e loja sem local cadastrado ficam de fora, como já acontecia com as lojas da vaga) ou, sem escolha, as da vaga.
create or replace function public.fn_lojas_referencia(p_vaga_id uuid, p_lojas text[] default null)
returns table (sigla text, nome text, regiao text, lat numeric, lon numeric)
language sql stable
set search_path = public
as $$
  select l.sigla, l.nome, l.regiao, l.lat, l.lon
    from public.fn_lojas_da_vaga(p_vaga_id) l
   where coalesce(cardinality(p_lojas), 0) = 0
  union all
  select e.sigla, e.nome, r.nome, coalesce(e.latitude, r.latitude), coalesce(e.longitude, r.longitude)
    from public.empresas e
    left join public.regioes_df r on r.id = e.regiao_id
   where coalesce(cardinality(p_lojas), 0) > 0
     and e.ativo
     and coalesce(e.latitude, r.latitude) is not null
     and upper(e.sigla) in (select upper(btrim(s)) from unnest(p_lojas) s)
$$;

-- A seleção da 033 com uma entrada a mais no fim (a assinatura antiga sai: duas versões da função confundiriam o painel)
--     p_lojas: siglas das lojas contra as quais medir a distância; nulo ou vazio = as lojas da vaga
drop function if exists public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric);
create or replace function public.selecionar_curriculos_vaga(
  p_vaga_id uuid, p_limite integer default 50, p_deslocamento integer default 0,
  p_ordem text default 'nota', p_km_max numeric default null, p_lojas text[] default null)
returns table (candidato_id uuid, nota integer, total integer, km_mais_proxima numeric, loja_mais_proxima text)
language sql stable
set search_path = public
as $$
  with lojas as (select * from public.fn_lojas_referencia(p_vaga_id, p_lojas)),
  base as (
    select f.candidato_id, f.nota, f.ultima_movimentacao, rc.latitude as lat, rc.longitude as lon
      from public.fn_curriculos_da_vaga(p_vaga_id) f
      join public.candidatos c on c.id = f.candidato_id
      left join public.regioes_df rc on rc.id = c.regiao_id
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

-- ───────────────────────────────────────────────────────────────────────
--  Privilégios (o painel chama a seleção; ela chama fn_lojas_referencia com a sessão dele, por isso também precisa de EXECUTE)
-- ───────────────────────────────────────────────────────────────────────
revoke execute on function
  public.fn_lojas_referencia(uuid, text[]),
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[])
from public, anon, authenticated;
grant execute on function
  public.fn_lojas_referencia(uuid, text[]),
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[])
to authenticated, service_role;
