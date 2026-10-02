-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Dashboard: CVs recebidos por e-mail e pelo portal de vagas (076)
--
--  Rodar depois da 075. Pode rodar de novo sem problema.
--
--  O gráfico "CVs recebidos" mostrava os e-mails da caixa (todos, com ou sem currículo) ao lado dos CVs gravados. Agora mostra
--  só o que virou currículo, separado por onde chegou:
--    • por_email   — currículos LIDOS que vieram por e-mail (anexo, link do Google Docs ou corpo do e-mail); e-mail sem
--                    currículo, exceção e reenvio ignorado não entram.
--    • pelo_portal — inscrições do portal de vagas que trouxeram currículo (portal_inscricoes). Onde o portal não está
--                    instalado (a tabela não existe), a coluna vem sempre 0.
--  O envio manual do RH (botão "Enviar currículo") não entra em nenhuma das duas.
--  p_agrupar: 'dia' (últimos 14 dias), 'semana' (últimas 12, começando na segunda) ou 'mes' (últimos 12), no horário de
--  Brasília, no mesmo eixo de dashboard_cvs_serie() (064). O último período do agrupamento 'dia' é HOJE (cartão do topo).
--  Vale a permissão de quem consulta (security invoker).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.dashboard_cvs_origem_serie(p_agrupar text default 'dia')
returns table(periodo date, por_email bigint, pelo_portal bigint)
language plpgsql stable security invoker
set search_path to 'public'
as $$
declare
  v_unidade  text     := case p_agrupar when 'semana' then 'week' when 'mes' then 'month' else 'day' end;
  v_passo    interval := case p_agrupar when 'semana' then interval '1 week' when 'mes' then interval '1 month' else interval '1 day' end;
  v_qtd      integer  := case p_agrupar when 'semana' then 12 when 'mes' then 12 else 14 end;
  v_hoje     date     := (now() at time zone 'America/Sao_Paulo')::date;
  v_ultimo   date     := date_trunc(v_unidade, v_hoje::timestamp)::date;
  v_primeiro date     := (date_trunc(v_unidade, v_hoje::timestamp) - v_passo * (v_qtd - 1))::date;
  v_portal   text     := 'select null::date as periodo, 0::bigint as total where false';
begin
  -- o portal é opcional: sem a tabela, a série dele fica vazia
  if to_regclass('public.portal_inscricoes') is not null then
    v_portal := format(
      'select date_trunc(%L, i.recebida_em at time zone ''America/Sao_Paulo'')::date as periodo, count(*)::bigint as total
         from public.portal_inscricoes i
        where i.curriculo_path is not null and (i.recebida_em at time zone ''America/Sao_Paulo'')::date >= %L
        group by 1', v_unidade, v_primeiro);
  end if;

  return query execute format($q$
    with eixo as (
      select g::date as periodo from generate_series(%L::timestamp, %L::timestamp, %L::interval) g
    ),
    email as (
      select date_trunc(%L, cu.recebido_em at time zone 'America/Sao_Paulo')::date as periodo, count(*)::bigint as total
        from public.curriculos cu
       where cu.origem::text <> 'upload_manual'
         and (cu.recebido_em at time zone 'America/Sao_Paulo')::date >= %L
       group by 1
    ),
    portal as (%s)
    select e.periodo, coalesce(m.total, 0)::bigint, coalesce(p.total, 0)::bigint
      from eixo e left join email m using (periodo) left join portal p using (periodo)
     order by e.periodo
  $q$, v_primeiro, v_ultimo, v_passo, v_unidade, v_primeiro, v_portal);
end $$;

revoke execute on function public.dashboard_cvs_origem_serie(text) from public, anon;
grant execute on function public.dashboard_cvs_origem_serie(text) to authenticated, service_role;
