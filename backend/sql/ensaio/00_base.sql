-- Réplica MÍNIMA do schema de produção (lida via Supabase em 2026-09-23) — só para ENSAIAR migrações
-- em um Postgres descartável (ver backend/sql/ensaio/ensaio.sh). NÃO é o schema oficial e nunca
-- deve ser rodada no Supabase: reproduz apenas o que as migrações do Banco de Talentos tocam.
\set ON_ERROR_STOP on

create schema if not exists extensions;
create schema if not exists auth;
create extension if not exists pgcrypto schema extensions;
create extension if not exists pg_trgm schema extensions;
create extension if not exists unaccent schema extensions;
create extension if not exists btree_gin schema extensions;
create extension if not exists citext schema public;

do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;
grant usage on schema public, extensions to anon, authenticated, service_role;

-- auth.uid() como no Supabase: o claim "sub" da requisição (PostgREST grava os claims em JSON)
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid
$$;
-- papel de conexão do PostgREST (no Supabase também se chama authenticator)
do $$ begin create role authenticator noinherit login password 'x'; exception when duplicate_object then null; end $$;
grant anon, authenticated, service_role to authenticator;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- ── Tipos ──
create type perfil_acesso as enum ('gerente_rh','administrador');
create type status_registro as enum ('ativo','inativo','expurgado');
create type tipo_requisito as enum ('obrigatorio','desejavel');
create type status_candidatura as enum ('recebido','em_analise','avaliado','selecionado','entrevista_agendada',
  'entrevista_realizada','aprovado','reprovado','nao_compareceu','contratado','descartado');
create type origem_curriculo as enum ('anexo_pdf','anexo_docx','anexo_doc','google_docs','corpo_email','upload_manual');
create type resultado_entrevista as enum ('agendada','aprovado','reprovado','nao_compareceu','remarcada','cancelada');
create type tipo_excecao as enum ('sem_anexo','formato_invalido','arquivo_corrompido','ocr_falhou','docs_privado',
  'nao_e_curriculo','vaga_nao_identificada','erro_processamento');
create type status_excecao as enum ('pendente','revisado','ignorado');
create type status_upload_manual as enum ('pendente','processado','erro');
create type acao_auditoria as enum ('criacao','atualizacao','selecao_candidato','descarte_candidato',
  'agendamento_entrevista','resultado_entrevista','bloqueio_remetente','desbloqueio_remetente','alteracao_criterios',
  'inativacao_automatica','expurgo_automatico','exclusao_manual_lgpd','login','reprocessamento');

-- ── Tabelas ──
create table public.usuarios (
  id uuid primary key,
  nome text not null, email citext not null unique, cargo text default 'Gerente de RH',
  iniciais text, ativo boolean not null default true, ultimo_acesso timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  perfil perfil_acesso not null default 'gerente_rh'
);
create table public.setores (
  id uuid primary key default gen_random_uuid(),
  nome text not null, slug text not null, icone text default 'ti-briefcase', cor text default '#3B82F6',
  ordem smallint default 0, ativo boolean default true,
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create table public.empresas (
  id uuid primary key default gen_random_uuid(), sigla text not null, nome text not null,
  ativo boolean default true, created_at timestamptz default now(), updated_at timestamptz default now()
);
create table public.vagas (
  id uuid primary key default gen_random_uuid(),
  setor_id uuid not null references setores(id) on delete restrict,
  titulo text not null check (length(trim(both from titulo)) > 0),
  descricao text, perfil_comportamental text,
  quantidade smallint not null default 1 check (quantidade > 0),
  versao_criterios integer not null default 1 check (versao_criterios > 0),
  status status_registro not null default 'ativo',
  data_abertura date not null default current_date, data_encerramento date,
  criado_por uuid references usuarios(id) on delete set null,
  atualizado_por uuid references usuarios(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint chk_deleted_coerente check ((status = 'ativo' and deleted_at is null) or status <> 'ativo'),
  constraint chk_encerramento_apos_abertura check (data_encerramento is null or data_encerramento >= data_abertura)
);
create table public.vaga_empresas (
  vaga_id uuid references vagas(id) on delete cascade, empresa_id uuid references empresas(id) on delete cascade,
  primary key (vaga_id, empresa_id)
);
create table public.requisitos (
  id uuid primary key default gen_random_uuid(), vaga_id uuid references vagas(id) on delete cascade,
  descricao text, tipo tipo_requisito, peso smallint default 1, ordem smallint default 0,
  created_at timestamptz default now(), updated_at timestamptz default now()
);
create table public.remetentes (
  id uuid primary key default gen_random_uuid(),
  email citext not null unique,
  total_envios integer not null default 0 check (total_envios >= 0),
  primeiro_envio_em timestamptz not null default now(), ultimo_envio_em timestamptz not null default now(),
  bloqueado boolean not null default false, bloqueado_em timestamptz,
  bloqueado_por uuid references usuarios(id) on delete set null, motivo_bloqueio text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint chk_bloqueio_coerente check ((bloqueado = false and bloqueado_em is null) or (bloqueado = true and bloqueado_em is not null))
);
create table public.candidaturas (
  id uuid primary key default gen_random_uuid(),
  remetente_id uuid not null references remetentes(id) on delete restrict,
  vaga_id uuid references vagas(id) on delete set null,
  dados_pessoais jsonb, hash_identidade text,
  status status_candidatura not null default 'recebido',
  aderencia_vaga smallint check (aderencia_vaga >= 0 and aderencia_vaga <= 100),
  vaga_confirmada_rh boolean not null default false,
  email_message_id text, email_assunto text,
  recebido_em timestamptz not null default now(),
  status_registro status_registro not null default 'ativo',
  data_ultimo_evento timestamptz not null default now(),
  em_processo_ativo boolean not null default false,
  inativado_em timestamptz, expurgado_em timestamptz,
  retencao_permanente boolean not null default false,
  selecionado_em timestamptz, selecionado_por uuid references usuarios(id) on delete set null,
  descartado_em timestamptz, descartado_por uuid references usuarios(id) on delete set null,
  motivo_descarte text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint chk_expurgado_sem_dados check (status_registro <> 'expurgado' or dados_pessoais is null),
  constraint chk_expurgo_apos_inativacao check (expurgado_em is null or inativado_em is not null),
  constraint chk_selecao_coerente check (selecionado_em is null or selecionado_em >= recebido_em)
);
create table public.curriculos (
  id uuid primary key default gen_random_uuid(),
  candidatura_id uuid not null unique references candidaturas(id) on delete cascade,
  storage_path text, nome_arquivo text, tipo_mime text,
  tamanho_bytes bigint check (tamanho_bytes is null or tamanho_bytes > 0),
  origem origem_curriculo not null, texto_extraido text,
  ocr_aplicado boolean not null default false, extracao_ok boolean not null default true,
  texto_busca tsvector generated always as (to_tsvector('portuguese'::regconfig, coalesce(texto_extraido, ''))) stored,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.avaliacoes (
  id uuid primary key default gen_random_uuid(),
  candidatura_id uuid not null references candidaturas(id) on delete cascade,
  vaga_id uuid references vagas(id) on delete set null,
  nota smallint not null check (nota >= 0 and nota <= 100),
  resumo_nota text, resumo_ia text,
  pontos_fortes text[] not null default '{}', lacunas text[] not null default '{}',
  requisitos_faltantes text[] not null default '{}',
  eliminado_por_regra boolean not null default false,
  versao_criterios integer not null, modelo_ia text not null,
  tokens_entrada integer check (tokens_entrada is null or tokens_entrada >= 0),
  tokens_saida integer check (tokens_saida is null or tokens_saida >= 0),
  duracao_ms integer check (duracao_ms is null or duracao_ms >= 0),
  sequencia smallint not null default 1 check (sequencia > 0),
  divergencia_detectada boolean not null default false,
  created_at timestamptz not null default now(),
  constraint uq_avaliacao_sequencia unique (candidatura_id, sequencia)
);
create table public.entrevistas (
  id uuid primary key default gen_random_uuid(),
  candidatura_id uuid not null references candidaturas(id) on delete cascade,
  data_hora timestamptz not null,
  duracao_minutos smallint not null default 30 check (duracao_minutos >= 5 and duracao_minutos <= 480),
  local text, entrevistador text,
  resultado resultado_entrevista not null default 'agendada',
  observacoes text, resultado_registrado_em timestamptz,
  resultado_registrado_por uuid references usuarios(id) on delete set null,
  mensagem_enviada text, whatsapp_aberto_em timestamptz,
  entrevista_anterior_id uuid references entrevistas(id) on delete set null,
  agendado_por uuid references usuarios(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint chk_nao_referencia_a_si check (entrevista_anterior_id is null or entrevista_anterior_id <> id),
  constraint chk_resultado_coerente check ((resultado = 'agendada' and resultado_registrado_em is null) or resultado <> 'agendada')
);
create table public.excecoes (
  id uuid primary key default gen_random_uuid(),
  remetente_id uuid references remetentes(id) on delete set null,
  email_remetente citext, email_message_id text, email_assunto text,
  tipo tipo_excecao, detalhe_erro text, nome_arquivo text, storage_path text,
  status status_excecao default 'pendente', revisado_em timestamptz,
  revisado_por uuid references usuarios(id) on delete set null, observacao_revisao text,
  candidatura_gerada_id uuid references candidaturas(id) on delete set null,
  recebido_em timestamptz default now(), created_at timestamptz default now(), updated_at timestamptz default now(),
  reprocessar_solicitado_em timestamptz, reprocessar_solicitado_por uuid references usuarios(id),
  email_corpo text, texto_extraido text
);
create table public.configuracoes (
  chave text primary key, valor jsonb, descricao text,
  updated_at timestamptz default now(), updated_by uuid references usuarios(id) on delete set null
);
create table public.execucoes_pipeline (
  id uuid primary key default gen_random_uuid(), iniciado_em timestamptz default now(), finalizado_em timestamptz,
  sucesso boolean, emails_lidos integer default 0, curriculos_processados integer default 0,
  excecoes_geradas integer default 0, avaliacoes_realizadas integer default 0, duplicados_detectados integer default 0,
  custo_estimado_usd numeric, erro_mensagem text, duracao_segundos integer default 0
);
create table public.uploads_manuais (
  id uuid primary key default gen_random_uuid(),
  vaga_id uuid not null references vagas(id),
  nome_arquivo text not null, tipo_mime text not null, tamanho_bytes bigint, storage_path text not null,
  status status_upload_manual not null default 'pendente', detalhe_erro text,
  candidatura_gerada_id uuid references candidaturas(id),
  enviado_por uuid not null references usuarios(id),
  enviado_em timestamptz not null default now(), processado_em timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create sequence public.logs_auditoria_id_seq;
create table public.logs_auditoria (
  id bigint not null default nextval('public.logs_auditoria_id_seq'),
  ocorrido_em timestamptz not null default now(),
  acao acao_auditoria not null, entidade text not null, entidade_id uuid,
  usuario_id uuid, usuario_nome text, dados_antes jsonb, dados_depois jsonb, detalhe text,
  ip_origem inet, user_agent text,
  primary key (id, ocorrido_em)
) partition by range (ocorrido_em);
create table public.logs_auditoria_default partition of public.logs_auditoria default;

-- ── Índices de produção (tabelas tocadas) ──
create index idx_aval_candidatura on avaliacoes (candidatura_id, sequencia);
create index idx_aval_vaga_nota on avaliacoes (vaga_id, nota desc, created_at desc);
create index idx_cand_dados_pessoais on candidaturas using gin (dados_pessoais jsonb_path_ops) where dados_pessoais is not null;
create index idx_cand_expurgo on candidaturas (inativado_em) where status_registro = 'inativo' and retencao_permanente = false;
create index idx_cand_hash_identidade on candidaturas (hash_identidade, vaga_id) where hash_identidade is not null;
create unique index idx_cand_message_id on candidaturas (email_message_id) where email_message_id is not null;
create index idx_cand_recebido_em on candidaturas (recebido_em desc) where status_registro = 'ativo';
create index idx_cand_remetente on candidaturas (remetente_id, recebido_em desc);
create index idx_cand_retencao on candidaturas (data_ultimo_evento) where status_registro = 'ativo' and em_processo_ativo = false and retencao_permanente = false;
create index idx_cand_status_ativas on candidaturas (status, recebido_em desc) where status_registro = 'ativo';
create index idx_cand_vaga_ativas on candidaturas (vaga_id, status) where status_registro = 'ativo';
create index idx_curr_storage_path on curriculos (storage_path) where storage_path is not null;
create index idx_curr_texto_busca on curriculos using gin (texto_busca);
create index idx_entr_candidatura on entrevistas (candidatura_id, data_hora desc);
create unique index entrevistas_uma_sucessora on entrevistas (entrevista_anterior_id) where entrevista_anterior_id is not null;

-- ── Funções de produção ──
create or replace function public.fn_set_updated_at() returns trigger language plpgsql set search_path to 'public' as $$
begin new.updated_at := now(); return new; end $$;

create or replace function public.fn_usuario_ativo() returns boolean language sql stable parallel safe security definer set search_path to 'public' as $$
  select exists (select 1 from usuarios where id = (select auth.uid()) and ativo = true); $$;
create or replace function public.fn_usuario_admin() returns boolean language sql stable parallel safe security definer set search_path to 'public' as $$
  select exists (select 1 from usuarios where id = (select auth.uid()) and ativo = true and perfil = 'administrador'); $$;

create or replace function public.fn_registra_auditoria(p_acao acao_auditoria, p_entidade text, p_entidade_id uuid,
  p_dados_antes jsonb default null, p_dados_depois jsonb default null, p_detalhe text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid; v_nome text;
begin
  v_uid := auth.uid();
  if v_uid is not null then select nome into v_nome from usuarios where id = v_uid; end if;
  insert into logs_auditoria (acao, entidade, entidade_id, usuario_id, usuario_nome, dados_antes, dados_depois, detalhe)
  values (p_acao, p_entidade, p_entidade_id, v_uid, coalesce(v_nome,'sistema'), p_dados_antes, p_dados_depois, p_detalhe);
end $$;

create or replace function public.fn_atualiza_marco_retencao() returns trigger language plpgsql set search_path to 'public' as $$
begin
  new.em_processo_ativo := new.status in ('selecionado','entrevista_agendada','entrevista_realizada','aprovado','contratado');
  if new.status = 'contratado' then new.retencao_permanente := true; end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status then new.data_ultimo_evento := now(); end if;
  return new;
end $$;

create or replace function public.fn_carimba_decisao() returns trigger language plpgsql set search_path to 'public' as $$
begin
  if new.status = 'selecionado' and old.status <> 'selecionado' then
    new.selecionado_em := coalesce(new.selecionado_em, now());
    new.selecionado_por := coalesce(new.selecionado_por, auth.uid());
  end if;
  if new.status = 'descartado' and old.status <> 'descartado' then
    new.descartado_em := coalesce(new.descartado_em, now());
    new.descartado_por := coalesce(new.descartado_por, auth.uid());
  end if;
  return new;
end $$;

create or replace function public.fn_audita_candidatura() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_acao acao_auditoria;
begin
  if new.status is not distinct from old.status then return new; end if;
  v_acao := case new.status when 'selecionado' then 'selecao_candidato'::acao_auditoria
                            when 'descartado' then 'descarte_candidato'::acao_auditoria
                            else 'atualizacao'::acao_auditoria end;
  perform fn_registra_auditoria(v_acao, 'candidaturas', new.id, jsonb_build_object('status', old.status),
    jsonb_build_object('status', new.status, 'vaga_id', new.vaga_id), format('Status: %s -> %s', old.status, new.status));
  return new;
end $$;

create or replace function public.fn_incrementa_envios_remetente() returns trigger language plpgsql set search_path to 'public' as $$
begin
  update remetentes set total_envios = total_envios + 1, ultimo_envio_em = new.recebido_em where id = new.remetente_id;
  return new;
end $$;

create or replace function public.fn_sincroniza_status_entrevista() returns trigger language plpgsql set search_path to 'public' as $$
begin
  if tg_op = 'INSERT' then
    update candidaturas set status = 'entrevista_agendada'
     where id = new.candidatura_id and status in ('selecionado','nao_compareceu','entrevista_realizada');
    return new;
  end if;
  if new.resultado is distinct from old.resultado then
    update candidaturas set status = case new.resultado
        when 'aprovado' then 'aprovado'::status_candidatura
        when 'reprovado' then 'reprovado'::status_candidatura
        when 'nao_compareceu' then 'nao_compareceu'::status_candidatura
        else status end
     where id = new.candidatura_id;
    new.resultado_registrado_em := coalesce(new.resultado_registrado_em, now());
    new.resultado_registrado_por := coalesce(new.resultado_registrado_por, auth.uid());
  end if;
  return new;
end $$;

create or replace function public.trg_entrevista_unica_ativa() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.entrevista_anterior_id is null and coalesce(new.resultado, 'agendada') in ('agendada', 'remarcada') then
    perform pg_advisory_xact_lock(hashtextextended(new.candidatura_id::text, 0));
    if exists (select 1 from public.entrevistas e where e.candidatura_id = new.candidatura_id and e.resultado in ('agendada', 'remarcada')) then
      raise exception 'Este candidato já tem uma entrevista agendada. Use "Remarcar" para alterar.';
    end if;
  end if;
  return new;
end $$;

create or replace function public.fn_inativar_candidaturas_vencidas() returns table(inativadas integer)
language plpgsql security definer set search_path to 'public' as $$
declare v_meses integer; v_count integer := 0; r record;
begin
  select (valor #>> '{}')::integer into v_meses from configuracoes where chave = 'retencao_meses_ate_inativar';
  v_meses := coalesce(v_meses, 2);
  for r in select id, status, data_ultimo_evento from candidaturas
            where status_registro = 'ativo' and em_processo_ativo = false and retencao_permanente = false
              and data_ultimo_evento < now() - (v_meses || ' months')::interval for update skip locked
  loop
    update candidaturas set status_registro = 'inativo', inativado_em = now() where id = r.id;
    perform fn_registra_auditoria('inativacao_automatica','candidaturas', r.id,
      jsonb_build_object('status_registro','ativo'), jsonb_build_object('status_registro','inativo'),
      format('Inativado automaticamente: %s meses sem evento relevante (último: %s)', v_meses, r.data_ultimo_evento::date));
    v_count := v_count + 1;
  end loop;
  return query select v_count;
end $$;

create or replace function public.fn_expurgar_candidaturas_inativas() returns table(expurgadas integer, arquivos_para_remover text[])
language plpgsql security definer set search_path to 'public' as $$
declare v_meses integer; v_count integer := 0; v_paths text[] := '{}'; r record;
begin
  select (valor #>> '{}')::integer into v_meses from configuracoes where chave = 'retencao_meses_ate_expurgar';
  v_meses := coalesce(v_meses, 4);
  for r in select c.id, c.inativado_em, cur.storage_path from candidaturas c
             left join curriculos cur on cur.candidatura_id = c.id
            where c.status_registro = 'inativo' and c.retencao_permanente = false
              and c.inativado_em < now() - (v_meses || ' months')::interval for update of c skip locked
  loop
    if r.storage_path is not null then v_paths := array_append(v_paths, r.storage_path); end if;
    update curriculos set texto_extraido = null, storage_path = null, nome_arquivo = null where candidatura_id = r.id;
    update candidaturas set dados_pessoais = null, email_assunto = null, email_message_id = null,
           status_registro = 'expurgado', expurgado_em = now() where id = r.id;
    perform fn_registra_auditoria('expurgo_automatico','candidaturas', r.id,
      jsonb_build_object('status_registro','inativo'), jsonb_build_object('status_registro','expurgado'),
      format('Dados pessoais expurgados: %s meses inativo (desde %s)', v_meses, r.inativado_em::date));
    v_count := v_count + 1;
  end loop;
  return query select v_count, v_paths;
end $$;

create or replace function public.fn_excluir_dados_candidato(p_candidatura_id uuid, p_motivo text default 'Solicitação do titular (LGPD Art. 18)')
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_path text;
begin
  select storage_path into v_path from curriculos where candidatura_id = p_candidatura_id;
  update curriculos set texto_extraido = null, storage_path = null, nome_arquivo = null where candidatura_id = p_candidatura_id;
  update candidaturas set dados_pessoais = null, email_assunto = null, email_message_id = null,
         status_registro = 'expurgado', expurgado_em = now(), inativado_em = coalesce(inativado_em, now())
   where id = p_candidatura_id;
  perform fn_registra_auditoria('exclusao_manual_lgpd','candidaturas', p_candidatura_id, null,
    jsonb_build_object('status_registro','expurgado'), p_motivo);
  return v_path;
end $$;

create or replace function public.fn_manutencao_diaria() returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_inativadas integer; v_expurgadas integer; v_paths text[]; v_proxima date; v_nome text;
begin
  select inativadas into v_inativadas from fn_inativar_candidaturas_vencidas();
  select expurgadas, arquivos_para_remover into v_expurgadas, v_paths from fn_expurgar_candidaturas_inativas();
  v_proxima := (date_trunc('month', current_date) + interval '2 month')::date;
  v_nome := 'logs_auditoria_' || to_char(v_proxima,'YYYY_MM');
  if not exists (select 1 from pg_class where relname = v_nome) then
    execute format('create table %I partition of logs_auditoria for values from (%L) to (%L)', v_nome, v_proxima, (v_proxima + interval '1 month')::date);
    execute format('alter table %I enable row level security', v_nome);
    execute format('alter table %I force row level security', v_nome);
    execute format('create policy %1$s_leitura on %1$I for select to authenticated using (fn_usuario_ativo())', v_nome);
  end if;
  return jsonb_build_object('executado_em', now(), 'inativadas', v_inativadas, 'expurgadas', v_expurgadas,
                            'arquivos_para_remover', to_jsonb(v_paths));
end $$;

-- ── Triggers de produção ──
create trigger trg_cand_auditoria after update of status on candidaturas for each row execute function fn_audita_candidatura();
create trigger trg_cand_carimba_decisao before update of status on candidaturas for each row execute function fn_carimba_decisao();
create trigger trg_cand_incrementa_envios after insert on candidaturas for each row execute function fn_incrementa_envios_remetente();
create trigger trg_cand_marco_retencao before insert or update of status on candidaturas for each row execute function fn_atualiza_marco_retencao();
create trigger trg_candidaturas_updated_at before update on candidaturas for each row execute function fn_set_updated_at();
create trigger trg_curriculos_updated_at before update on curriculos for each row execute function fn_set_updated_at();
create trigger entrevista_unica_ativa before insert on entrevistas for each row execute function trg_entrevista_unica_ativa();
create trigger trg_entr_sincroniza_insert after insert on entrevistas for each row execute function fn_sincroniza_status_entrevista();
create trigger trg_entr_sincroniza_update before update of resultado on entrevistas for each row execute function fn_sincroniza_status_entrevista();
create trigger trg_entrevistas_updated_at before update on entrevistas for each row execute function fn_set_updated_at();
create trigger trg_vagas_updated_at before update on vagas for each row execute function fn_set_updated_at();
create trigger trg_uploads_manuais_updated_at before update on uploads_manuais for each row execute function fn_set_updated_at();
