-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Contratar o candidato aprovado (070)
--
--  Rodar depois da 069. Pode rodar de novo sem problema.
--
--  O status "contratado" já existia (contadores das vagas, dashboard, retenção permanente), mas o painel não tinha como chegar
--  nele: a candidatura parava em "aprovado".
--    • contratar_candidatura(id) — só vale para candidatura "aprovado" e ainda aberta. Passa para "contratado"; os gatilhos da 022
--      fazem o resto: fecham a candidatura (encerrada_em, resultado_final) e tiram o candidato do Banco de Talentos (inativo, com
--      retenção permanente — contratado não vai à sanitização).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.contratar_candidatura(p_candidatura_id uuid)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status    public.status_candidatura;
  v_encerrada timestamptz;
begin
  perform public.fn_exige_usuario_ativo();

  select status, encerrada_em into v_status, v_encerrada
    from public.candidaturas where id = p_candidatura_id for update;
  if not found then
    raise exception 'Candidatura não encontrada.';
  end if;
  if v_encerrada is not null then
    raise exception 'Esta candidatura já foi encerrada.';
  end if;
  if v_status <> 'aprovado' then
    raise exception 'Só é possível contratar candidato aprovado.';
  end if;

  update public.candidaturas
     set status = 'contratado'::public.status_candidatura
   where id = p_candidatura_id;
end $$;

revoke all on function public.contratar_candidatura(uuid) from public, anon;
grant execute on function public.contratar_candidatura(uuid) to authenticated;
grant execute on function public.contratar_candidatura(uuid) to service_role;
