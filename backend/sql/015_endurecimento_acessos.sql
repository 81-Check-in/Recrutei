-- 015_endurecimento_acessos
-- Correções da auditoria de segurança de 2026-09-20.
--
--  1. O cadastro público estava aberto e o gatilho de perfil lia "perfil" de raw_user_meta_data
--     (preenchido pelo próprio cliente): qualquer pessoa podia criar uma conta administrador ativa.
--  2. Qualquer usuário podia editar a própria linha inteira em "usuarios" (inclusive perfil e ativo).
--  3. fn_excluir_dados_candidato (SECURITY DEFINER, sem checagem de quem chama) era executável por RPC.
--  4. Privilégios de tabela desnecessários: anon com acesso total; TRUNCATE/TRIGGER/REFERENCES no authenticated.
--
-- Efeito para quem administra: todo usuário novo nasce INATIVO. Depois de criá-lo no painel do Supabase
-- (Authentication > Users), ative-o:  update public.usuarios set ativo = true where email = '...';
-- Para nascer administrador, defina "perfil" em app_metadata (não em user_metadata) ou promova por SQL.

-- 1) Gatilho de cadastro: perfil só vem de raw_app_meta_data (definido no servidor) e o usuário nasce inativo
create or replace function public.fn_cria_perfil_usuario()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into usuarios (id, nome, email, cargo, perfil, ativo)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'nome', split_part(new.email, '@', 1)),
    new.email,
    coalesce(new.raw_user_meta_data ->> 'cargo', 'Gerente de RH'),
    coalesce((new.raw_app_meta_data ->> 'perfil')::perfil_acesso, 'gerente_rh'),
    false
  )
  on conflict (id) do nothing;
  return new;
end
$function$;

-- 2) "usuarios": o usuário só pode atualizar o próprio ultimo_acesso (perfil, ativo, e-mail... só por SQL/service_role)
revoke update on public.usuarios from authenticated;
grant update (ultimo_acesso) on public.usuarios to authenticated;

-- 3) Funções que não devem ser chamadas por RPC
revoke execute on function public.fn_excluir_dados_candidato(uuid, text) from public, anon, authenticated;
revoke execute on function public.trg_entrevista_unica_ativa() from public, anon, authenticated;

-- 4) excluir_entrevista: além das regras existentes, exige usuário ativo (um usuário desativado com sessão aberta
--    ainda podia excluir as entrevistas que ele mesmo agendou)
create or replace function public.excluir_entrevista(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v public.entrevistas%rowtype;
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
$function$;

-- 5) Privilégios de tabela. O app nunca acessa dados como anon (login e recuperação de senha usam a API de Auth).
--    Não mexer em funções em massa: as do citext moram em "public" e o authenticated precisa executá-las.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke truncate, references, trigger on tables from authenticated;

-- Para reverter (não recomendado):
--   grant update on public.usuarios to authenticated;
--   grant execute on function public.fn_excluir_dados_candidato(uuid, text) to authenticated;
--   grant all on all tables in schema public to anon;
