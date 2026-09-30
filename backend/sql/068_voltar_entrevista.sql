-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Voltar entrevista agendada para "Em processo" (068)
--
--  Rodar depois da 067. Pode rodar de novo sem problema.
--
--  Entrevista marcada por engano/teste: em vez de só apagar, o RH pode VOLTAR o candidato para "Em processo".
--    • voltar_entrevista(id) — a entrevista fica como "cancelada" (o registro permanece, mas some da agenda) e a candidatura volta
--      para "aguardando", o mesmo status de quem ainda não tem entrevista. Quem pode: quem agendou ou um administrador (mesma regra
--      da exclusão). Não vai para o Histórico do candidato: ele só recebe desfechos (aprovado, reprovado, não compareceu).
--    • Apagar de vez continua sendo excluir_entrevista (só o administrador, no painel).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.voltar_entrevista(p_id uuid)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v       public.entrevistas%rowtype;
  v_admin boolean;
begin
  if auth.uid() is null then
    raise exception 'Sessão expirada. Entre novamente.';
  end if;
  if not public.fn_usuario_ativo() then
    raise exception 'Usuário inativo. Contate o administrador.';
  end if;

  select * into v from public.entrevistas where id = p_id for update;
  if not found then
    raise exception 'Entrevista não encontrada (talvez já tenha sido excluída).';
  end if;

  select exists (
    select 1 from public.usuarios u
     where u.id = auth.uid() and u.ativo and u.perfil = 'administrador'
  ) into v_admin;
  if not (v_admin or v.agendado_por = auth.uid()) then
    raise exception 'Só quem agendou a entrevista ou um administrador pode voltá-la para Em processo.';
  end if;

  if v.resultado <> 'agendada' then
    raise exception 'Só é possível voltar entrevista ainda agendada, sem resultado registrado.';
  end if;
  if exists (select 1 from public.entrevistas where entrevista_anterior_id = p_id) then
    raise exception 'Esta entrevista já foi remarcada e não pode ser voltada.';
  end if;

  update public.entrevistas set resultado = 'cancelada' where id = p_id;

  if not exists (
    select 1 from public.entrevistas e
     where e.candidatura_id = v.candidatura_id and e.resultado in ('agendada', 'remarcada')
  ) then
    update public.candidaturas set status = 'aguardando'
     where id = v.candidatura_id and status = 'entrevista_agendada';
  end if;
end $$;

revoke all on function public.voltar_entrevista(uuid) from public, anon;
grant execute on function public.voltar_entrevista(uuid) to authenticated;
grant execute on function public.voltar_entrevista(uuid) to service_role;
