-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Upload manual de currículo
--
--  Rode UMA vez: Supabase → SQL Editor → New query → cole este arquivo → Run.
--  Cria a tabela "uploads_manuais" (nenhuma tabela existente perde dado).
--
--  O que isso habilita: o botão "Enviar currículo" na tela Vagas. O RH escolhe
--  uma vaga aberta e envia um arquivo (PDF/DOC/DOCX) direto pelo painel — sem
--  precisar de e-mail. O painel só grava o pedido (fila, igual à Fila de
--  exceções); quem baixa o arquivo, extrai o texto, classifica e avalia é o
--  pipeline Python, na próxima execução (ou com  python main.py --uploads-manuais).
--  A vaga já escolhida pelo RH pula a etapa de "qual vaga combina" — a IA só
--  confirma que é currículo de verdade e avalia contra essa vaga.
--
--  Sem isto: o botão "Enviar currículo" ainda não aparece habilitado — a tela
--  avisa que precisa desta atualização, do mesmo jeito que os filtros
--  avançados avisam em backend/sql/filtros_avancados.sql.
-- ════════════════════════════════════════════════════════════════════════

create type public.status_upload_manual as enum ('pendente', 'processado', 'erro');

create table public.uploads_manuais (
  id                    uuid primary key default gen_random_uuid(),
  vaga_id               uuid not null references public.vagas(id),
  nome_arquivo          text not null,
  tipo_mime             text not null,
  tamanho_bytes         bigint,
  storage_path          text not null,
  status                public.status_upload_manual not null default 'pendente',
  detalhe_erro          text,
  candidatura_gerada_id uuid references public.candidaturas(id),
  enviado_por           uuid not null references public.usuarios(id),
  enviado_em            timestamptz not null default now(),
  processado_em         timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table public.uploads_manuais is
  'Currículos enviados manualmente pelo RH no painel (sem passar por e-mail). O pipeline Python processa como fila, igual à Fila de exceções.';
comment on column public.uploads_manuais.status is
  'pendente = aguardando o pipeline; processado = candidatura criada (ver candidatura_gerada_id); erro = não deu pra avaliar (ver detalhe_erro).';

create trigger trg_uploads_manuais_updated_at
  before update on public.uploads_manuais
  for each row execute function public.fn_set_updated_at();

alter table public.uploads_manuais enable row level security;

create policy uploads_manuais_rh_select on public.uploads_manuais
  for select to authenticated using (fn_usuario_ativo());

create policy uploads_manuais_rh_insert on public.uploads_manuais
  for insert to authenticated with check (fn_usuario_ativo());

create policy uploads_manuais_rh_update on public.uploads_manuais
  for update to authenticated using (fn_usuario_ativo()) with check (fn_usuario_ativo());

create policy uploads_manuais_admin_delete on public.uploads_manuais
  for delete to authenticated using (fn_usuario_admin());

grant select, insert, update, delete on public.uploads_manuais to authenticated;

-- O Storage já aceita upload no bucket "curriculos" por usuário ativo
-- (storage_curriculos_insert, de antes desta migração) — nada a mudar lá.
