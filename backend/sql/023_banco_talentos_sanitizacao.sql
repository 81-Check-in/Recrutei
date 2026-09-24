-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · PASSO 4 de 6: sanitização periódica com decisão do RH
--
--  O sistema NÃO apaga nada sozinho. A cada ciclo (2 meses, configurável) ele monta uma LISTA DE
--  SUGESTÕES — cada candidato com motivo e prioridade — e o RH decide: Manter, Inativar ou Excluir
--  definitivamente. Toda decisão fica registrada (quem, quando, o quê), inclusive "manter".
--
--  ATENÇÃO — muda uma regra de LGPD que hoje roda sozinha: a rotina diária deixa de inativar (2 meses
--  sem evento) e de expurgar os dados pessoais (4 meses inativo) automaticamente. No lugar entra este
--  fluxo, com o critério "prazo máximo no banco" (padrão 24 meses) gerando sugestão de prioridade alta.
--  Os parâmetros antigos (retencao_meses_ate_inativar/expurgar) são removidos.
--
--  Pode rodar de novo sem problema.
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  Parâmetros (editáveis por administrador em Configurações — nada fixo no código)
-- ───────────────────────────────────────────────────────────────────────
insert into public.configuracoes (chave, valor, descricao) values
  ('sanitizacao_intervalo_meses',       to_jsonb(2),
   'Banco de Talentos: de quantos em quantos meses o sistema gera a lista de sugestões de sanitização.'),
  ('sanitizacao_meses_sem_movimentacao', to_jsonb(6),
   'Sanitização: sugere candidato sem nenhuma movimentação (candidatura, novo currículo, contato, edição) há mais de N meses.'),
  ('sanitizacao_reprovacoes_max',       to_jsonb(3),
   'Sanitização: sugere candidato reprovado em N vagas diferentes sem nenhuma aprovação.'),
  ('sanitizacao_aderencia_min',         to_jsonb(40),
   'Sanitização: sugere candidato cuja MELHOR nota de aderência da IA às vagas ficou abaixo deste valor (0–100).'),
  ('sanitizacao_confianca_min',         to_jsonb(50),
   'Sanitização: sugere candidato cuja análise da IA não classificou área/cargo/nível com confiança mínima (0–100).'),
  ('sanitizacao_detectar_duplicidade',  to_jsonb(true),
   'Sanitização: sugere o cadastro mais antigo quando há outro do mesmo candidato (mesmo hash de identidade, ou mesmo telefone/e-mail com nome parecido).'),
  ('sanitizacao_retencao_maxima_meses', to_jsonb(24),
   'LGPD: prazo máximo (meses) que um candidato fica no banco sem consentimento registrado. Vencido, entra na sanitização com prioridade alta.'),
  ('sanitizacao_adiar_meses',           to_jsonb(6),
   'Sanitização: ao MANTER um candidato, não sugerir de novo por N meses.'),
  ('sanitizacao_pesos',
   '{"sem_movimentacao":2,"reprovacoes":2,"baixa_aderencia":1,"dados_incompletos":2,"duplicidade":3,"prazo_retencao":4,"limite_alta":4,"limite_media":2}'::jsonb,
   'Sanitização: pontos de cada motivo. A soma define a prioridade: alta se ≥ limite_alta, média se ≥ limite_media, senão baixa.'),
  ('sanitizacao_emails_aviso',          to_jsonb(''::text),
   'Sanitização: e-mails (separados por vírgula) que recebem o aviso "há sugestões pendentes". Vazio = só o aviso dentro do sistema.'),
  ('ia_confianca_minima',               to_jsonb(60),
   'Análise da IA: abaixo desta confiança (0–100) o candidato é marcado como "revisão manual necessária".')
on conflict (chave) do nothing;

-- A retenção automática por tempo acabou (ver o aviso no topo)
delete from public.configuracoes where chave in ('retencao_meses_ate_inativar', 'retencao_meses_ate_expurgar');

-- Leitura tolerante: valor vazio, texto ou inválido cai no padrão em vez de derrubar a rotina
create or replace function public.fn_config_numero(p_chave text, p_padrao numeric)
returns numeric
language plpgsql stable security definer
set search_path to 'public'
as $$
declare v numeric;
begin
  select nullif(btrim(valor #>> '{}'), '')::numeric into v from public.configuracoes where chave = p_chave;
  return coalesce(v, p_padrao);
exception when others then
  return p_padrao;
end $$;

create or replace function public.fn_sanitizacao_parametros()
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'intervalo_meses',          public.fn_config_numero('sanitizacao_intervalo_meses', 2)::int,
    'meses_sem_movimentacao',   public.fn_config_numero('sanitizacao_meses_sem_movimentacao', 6)::int,
    'reprovacoes_max',          public.fn_config_numero('sanitizacao_reprovacoes_max', 3)::int,
    'aderencia_min',            public.fn_config_numero('sanitizacao_aderencia_min', 40)::int,
    'confianca_min',            public.fn_config_numero('sanitizacao_confianca_min', 50)::int,
    'detectar_duplicidade',     coalesce((select (valor #>> '{}')::boolean from public.configuracoes
                                           where chave = 'sanitizacao_detectar_duplicidade'), true),
    'retencao_maxima_meses',    public.fn_config_numero('sanitizacao_retencao_maxima_meses', 24)::int,
    'adiar_meses',              public.fn_config_numero('sanitizacao_adiar_meses', 6)::int,
    'pesos', '{"sem_movimentacao":2,"reprovacoes":2,"baixa_aderencia":1,"dados_incompletos":2,"duplicidade":3,"prazo_retencao":4,"limite_alta":4,"limite_media":2}'::jsonb
             || coalesce((select case when jsonb_typeof(valor) = 'object' then valor end
                            from public.configuracoes where chave = 'sanitizacao_pesos'), '{}'::jsonb)
  );
$$;

-- ───────────────────────────────────────────────────────────────────────
--  Tabelas
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.sanitizacao_ciclos (
  id              uuid primary key default gen_random_uuid(),
  gerada_em       timestamptz not null default now(),
  origem          text not null check (origem in ('job', 'manual')),
  gerada_por      uuid references public.usuarios(id) on delete set null,
  parametros      jsonb not null,                       -- foto dos parâmetros usados neste ciclo
  total_sugeridas integer not null default 0,
  por_prioridade  jsonb not null default '{}'::jsonb,
  notificada_em   timestamptz                           -- quando o e-mail de aviso saiu
);

create table if not exists public.sanitizacao_sugestoes (
  id                  uuid primary key default gen_random_uuid(),
  ciclo_id            uuid not null references public.sanitizacao_ciclos(id) on delete cascade,
  -- set null: a trilha de decisão sobrevive mesmo que o cadastro seja apagado à força
  candidato_id        uuid references public.candidatos(id) on delete set null,
  motivos             text[] not null,                  -- códigos: sem_movimentacao, reprovacoes, baixa_aderencia, dados_incompletos, duplicidade, prazo_retencao
  motivo_texto        text not null,                    -- texto para o RH ler (sem dados pessoais)
  pontos              smallint not null,
  prioridade          text not null check (prioridade in ('alta', 'media', 'baixa')),
  ultima_movimentacao timestamptz,
  status              text not null default 'pendente'
                      check (status in ('pendente', 'mantido', 'inativado', 'excluido', 'expirada')),
  decidido_por        uuid references public.usuarios(id) on delete set null,
  decidido_em         timestamptz,
  observacao          text,
  adiada_ate          timestamptz,                      -- "mantido": não sugerir de novo antes disso
  created_at          timestamptz not null default now(),
  constraint chk_sugestao_decisao_coerente check (
    (status = 'pendente' and decidido_em is null) or (status <> 'pendente' and decidido_em is not null)
  )
);
-- um candidato não fica com duas sugestões pendentes ao mesmo tempo
create unique index if not exists uq_sugestao_pendente
  on public.sanitizacao_sugestoes (candidato_id) where status = 'pendente';
create index if not exists idx_sugestoes_ciclo on public.sanitizacao_sugestoes (ciclo_id, prioridade);
create index if not exists idx_sugestoes_fila on public.sanitizacao_sugestoes (status, prioridade, pontos desc);
create index if not exists idx_sugestoes_candidato on public.sanitizacao_sugestoes (candidato_id) where candidato_id is not null;

-- Arquivos de currículo cujo dado já foi apagado do banco e ainda falta remover do Storage.
-- O banco não consegue apagar o arquivo; a rotina do backend faz isso e marca aqui.
create table if not exists public.arquivos_para_remover (
  id             uuid primary key default gen_random_uuid(),
  storage_path   text not null unique,
  enfileirado_em timestamptz not null default now(),
  removido_em    timestamptz
);
create index if not exists idx_arquivos_pendentes on public.arquivos_para_remover (enfileirado_em) where removido_em is null;

alter table public.sanitizacao_ciclos enable row level security;
alter table public.sanitizacao_sugestoes enable row level security;
alter table public.arquivos_para_remover enable row level security;

drop policy if exists sanitizacao_ciclos_rh_select on public.sanitizacao_ciclos;
create policy sanitizacao_ciclos_rh_select on public.sanitizacao_ciclos for select to authenticated using (fn_usuario_ativo());
drop policy if exists sanitizacao_sugestoes_rh_select on public.sanitizacao_sugestoes;
create policy sanitizacao_sugestoes_rh_select on public.sanitizacao_sugestoes for select to authenticated using (fn_usuario_ativo());

revoke all on public.sanitizacao_ciclos, public.sanitizacao_sugestoes, public.arquivos_para_remover from anon, authenticated;
grant select on public.sanitizacao_ciclos, public.sanitizacao_sugestoes to authenticated;
grant all on public.sanitizacao_ciclos, public.sanitizacao_sugestoes, public.arquivos_para_remover to service_role;

-- ───────────────────────────────────────────────────────────────────────
--  Expurgo (apagar dados pessoais mantendo o esqueleto para métricas e detecção de reenvio)
--  Faz o mesmo que o expurgo antigo e um pouco mais: também limpa os textos livres da IA e das
--  entrevistas, que podem carregar dados do candidato.
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_expurgar_candidato(p_candidato_id uuid, p_motivo text)
returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_arquivos integer;
begin
  perform 1 from public.candidatos where id = p_candidato_id and status_banco <> 'expurgado' for update;
  if not found then
    return 0;                                   -- já expurgado (ou inexistente): nada a fazer
  end if;

  insert into public.arquivos_para_remover (storage_path)
  select distinct storage_path from public.curriculos
   where candidato_id = p_candidato_id and storage_path is not null
  on conflict (storage_path) do nothing;
  get diagnostics v_arquivos = row_count;

  update public.curriculos
     set texto_extraido = null, storage_path = null, nome_arquivo = null,
         email_message_id = null, email_assunto = null
   where candidato_id = p_candidato_id;

  delete from public.analises_ia where candidato_id = p_candidato_id;

  update public.avaliacoes
     set resumo_nota = null, resumo_ia = null,
         pontos_fortes = '{}', lacunas = '{}', requisitos_faltantes = '{}'
   where candidatura_id in (select id from public.candidaturas where candidato_id = p_candidato_id);

  update public.entrevistas
     set observacoes = null, mensagem_enviada = null
   where candidatura_id in (select id from public.candidaturas where candidato_id = p_candidato_id);

  update public.candidaturas
     set dados_pessoais = null, email_assunto = null, email_message_id = null, observacao_atribuicao = null,
         status_registro = 'expurgado', expurgado_em = now(), inativado_em = coalesce(inativado_em, now())
   where candidato_id = p_candidato_id;

  -- sugestões que ainda estavam pendentes deste candidato perdem o sentido
  update public.sanitizacao_sugestoes
     set status = 'expirada', decidido_em = now(), observacao = 'Dados do candidato excluídos'
   where candidato_id = p_candidato_id and status = 'pendente';

  -- só o hash de identidade fica (para reconhecer um reenvio futuro), além de datas e situação
  update public.candidatos
     set nome = null, sexo = null, data_nascimento = null, idade_informada = null, idade_informada_em = null,
         cidade = null, uf = null, telefone = null, telefone_e164 = null, email = null,
         escolaridade = null, anos_experiencia = null, cnh = null,
         area_sugerida = null, cargo_sugerido = null, nivel_sugerido = null, ia_confianca = null,
         revisao_manual = false, analise_atual_id = null, reanalise_solicitada_em = null,
         consentimento_em = null, consentimento_origem = null, ultimo_contato_em = null,
         sanitizacao_adiada_ate = null,
         status_banco = 'expurgado', expurgado_em = now(), inativado_em = coalesce(inativado_em, now()),
         motivo_inativacao = 'dados excluídos'
   where id = p_candidato_id;

  perform public.fn_registra_auditoria(
    'exclusao_manual_lgpd', 'candidatos', p_candidato_id,
    null, jsonb_build_object('status_banco', 'expurgado', 'arquivos_a_remover', v_arquivos),
    coalesce(p_motivo, 'Exclusão de dados'));
  return v_arquivos;
end $$;

-- Pedido do titular (LGPD art. 18): administrador apaga os dados de um candidato a qualquer momento.
-- Se ele estava em processo, as candidaturas abertas são canceladas antes.
create or replace function public.excluir_dados_candidato(p_candidato_id uuid, p_motivo text default null)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  perform public.fn_exige_admin();
  update public.entrevistas set resultado = 'cancelada'
   where resultado in ('agendada', 'remarcada')
     and candidatura_id in (select id from public.candidaturas where candidato_id = p_candidato_id and encerrada_em is null);
  update public.candidaturas
     set status = 'cancelado', resultado_final = 'Dados excluídos a pedido do titular'
   where candidato_id = p_candidato_id and encerrada_em is null;
  perform public.fn_expurgar_candidato(p_candidato_id,
    coalesce(nullif(btrim(p_motivo), ''), 'Solicitação do titular (LGPD art. 18)'));
end $$;

-- Compatibilidade: a função antiga (por candidatura) continua existindo, agora apagando o candidato inteiro
create or replace function public.fn_excluir_dados_candidato(
  p_candidatura_id uuid, p_motivo text default 'Solicitação do titular (LGPD Art. 18)')
returns text
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_candidato uuid;
begin
  select candidato_id into v_candidato from public.candidaturas where id = p_candidatura_id;
  if v_candidato is null then
    raise exception 'Candidatura não encontrada ou sem candidato vinculado.';
  end if;
  perform public.fn_expurgar_candidato(v_candidato, p_motivo);
  return null;                                   -- os caminhos vão para arquivos_para_remover
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Cálculo das sugestões — quem entra na lista e por quê
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_sanitizacao_avaliar(p_params jsonb)
returns table (
  candidato_id        uuid,
  motivos             text[],
  motivo_texto        text,
  pontos              integer,
  prioridade          text,
  ultima_movimentacao timestamptz
)
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_mov     int     := (p_params ->> 'meses_sem_movimentacao')::int;
  v_reprov  int     := (p_params ->> 'reprovacoes_max')::int;
  v_ader    int     := (p_params ->> 'aderencia_min')::int;
  v_conf    int     := (p_params ->> 'confianca_min')::int;
  v_dup     boolean := (p_params ->> 'detectar_duplicidade')::boolean;
  v_ret     int     := (p_params ->> 'retencao_maxima_meses')::int;
  w         jsonb   := p_params -> 'pesos';
begin
  return query
  with base as (
    select c.*
      from public.candidatos c
     where c.status_banco in ('ativo', 'inativo')
       and not c.retencao_permanente
       and (c.sanitizacao_adiada_ate is null or c.sanitizacao_adiada_ate <= now())
       and not exists (select 1 from public.sanitizacao_sugestoes s
                        where s.candidato_id = c.id and s.status = 'pendente')
  ),
  hist as (
    select b.id,
           count(distinct ca.vaga_id) filter (where ca.status = 'reprovado')             as vagas_reprovado,
           coalesce(bool_or(ca.status in ('aprovado', 'contratado')), false)              as tem_aprovacao
      from base b left join public.candidaturas ca on ca.candidato_id = b.id
     group by b.id
  ),
  notas as (
    select b.id, max(av.nota) as nota_max
      from base b
      join public.candidaturas ca on ca.candidato_id = b.id
      join public.avaliacoes av on av.candidatura_id = ca.id
     group by b.id
  ),
  sinais as (
    select b.id,
           b.ultima_movimentacao                                                          as ult_mov,
           (b.ultima_movimentacao < now() - make_interval(months => v_mov))               as f_mov,
           (coalesce(h.vagas_reprovado, 0) >= v_reprov and not h.tem_aprovacao)           as f_reprov,
           (n.nota_max is not null and n.nota_max < v_ader)                               as f_ader,
           -- análise ainda pendente não conta como "dado incompleto"
           (b.reanalise_solicitada_em is null and (
                b.analise_atual_id is null or b.revisao_manual
             or b.area_sugerida is null or b.cargo_sugerido is null or b.nivel_sugerido is null
             or coalesce(b.ia_confianca, 0) < v_conf))                                    as f_dados,
           -- só o cadastro MAIS ANTIGO do par é sugerido (o mais recente fica). Um EXISTS por critério, cada
           -- um com o seu índice (hash, telefone, e-mail): um único EXISTS com OR obrigaria a varrer a tabela.
           -- Telefone/e-mail iguais só valem com nome parecido (família ou agência dividem contato).
           (v_dup and (
              (b.hash_identidade is not null and exists (
                 select 1 from public.candidatos d
                  where d.hash_identidade = b.hash_identidade and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)))
              or (b.telefone_e164 is not null and exists (
                 select 1 from public.candidatos d
                  where d.telefone_e164 = b.telefone_e164 and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)
                    and extensions.similarity(d.nome_norm, b.nome_norm) >= 0.5))
              or (b.email is not null and exists (
                 select 1 from public.candidatos d
                  where lower(d.email) = lower(b.email) and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)
                    and extensions.similarity(d.nome_norm, b.nome_norm) >= 0.5))))          as f_dup,
           (coalesce(b.consentimento_em, b.data_entrada) < now() - make_interval(months => v_ret)) as f_prazo,
           coalesce(h.vagas_reprovado, 0)                                                 as vagas_reprovado,
           n.nota_max,
           b.consentimento_em is null                                                     as sem_consentimento,
           b.data_entrada
      from base b
      join hist h on h.id = b.id
      left join notas n on n.id = b.id
  ),
  pont as (
    select s.*,
           ( (s.f_mov    ::int * (w ->> 'sem_movimentacao')::int)
           + (s.f_reprov ::int * (w ->> 'reprovacoes')::int)
           + (s.f_ader   ::int * (w ->> 'baixa_aderencia')::int)
           + (s.f_dados  ::int * (w ->> 'dados_incompletos')::int)
           + (s.f_dup    ::int * (w ->> 'duplicidade')::int)
           + (s.f_prazo  ::int * (w ->> 'prazo_retencao')::int) ) as total
      from sinais s
  )
  select p.id,
         array_remove(array[
           case when p.f_mov    then 'sem_movimentacao'   end,
           case when p.f_reprov then 'reprovacoes'        end,
           case when p.f_ader   then 'baixa_aderencia'    end,
           case when p.f_dados  then 'dados_incompletos'  end,
           case when p.f_dup    then 'duplicidade'        end,
           case when p.f_prazo  then 'prazo_retencao'     end], null),
         array_to_string(array_remove(array[
           case when p.f_mov then format('Sem movimentação há %s meses (limite: %s)',
                  (extract(year from age(now(), p.ult_mov)) * 12 + extract(month from age(now(), p.ult_mov)))::int, v_mov) end,
           case when p.f_reprov then format('Reprovado em %s vagas diferentes sem nenhuma aprovação', p.vagas_reprovado) end,
           case when p.f_ader then format('Melhor aderência da IA às vagas: %s%% (mínimo: %s%%)', p.nota_max, v_ader) end,
           case when p.f_dados then 'Currículo sem classificação confiável da IA (área, cargo ou nível)' end,
           case when p.f_dup then 'Possível cadastro duplicado (há outro mais recente do mesmo candidato)' end,
           case when p.f_prazo then format('No banco há mais de %s meses%s',
                  v_ret, case when p.sem_consentimento then ' sem consentimento registrado' else ' desde o último consentimento' end) end
         ], null), '; '),
         p.total,
         case when p.total >= (w ->> 'limite_alta')::int  then 'alta'
              when p.total >= (w ->> 'limite_media')::int then 'media'
              else 'baixa' end,
         p.ult_mov
    from pont p
   where p.f_mov or p.f_reprov or p.f_ader or p.f_dados or p.f_dup or p.f_prazo;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Geração da lista (job do backend, ou administrador pelo painel)
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_gerar_sugestoes_sanitizacao(
  p_origem text default 'manual', p_forcar boolean default false)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_params  jsonb;
  v_ultima  timestamptz;
  v_proxima timestamptz;
  v_ciclo   uuid;
  v_total   integer;
  v_por     jsonb;
begin
  -- o job usa a service_role (sem usuário); pelo painel só administrador
  if auth.uid() is not null then
    perform public.fn_exige_admin();
  end if;
  if p_origem not in ('job', 'manual') then
    raise exception 'Origem inválida.';
  end if;

  v_params := public.fn_sanitizacao_parametros();
  select max(gerada_em) into v_ultima from public.sanitizacao_ciclos;
  v_proxima := v_ultima + make_interval(months => (v_params ->> 'intervalo_meses')::int);
  if not p_forcar and v_ultima is not null and v_proxima > now() then
    return jsonb_build_object('gerada', false, 'motivo', 'intervalo ainda não venceu', 'proxima_em', v_proxima);
  end if;

  -- pendências de quem já não pode ser sanitizado (entrou em processo, foi excluído) saem da fila
  update public.sanitizacao_sugestoes s
     set status = 'expirada', decidido_em = now(), observacao = 'Candidato entrou em processo ou foi excluído'
    from public.candidatos c
   where c.id = s.candidato_id and s.status = 'pendente' and c.status_banco in ('em_processo', 'expurgado');

  insert into public.sanitizacao_ciclos (origem, gerada_por, parametros)
  values (p_origem, auth.uid(), v_params)
  returning id into v_ciclo;

  insert into public.sanitizacao_sugestoes
         (ciclo_id, candidato_id, motivos, motivo_texto, pontos, prioridade, ultima_movimentacao)
  select v_ciclo, a.candidato_id, a.motivos, a.motivo_texto, a.pontos, a.prioridade, a.ultima_movimentacao
    from public.fn_sanitizacao_avaliar(v_params) a;
  get diagnostics v_total = row_count;

  select coalesce(jsonb_object_agg(prioridade, n), '{}'::jsonb) into v_por
    from (select prioridade, count(*) n from public.sanitizacao_sugestoes where ciclo_id = v_ciclo group by 1) x;

  update public.sanitizacao_ciclos set total_sugeridas = v_total, por_prioridade = v_por where id = v_ciclo;

  perform public.fn_registra_auditoria(
    'sanitizacao_geracao', 'sanitizacao_ciclos', v_ciclo, null,
    jsonb_build_object('origem', p_origem, 'total', v_total, 'por_prioridade', v_por),
    'Lista de sugestões de sanitização gerada');

  return jsonb_build_object('gerada', true, 'ciclo_id', v_ciclo, 'total', v_total, 'por_prioridade', v_por);
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Decisão do RH — nada acontece sem esta chamada explícita
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_sanitizacao_aplicar(
  p_sugestao_id uuid, p_decisao text, p_observacao text, p_adiar_meses integer,
  p_usuario uuid, p_admin boolean)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v     public.sanitizacao_sugestoes%rowtype;
  v_st  public.status_banco_talentos;
  v_ate timestamptz;
  v_obs text := nullif(btrim(p_observacao), '');
begin
  if p_decisao not in ('manter', 'inativar', 'excluir') then
    raise exception 'Decisão inválida: use manter, inativar ou excluir.';
  end if;
  if p_decisao = 'excluir' and not p_admin then
    raise exception 'Somente o administrador pode excluir definitivamente.';
  end if;

  select * into v from public.sanitizacao_sugestoes where id = p_sugestao_id for update;
  if not found then
    raise exception 'Sugestão não encontrada.';
  end if;
  if v.status <> 'pendente' then
    raise exception 'Esta sugestão já foi decidida.';
  end if;
  if v.candidato_id is null then
    raise exception 'O cadastro deste candidato não existe mais.';
  end if;

  select status_banco into v_st from public.candidatos where id = v.candidato_id for update;
  if p_decisao <> 'manter' then
    if v_st = 'em_processo' then
      raise exception 'O candidato entrou em processo seletivo depois que a sugestão foi gerada.';
    elsif v_st = 'expurgado' then
      raise exception 'Os dados deste candidato já foram excluídos.';
    end if;
  end if;

  if p_decisao = 'manter' then
    v_ate := now() + make_interval(months => coalesce(p_adiar_meses, public.fn_config_numero('sanitizacao_adiar_meses', 6)::int));
    update public.candidatos set sanitizacao_adiada_ate = v_ate where id = v.candidato_id;
    update public.sanitizacao_sugestoes
       set status = 'mantido', adiada_ate = v_ate, decidido_por = p_usuario, decidido_em = now(), observacao = v_obs
     where id = v.id;
  elsif p_decisao = 'inativar' then
    if v_st <> 'inativo' then
      update public.candidatos
         set status_banco = 'inativo', inativado_em = now(), motivo_inativacao = 'sanitização',
             ultima_movimentacao = now()
       where id = v.candidato_id;
    end if;
    update public.sanitizacao_sugestoes
       set status = 'inativado', decidido_por = p_usuario, decidido_em = now(), observacao = v_obs
     where id = v.id;
  else
    -- a sugestão é fechada ANTES do expurgo (o expurgo expira as demais pendências do candidato)
    update public.sanitizacao_sugestoes
       set status = 'excluido', decidido_por = p_usuario, decidido_em = now(), observacao = v_obs
     where id = v.id;
    perform public.fn_expurgar_candidato(v.candidato_id, 'Sanitização: ' || v.motivo_texto);
  end if;

  perform public.fn_registra_auditoria(
    'sanitizacao_decisao', 'candidatos', v.candidato_id, null,
    jsonb_build_object('decisao', p_decisao, 'sugestao_id', v.id, 'prioridade', v.prioridade,
                       'motivos', to_jsonb(v.motivos), 'adiada_ate', v_ate),
    'Sanitização: ' || p_decisao);
end $$;

create or replace function public.sanitizacao_decidir(
  p_sugestao_id uuid, p_decisao text, p_observacao text default null, p_adiar_meses integer default null)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  perform public.fn_exige_usuario_ativo();
  if p_adiar_meses is not null and p_adiar_meses not between 1 and 60 then
    raise exception 'O prazo para adiar deve ficar entre 1 e 60 meses.';
  end if;
  perform public.fn_sanitizacao_aplicar(p_sugestao_id, p_decisao, p_observacao, p_adiar_meses,
                                        auth.uid(), public.fn_usuario_admin());
end $$;

-- Em lote (ex.: "todas as de prioridade alta"). Cada item é decidido e auditado sozinho; um que falha
-- (já decidido, candidato entrou em processo…) não desfaz os outros — vem na lista de falhas.
create or replace function public.sanitizacao_decidir_lote(
  p_sugestao_ids uuid[], p_decisao text, p_observacao text default null, p_adiar_meses integer default null)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_id     uuid;
  v_ok     integer := 0;
  v_falhas jsonb := '[]'::jsonb;
  v_admin  boolean;
begin
  perform public.fn_exige_usuario_ativo();
  if p_decisao = 'excluir' then
    perform public.fn_exige_admin();
  end if;
  if coalesce(cardinality(p_sugestao_ids), 0) = 0 then
    raise exception 'Nenhuma sugestão selecionada.';
  end if;
  if cardinality(p_sugestao_ids) > 500 then
    raise exception 'No máximo 500 sugestões por vez.';
  end if;
  if p_adiar_meses is not null and p_adiar_meses not between 1 and 60 then
    raise exception 'O prazo para adiar deve ficar entre 1 e 60 meses.';
  end if;

  v_admin := public.fn_usuario_admin();
  foreach v_id in array p_sugestao_ids loop
    begin
      perform public.fn_sanitizacao_aplicar(v_id, p_decisao, p_observacao, p_adiar_meses, auth.uid(), v_admin);
      v_ok := v_ok + 1;
    exception when others then
      v_falhas := v_falhas || jsonb_build_object('id', v_id, 'erro', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('processadas', v_ok, 'falhas', v_falhas);
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Manutenção diária: sem inativar/expurgar sozinha. Só prepara o que o backend precisa.
-- ───────────────────────────────────────────────────────────────────────
drop function if exists public.fn_inativar_candidaturas_vencidas();
drop function if exists public.fn_expurgar_candidaturas_inativas();

create or replace function public.fn_manutencao_diaria()
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_proxima date;
  v_nome    text;
begin
  -- Cria a partição do mês seguinte da auditoria JÁ COM RLS
  v_proxima := (date_trunc('month', current_date) + interval '2 month')::date;
  v_nome    := 'logs_auditoria_' || to_char(v_proxima, 'YYYY_MM');

  if not exists (select 1 from pg_class where relname = v_nome) then
    execute format(
      'create table %I partition of logs_auditoria for values from (%L) to (%L)',
      v_nome, v_proxima, (v_proxima + interval '1 month')::date);
    execute format('alter table %I enable row level security', v_nome);
    execute format('alter table %I force row level security', v_nome);
    execute format(
      'create policy %1$s_leitura on %1$I for select to authenticated using (fn_usuario_ativo())', v_nome);
  end if;

  return jsonb_build_object(
    'executado_em', now(),
    'arquivos_para_remover',
      coalesce((select jsonb_agg(storage_path order by enfileirado_em)
                  from public.arquivos_para_remover where removido_em is null), '[]'::jsonb),
    'sanitizacao_pendentes',
      (select count(*) from public.sanitizacao_sugestoes where status = 'pendente'));
end $$;

create or replace function public.fn_marcar_arquivos_removidos(p_caminhos text[])
returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare n integer;
begin
  update public.arquivos_para_remover set removido_em = now()
   where storage_path = any (p_caminhos) and removido_em is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Privilégios de execução
-- ───────────────────────────────────────────────────────────────────────
revoke execute on function
  public.fn_config_numero(text, numeric),
  public.fn_sanitizacao_parametros(),
  public.fn_expurgar_candidato(uuid, text),
  public.excluir_dados_candidato(uuid, text),
  public.fn_excluir_dados_candidato(uuid, text),
  public.fn_sanitizacao_avaliar(jsonb),
  public.fn_gerar_sugestoes_sanitizacao(text, boolean),
  public.fn_sanitizacao_aplicar(uuid, text, text, integer, uuid, boolean),
  public.sanitizacao_decidir(uuid, text, text, integer),
  public.sanitizacao_decidir_lote(uuid[], text, text, integer),
  public.fn_manutencao_diaria(),
  public.fn_marcar_arquivos_removidos(text[])
from public, anon, authenticated;

-- O painel chama estas; as demais são do banco e do backend
grant execute on function
  public.fn_gerar_sugestoes_sanitizacao(text, boolean),   -- só administrador (a função confere)
  public.excluir_dados_candidato(uuid, text),             -- só administrador (a função confere)
  public.sanitizacao_decidir(uuid, text, text, integer),
  public.sanitizacao_decidir_lote(uuid[], text, text, integer)
to authenticated;

grant execute on all functions in schema public to service_role;
