-- Garante no banco que uma candidatura nunca tenha duas entrevistas ativas.
-- Rodar uma vez no SQL Editor do projeto Supabase do Recrutei. É idempotente.
--
-- Entrevista ativa = resultado 'agendada' ou 'remarcada'.

-- 1) Agendamento novo (sem entrevista_anterior_id): recusa se já existe uma ativa.
--    O lock por candidatura serializa inserts simultâneos (duplo clique, duas abas).
--    SECURITY DEFINER para a checagem enxergar todas as linhas, mesmo com RLS.
create or replace function public.trg_entrevista_unica_ativa()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.entrevista_anterior_id is null
     and coalesce(new.resultado, 'agendada') in ('agendada', 'remarcada') then

    perform pg_advisory_xact_lock(hashtextextended(new.candidatura_id::text, 0));

    if exists (
      select 1
      from public.entrevistas e
      where e.candidatura_id = new.candidatura_id
        and e.resultado in ('agendada', 'remarcada')
    ) then
      raise exception 'Este candidato já tem uma entrevista agendada. Use "Remarcar" para alterar.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists entrevista_unica_ativa on public.entrevistas;
create trigger entrevista_unica_ativa
  before insert on public.entrevistas
  for each row execute function public.trg_entrevista_unica_ativa();

-- 2) Remarcação: uma entrevista só pode ser substituída uma vez.
create unique index if not exists entrevistas_uma_sucessora
  on public.entrevistas (entrevista_anterior_id)
  where entrevista_anterior_id is not null;
