-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Dashboard: e-mails recebidos na caixa, por dia (069)
--
--  Rodar depois da 068. Pode rodar de novo sem problema.
--
--  O painel não lê a caixa de e-mail: o robô conta e grava aqui, um registro por dia (só números, nenhum dado pessoal):
--    • emails         — mensagens que chegaram na caixa de entrada naquele dia
--    • com_anexo      — as que trazem algum anexo (inclui imagens de assinatura e logos, por isso superestima)
--    • com_documento  — as que trazem PDF, DOC, DOCX, ODT ou RTF (o mais próximo de "e-mail com currículo")
--  dashboard_emails_serie() agrupa por dia, semana (segunda a domingo) ou mês, no mesmo eixo de dashboard_cvs_serie() (064).
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.caixa_emails_dia (
  dia            date primary key,
  emails         integer not null default 0 check (emails >= 0),
  com_anexo      integer not null default 0 check (com_anexo >= 0),
  com_documento  integer not null default 0 check (com_documento >= 0),
  atualizado_em  timestamptz not null default now()
);
comment on table public.caixa_emails_dia is
  'Contagem diária de e-mails da caixa de entrada (total, com anexo, com PDF/DOC). Gravada pelo robô; só números.';

alter table public.caixa_emails_dia enable row level security;
drop policy if exists caixa_emails_leitura on public.caixa_emails_dia;
create policy caixa_emails_leitura on public.caixa_emails_dia for select to authenticated using (public.fn_usuario_ativo());

revoke all on public.caixa_emails_dia from anon, authenticated;
grant select on public.caixa_emails_dia to authenticated;
grant all on public.caixa_emails_dia to service_role;

create or replace function public.dashboard_emails_serie(p_agrupar text default 'dia')
returns table(periodo date, emails bigint, com_documento bigint)
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
    select date_trunc((select unidade from cfg), d.dia::timestamp)::date as periodo,
           sum(d.emails) as emails, sum(d.com_documento) as com_documento
      from public.caixa_emails_dia d
     where d.dia >= (select primeiro from inicio)
     group by 1
  )
  select e.periodo, coalesce(c.emails, 0)::bigint, coalesce(c.com_documento, 0)::bigint
    from eixo e left join contagem c using (periodo)
   order by e.periodo
$$;

revoke execute on function public.dashboard_emails_serie(text) from public, anon;
grant execute on function public.dashboard_emails_serie(text) to authenticated, service_role;
