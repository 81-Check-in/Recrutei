-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Dashboard: CVs por região (063)
--
--  Rodar depois da 062. Pode rodar de novo sem problema.
--
--  De onde vêm os currículos recebidos no período: p_dias = 7 → últimos 7 dias; qualquer outro valor → mês atual (o
--  mesmo recorte do seletor "7 dias / Mês atual" do painel). Conta CANDIDATOS distintos, não arquivos (quem mandou
--  duas vezes conta uma). O lugar é a região do candidato; sem região, a cidade; sem nenhuma das duas, "Não identificada".
--  Vale a permissão de quem consulta (security invoker).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.dashboard_cvs_por_regiao(p_dias integer default 7)
returns table(local text, total bigint)
language sql stable security invoker
set search_path to 'public'
as $$
  select coalesce(r.nome, nullif(btrim(c.cidade), ''), 'Não identificada') as local,
         count(distinct c.id)                                              as total
    from public.curriculos cu
    join public.candidatos c on c.id = cu.candidato_id
    left join public.regioes_df r on r.id = c.regiao_id
   where cu.recebido_em >= case when p_dias = 7 then (current_date - 7)::timestamptz
                                else date_trunc('month', current_date::timestamptz) end
   group by 1
   order by 2 desc, 1
$$;

revoke execute on function public.dashboard_cvs_por_regiao(integer) from public, anon;
grant execute on function public.dashboard_cvs_por_regiao(integer) to authenticated, service_role;
