-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · PASSO 2 de 6: modelo de dados
--
--  ANTES: candidato → vinculado a UMA vaga → preso a ela (tudo morava em "candidaturas").
--  DEPOIS: candidato é uma entidade própria e reutilizável ("candidatos"); a análise da IA é dele
--  ("analises_ia", histórico); e o vínculo com vaga vira histórico N:N ("candidaturas", que passa a
--  ser o CandidaturaVaga: uma linha por atribuição, com status, quem atribuiu e resultado).
--
--  Este arquivo só ACRESCENTA: cria tabelas/colunas/índices novos e afrouxa três restrições que
--  impediam o modelo novo. Nada é apagado nem movido — isso é o passo 025 (com verificações).
--  Pode rodar de novo sem problema.
-- ════════════════════════════════════════════════════════════════════════

create extension if not exists pg_trgm with schema extensions;

-- Texto em minúsculas e sem acento (mesma função de filtros_avancados.sql). As colunas geradas de
-- "candidatos" dependem dela; por isso ela também é garantida aqui.
create or replace function public.norm_busca(t text)
returns text
language sql immutable parallel safe
as $$
  select translate(lower(coalesce(t, '')),
                   'áàâãäéèêëíìîïóòôõöúùûüçñ',
                   'aaaaaeeeeiiiiooooouuuucn')
$$;

-- ───────────────────────────────────────────────────────────────────────
--  Tipos
-- ───────────────────────────────────────────────────────────────────────
do $$ begin
  create type public.status_banco_talentos as enum ('ativo', 'em_processo', 'inativo', 'expurgado');
exception when duplicate_object then null; end $$;

-- ───────────────────────────────────────────────────────────────────────
--  CANDIDATOS — a entidade central e persistente
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.candidatos (
  id                      uuid primary key default gen_random_uuid(),

  -- dados pessoais (todos anuláveis: o currículo nem sempre informa)
  nome                    text,
  sexo                    text check (sexo in ('masculino', 'feminino')),
  data_nascimento         date check (data_nascimento is null or data_nascimento >= date '1900-01-01'),
  -- A maioria dos currículos traz só a idade ("Idade: 27 anos"), não a data. Guarda-se a idade e o dia
  -- em que foi lida; "nascimento_ref" (abaixo) junta as duas coisas num campo indexável para filtrar
  -- por faixa etária sem calcular idade linha a linha.
  idade_informada         smallint check (idade_informada between 14 and 85),
  idade_informada_em      date,
  nascimento_ref          date generated always as (
                            coalesce(data_nascimento, idade_informada_em - (idade_informada * 365 + 183))
                          ) stored,
  cidade                  text,
  uf                      text check (uf ~ '^[A-Z]{2}$'),
  telefone                text,
  telefone_e164           text,
  email                   text,

  -- perfil extraído do currículo (filtros da tela)
  escolaridade            text check (escolaridade in ('nenhuma', 'fundamental', 'medio', 'tecnico', 'superior', 'pos')),
  anos_experiencia        numeric(4, 1) check (anos_experiencia is null or anos_experiencia >= 0),
  cnh                     text,

  -- campos de busca (derivados; não escreva neles)
  nome_norm               text generated always as (public.norm_busca(nome)) stored,
  cidade_norm             text generated always as (public.norm_busca(cidade)) stored,
  escolaridade_ord        smallint generated always as (
                            case escolaridade
                              when 'nenhuma' then 0 when 'fundamental' then 1 when 'medio' then 2
                              when 'tecnico' then 3 when 'superior' then 4 when 'pos' then 5 end
                          ) stored,

  -- identidade (HMAC de nome+telefone; sobrevive ao expurgo para detectar reenvio)
  hash_identidade         text,

  -- situação no banco
  status_banco            public.status_banco_talentos not null default 'ativo',
  origem_entrada          text not null default 'email' check (origem_entrada in ('email', 'upload_manual', 'migracao')),
  data_entrada            timestamptz not null default now(),
  ultima_atualizacao      timestamptz not null default now(),   -- dados, currículo ou análise mudaram
  ultima_movimentacao     timestamptz not null default now(),   -- qualquer movimento: candidatura, currículo, contato, edição
  ultimo_contato_em       timestamptz,
  inativado_em            timestamptz,
  motivo_inativacao       text,
  expurgado_em            timestamptz,
  retencao_permanente     boolean not null default false,       -- contratado: não entra na sanitização

  -- LGPD
  consentimento_em        timestamptz,
  consentimento_origem    text check (consentimento_origem in ('envio_espontaneo', 'confirmado_pelo_candidato')),

  -- sanitização
  sanitizacao_adiada_ate  timestamptz,                          -- "manter": não sugerir de novo antes disso

  -- sugestão ATUAL da IA (cópia da análise mais recente, para filtrar e indexar sem juntar tabelas)
  analise_atual_id        uuid,
  area_sugerida           text,
  cargo_sugerido          text,
  nivel_sugerido          text check (nivel_sugerido in ('estagio', 'junior', 'pleno', 'senior', 'lideranca')),
  ia_confianca            smallint check (ia_confianca between 0 and 100),
  revisao_manual          boolean not null default false,       -- a IA não classificou com confiança
  reanalise_solicitada_em timestamptz,                          -- pedido de (re)análise à espera do pipeline

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint chk_candidato_expurgado_sem_dados check (
    status_banco <> 'expurgado'
    or (nome is null and telefone is null and telefone_e164 is null and email is null and cidade is null)
  )
);

comment on table public.candidatos is
  'Banco de Talentos: cada pessoa uma vez, independente de vaga. O vínculo com vagas está em "candidaturas" (histórico N:N).';
comment on column public.candidatos.status_banco is
  'ativo = disponível para atribuir; em_processo = tem candidatura aberta; inativo = fora do banco por decisão do RH (ou contratado); expurgado = dados pessoais apagados (só sobra o hash de identidade e as métricas).';
comment on column public.candidatos.nascimento_ref is
  'Data de nascimento exata, ou estimada a partir da idade informada. Serve só para filtro de faixa etária (índice); a idade aparece em vw_banco_talentos.';
comment on column public.candidatos.ultima_movimentacao is
  'Última vez que algo aconteceu com o candidato (candidatura, novo currículo, contato, edição). Base do critério "sem movimentação" da sanitização.';

-- ───────────────────────────────────────────────────────────────────────
--  ANALISES_IA — histórico de análises por candidato (a mais recente vale)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.analises_ia (
  id                 uuid primary key default gen_random_uuid(),
  candidato_id       uuid not null references public.candidatos(id) on delete cascade,
  curriculo_id       uuid,                                       -- qual currículo foi analisado (FK abaixo)
  sequencia          smallint not null default 1 check (sequencia > 0),
  pontos_positivos   text[] not null default '{}',
  pontos_negativos   text[] not null default '{}',
  area_sugerida      text,                                       -- ex.: Logística
  cargo_sugerido     text,                                       -- ex.: Auxiliar
  nivel_sugerido     text check (nivel_sugerido in ('estagio', 'junior', 'pleno', 'senior', 'lideranca')),
  confianca          smallint check (confianca between 0 and 100),
  revisao_manual     boolean not null default false,             -- confiança baixa ou campos sem classificação
  motivo_revisao     text,
  texto_resumo_ia    text,
  data_analise       timestamptz not null default now(),
  versao_modelo_ia   text not null,                              -- ex.: claude-sonnet-5
  versao_prompt      smallint not null default 1,
  origem             text not null default 'ia' check (origem in ('ia', 'migracao')),
  tokens_entrada     integer check (tokens_entrada is null or tokens_entrada >= 0),
  tokens_saida       integer check (tokens_saida is null or tokens_saida >= 0),
  duracao_ms         integer check (duracao_ms is null or duracao_ms >= 0),
  constraint uq_analise_sequencia unique (candidato_id, sequencia)
);
comment on table public.analises_ia is
  'Análise da IA por candidato (não por vaga). Reenviar/editar o currículo gera uma linha nova; candidatos.analise_atual_id aponta a vigente.';

alter table public.candidatos drop constraint if exists candidatos_analise_atual_fkey;
alter table public.candidatos
  add constraint candidatos_analise_atual_fkey
  foreign key (analise_atual_id) references public.analises_ia(id) on delete set null;

-- ───────────────────────────────────────────────────────────────────────
--  CANDIDATURAS — passa a ser o vínculo candidato ↔ vaga (histórico N:N)
-- ───────────────────────────────────────────────────────────────────────
alter table public.candidaturas
  add column if not exists candidato_id          uuid references public.candidatos(id) on delete restrict,
  add column if not exists atribuido_por         uuid references public.usuarios(id) on delete set null,
  add column if not exists data_atribuicao       timestamptz,
  add column if not exists resultado_final       text,
  add column if not exists encerrada_em          timestamptz,     -- preenchido quando a candidatura fecha (reprovado/cancelado/descartado/contratado)
  add column if not exists observacao_atribuicao text,
  add column if not exists avaliacao_pendente    boolean not null default false,  -- a IA ainda vai avaliar este candidato para esta vaga
  add column if not exists origem                text not null default 'atribuicao_manual'
                                                 check (origem in ('atribuicao_manual', 'triagem_legada'));

comment on column public.candidaturas.origem is
  'atribuicao_manual = o RH atribuiu o candidato à vaga; triagem_legada = vínculo automático do modelo antigo (a IA escolhia a vaga), encerrado na migração e mantido só como histórico.';
comment on column public.candidaturas.encerrada_em is
  'Nulo = candidatura aberta (candidato "em processo"). Reprovar/cancelar preenche e o candidato volta ao Banco de Talentos.';

-- uma candidatura não precisa mais de e-mail de origem (o e-mail pertence ao currículo)
alter table public.candidaturas alter column remetente_id drop not null;

-- ───────────────────────────────────────────────────────────────────────
--  CURRICULOS — passam a pertencer ao candidato (várias versões por candidato)
-- ───────────────────────────────────────────────────────────────────────
alter table public.curriculos
  add column if not exists candidato_id     uuid references public.candidatos(id) on delete cascade,
  add column if not exists atual            boolean not null default true,    -- só um "atual" por candidato
  add column if not exists remetente_id     uuid references public.remetentes(id) on delete set null,
  add column if not exists email_message_id text,
  add column if not exists email_assunto    text,
  add column if not exists recebido_em      timestamptz not null default now();

-- o currículo sobrevive à candidatura (antes: apagar a candidatura apagava o currículo)
alter table public.curriculos alter column candidatura_id drop not null;
alter table public.curriculos drop constraint if exists curriculos_candidatura_id_fkey;
alter table public.curriculos
  add constraint curriculos_candidatura_id_fkey
  foreign key (candidatura_id) references public.candidaturas(id) on delete set null;
-- várias versões de currículo por candidato: cai a unicidade por candidatura
alter table public.curriculos drop constraint if exists curriculos_candidatura_id_key;

alter table public.analises_ia drop constraint if exists analises_ia_curriculo_fkey;
alter table public.analises_ia
  add constraint analises_ia_curriculo_fkey
  foreign key (curriculo_id) references public.curriculos(id) on delete set null;

-- ───────────────────────────────────────────────────────────────────────
--  UPLOADS_MANUAIS — a vaga deixa de ser obrigatória (todo currículo entra no banco primeiro)
-- ───────────────────────────────────────────────────────────────────────
alter table public.uploads_manuais alter column vaga_id drop not null;
alter table public.uploads_manuais
  add column if not exists candidato_gerado_id uuid references public.candidatos(id);

-- ───────────────────────────────────────────────────────────────────────
--  ÍNDICES — busca do Banco de Talentos
-- ───────────────────────────────────────────────────────────────────────
-- Nome: busca PARCIAL ("mar" acha "Maria"). O que atende "like '%x%'" é trigrama (GIN), não
-- full-text (que só casa palavra inteira). Consulta: nome_norm like '%' || norm_busca('x') || '%'.
create index if not exists idx_candidatos_nome_trgm
  on public.candidatos using gin (nome_norm extensions.gin_trgm_ops);

-- Sexo: baixa cardinalidade — índice simples e parcial (ignora quem não informou)
create index if not exists idx_candidatos_sexo
  on public.candidatos (sexo) where sexo is not null;

-- Idade: faixa etária = faixa de nascimento_ref
create index if not exists idx_candidatos_nascimento
  on public.candidatos (nascimento_ref) where nascimento_ref is not null;

-- Cidade: por prefixo, sozinha, com estado, e combinada com a área sugerida (busca frequente da tela)
create index if not exists idx_candidatos_cidade_uf
  on public.candidatos (cidade_norm text_pattern_ops, uf);
create index if not exists idx_candidatos_cidade_area
  on public.candidatos (cidade_norm text_pattern_ops, area_sugerida);

-- Área / cargo / nível / status: filtros mais usados
create index if not exists idx_candidatos_status_area_nivel
  on public.candidatos (status_banco, area_sugerida, nivel_sugerido);
create index if not exists idx_candidatos_cargo
  on public.candidatos (cargo_sugerido) where cargo_sugerido is not null;

-- Ordem padrão da lista
create index if not exists idx_candidatos_entrada
  on public.candidatos (status_banco, data_entrada desc);

-- Fila de trabalho
create index if not exists idx_candidatos_revisao_manual
  on public.candidatos (data_entrada) where revisao_manual;
create index if not exists idx_candidatos_reanalise
  on public.candidatos (reanalise_solicitada_em) where reanalise_solicitada_em is not null;

-- Sanitização
create index if not exists idx_candidatos_sanitizacao
  on public.candidatos (ultima_movimentacao)
  where status_banco in ('ativo', 'inativo') and not retencao_permanente;

-- Detecção de duplicidade / reenvio
create index if not exists idx_candidatos_hash on public.candidatos (hash_identidade) where hash_identidade is not null;
create index if not exists idx_candidatos_telefone on public.candidatos (telefone_e164) where telefone_e164 is not null;
create index if not exists idx_candidatos_email on public.candidatos (lower(email)) where email is not null;

create index if not exists idx_analises_candidato on public.analises_ia (candidato_id, sequencia desc);

create index if not exists idx_candidaturas_candidato on public.candidaturas (candidato_id, recebido_em desc);
create index if not exists idx_candidaturas_avaliacao_pendente on public.candidaturas (updated_at) where avaliacao_pendente;

create index if not exists idx_curr_candidato on public.curriculos (candidato_id, recebido_em desc);
-- só um currículo "atual" por candidato e um e-mail (Message-ID) só vira currículo uma vez
create unique index if not exists uq_curriculo_atual on public.curriculos (candidato_id) where atual and candidato_id is not null;
create unique index if not exists uq_curriculo_message_id on public.curriculos (email_message_id) where email_message_id is not null;

-- ───────────────────────────────────────────────────────────────────────
--  Segurança: leitura para usuário ativo; escrita só por função (SECURITY DEFINER) ou pelo backend
-- ───────────────────────────────────────────────────────────────────────
alter table public.candidatos enable row level security;
alter table public.analises_ia enable row level security;

drop policy if exists candidatos_rh_select on public.candidatos;
create policy candidatos_rh_select on public.candidatos for select to authenticated using (fn_usuario_ativo());
drop policy if exists analises_ia_rh_select on public.analises_ia;
create policy analises_ia_rh_select on public.analises_ia for select to authenticated using (fn_usuario_ativo());

-- Sem insert/update/delete direto pelo painel: as regras (atribuir, devolver ao banco, sanitizar, expurgar)
-- vivem nas funções do passo 022/023 e o pipeline usa a service_role.
revoke all on public.candidatos, public.analises_ia from anon, authenticated;
grant select on public.candidatos, public.analises_ia to authenticated;
grant all on public.candidatos, public.analises_ia to service_role;
