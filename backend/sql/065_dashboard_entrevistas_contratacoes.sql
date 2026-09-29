-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Dashboard: entrevistas x contratações por mês (065)
--
--  Rodar depois da 064. Pode rodar de novo sem problema.
--
--  Sai do Histórico do candidato (historico_candidatos), que tem a planilha antiga e as entrevistas do sistema:
--    • entrevistas  = quem foi entrevistado no mês (todos os desfechos, menos "não compareceu")
--    • contratacoes = quem foi aprovado no mês (quem desistiu depois de aprovado tem outro status e não conta)
--  Os meses sem registro aparecem com 0. p_meses = quantos meses mostrar, contando o atual (1 a 36).
--  Vale a permissão de quem consulta (security invoker).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.dashboard_entrevistas_contratacoes(p_meses integer default 6)
returns table(mes date, entrevistas bigint, contratacoes bigint)
language sql stable security invoker
set search_path to 'public'
as $$
  with n as (select least(greatest(coalesce(p_meses, 6), 1), 36) as qtd),
  eixo as (
    select (date_trunc('month', (now() at time zone 'America/Sao_Paulo')) - interval '1 month' * g)::date as mes
      from n, generate_series(0, (select qtd from n) - 1) g
  )
  select e.mes,
         count(h.id) filter (where h.status <> 'nao_compareceu')::bigint,
         count(h.id) filter (where h.status = 'aprovado')::bigint
    from eixo e
    left join public.historico_candidatos h
           on h.data_evento >= e.mes and h.data_evento < (e.mes + interval '1 month')::date
   group by e.mes
   order by e.mes
$$;

revoke execute on function public.dashboard_entrevistas_contratacoes(integer) from public, anon;
grant execute on function public.dashboard_entrevistas_contratacoes(integer) to authenticated, service_role;
