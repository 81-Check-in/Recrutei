-- Permite excluir uma entrevista agendada por engano.
-- Rodar uma vez no SQL Editor do projeto Supabase do Recrutei. É idempotente.
--
-- Regras:
--   * só quem agendou ou um administrador pode excluir;
--   * só entrevistas ainda 'agendada' (sem resultado registrado);
--   * não exclui entrevista que já foi remarcada (tem sucessora);
--   * se era a única entrevista ativa, o candidato volta para 'selecionado'.
--
-- SECURITY DEFINER: a exclusão e o ajuste de status acontecem juntos, sem depender
-- das políticas de RLS de cada tabela. A autorização é feita aqui dentro.

create or replace function public.excluir_entrevista(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.entrevistas%rowtype;
  v_admin boolean;
begin
  if auth.uid() is null then
    raise exception 'Sessão expirada. Entre novamente.';
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
    raise exception 'Só quem agendou a entrevista ou um administrador pode excluí-la.';
  end if;

  if v.resultado <> 'agendada' then
    raise exception 'Só é possível excluir entrevista ainda agendada, sem resultado registrado.';
  end if;

  if exists (select 1 from public.entrevistas where entrevista_anterior_id = p_id) then
    raise exception 'Esta entrevista já foi remarcada e não pode ser excluída.';
  end if;

  delete from public.entrevistas where id = p_id;

  -- Era a única entrevista ativa: o candidato volta a aguardar agendamento.
  if not exists (
    select 1 from public.entrevistas e
    where e.candidatura_id = v.candidatura_id
      and e.resultado in ('agendada', 'remarcada')
  ) then
    update public.candidaturas
       set status = 'selecionado'
     where id = v.candidatura_id and status = 'entrevista_agendada';
  end if;
end;
$$;

revoke all on function public.excluir_entrevista(uuid) from public, anon;
grant execute on function public.excluir_entrevista(uuid) to authenticated;

-- Faz a API do Supabase enxergar a função na hora (senão o painel dá "não habilitada").
notify pgrst, 'reload schema';
