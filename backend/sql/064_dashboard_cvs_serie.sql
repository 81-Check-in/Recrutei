-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Dashboard: CVs recebidos por dia, semana ou mês (064)
--
--  Rodar depois da 063. Pode rodar de novo sem problema.
--
--  p_agrupar: 'dia' (últimos 14 dias), 'semana' (últimas 12 semanas, começando na segunda) ou 'mes' (últimos 12 meses).
--  Conta currículos (arquivos) recebidos, no horário de Brasília. Períodos sem nenhum currículo aparecem com 0.
--  Vale a permissão de quem consulta (security invoker).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.dashboard_cvs_serie(p_agrupar text default 'dia')
returns table(periodo date, total bigint)
language sql stable security invoker
set search_path to 'public'
as $$
  with cfg as (
    select case p_agrupar when 'semana' then 'week' when 'mes' then 'month' else 'day' end        as unidade,
           case p_agrupar when 'semana' then interval '1 week' when 'mes' then interval '1 month' else interval '1 day' end as passo,
           case p_agrupar when 'semana' then 12 when 'mes' then 12 else 14 end                     as qtd,
           (now() at time zone 'America/Sao_Paulo')::date                                          as hoje
  ),
  inicio as (
    select unidade, passo,
           (date_trunc(unidade, hoje::timestamp) - passo * (qtd - 1))::date as primeiro,
           date_trunc(unidade, hoje::timestamp)::date                       as ultimo
      from cfg
  ),
  eixo as (
    select g::date as periodo
      from inicio, generate_series(primeiro::timestamp, ultimo::timestamp, passo) g
  ),
  contagem as (
    select date_trunc((select unidade from cfg), cu.recebido_em at time zone 'America/Sao_Paulo')::date as periodo,
           count(*) as total
      from public.curriculos cu
     where (cu.recebido_em at time zone 'America/Sao_Paulo')::date >= (select primeiro from inicio)
     group by 1
  )
  select e.periodo, coalesce(c.total, 0)::bigint
    from eixo e left join contagem c using (periodo)
   order by e.periodo
$$;

revoke execute on function public.dashboard_cvs_serie(text) from public, anon;
grant execute on function public.dashboard_cvs_serie(text) to authenticated, service_role;
