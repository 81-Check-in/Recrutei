-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · ETAPA 1: reincidência, lista negra, descarte por vaga
--
--  Rodar depois da 027. Pode rodar de novo sem problema. Não muda dados existentes.
--
--  1) Reincidência — o mesmo currículo não é lido de novo. O backend reconhece o arquivo pela impressão digital
--     (curriculos.arquivo_hash) e a pessoa por nome + telefone; só relê depois de 30 dias E se o candidato foi
--     sanitizado (regra em pipeline.py). Aqui entra só a coluna e o índice.
--  2) Lista negra de e-mails — o RH bloqueia um endereço (ou o candidato inteiro) e o sistema deixa de receber
--     qualquer coisa dele. Reaproveita remetentes.bloqueado, que o pipeline já respeita.
--  3) Descarte por vaga — quem foi reprovado/descartado numa vaga não volta a ela; só em vaga nova.
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  1) Impressão digital do arquivo do currículo
--     HMAC do conteúdo com a chave de identidade (a mesma do hash_identidade), calculado no backend.
--     Sobrevive à exclusão de dados (o expurgo só limpa texto, caminho e nome do arquivo): é assim que um
--     reenvio do mesmo arquivo é reconhecido mesmo depois da sanitização.
-- ───────────────────────────────────────────────────────────────────────
alter table public.curriculos add column if not exists arquivo_hash text;
create index if not exists idx_curriculos_arquivo_hash on public.curriculos (arquivo_hash) where arquivo_hash is not null;

-- ───────────────────────────────────────────────────────────────────────
--  2) Lista negra
-- ───────────────────────────────────────────────────────────────────────
alter table public.candidatos
  add column if not exists lista_negra        boolean not null default false,
  add column if not exists lista_negra_em     timestamptz,
  add column if not exists lista_negra_por    uuid references public.usuarios(id) on delete set null,
  add column if not exists lista_negra_motivo text;
create index if not exists idx_candidatos_lista_negra_por on public.candidatos (lista_negra_por) where lista_negra_por is not null;

-- Interna: põe UM candidato na lista negra (cancela as candidaturas abertas e as entrevistas marcadas, marca a lista
-- negra, inativa e mantém com retenção permanente — assim a sanitização não sugere apagá-lo: a lista existe justamente
-- para reconhecê-lo se voltar). Devolve os endereços ligados a ele (o do currículo e os de quem enviou cada currículo),
-- para o chamador bloqueá-los. Nunca apaga nada; excluir os dados continua possível e o bloqueio do e-mail permanece.
create or replace function public.fn_lista_negra_candidato(p_candidato_id uuid, p_motivo text)
returns text[]
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_cand   public.candidatos%rowtype;
  v_emails text[];
begin
  select * into v_cand from public.candidatos where id = p_candidato_id for update;
  if not found then
    return '{}'::text[];
  end if;

  select array_agg(distinct e) into v_emails
    from unnest(
           array(select lower(r.email::text) from public.curriculos cu
                   join public.remetentes r on r.id = cu.remetente_id where cu.candidato_id = p_candidato_id)
           || case when v_cand.email is not null then array[lower(btrim(v_cand.email))] else '{}'::text[] end) e
   where e is not null and e <> '';

  update public.entrevistas set resultado = 'cancelada'
   where resultado in ('agendada', 'remarcada')
     and candidatura_id in (select id from public.candidaturas where candidato_id = p_candidato_id and encerrada_em is null);
  update public.candidaturas
     set status = 'cancelado', resultado_final = 'Candidato na lista negra'
   where candidato_id = p_candidato_id and encerrada_em is null;

  update public.candidatos
     set lista_negra         = true,
         lista_negra_em      = coalesce(lista_negra_em, now()),
         lista_negra_por     = coalesce(lista_negra_por, auth.uid()),
         lista_negra_motivo  = p_motivo,
         retencao_permanente = true,
         status_banco        = case when status_banco = 'expurgado' then status_banco else 'inativo' end,
         inativado_em        = coalesce(inativado_em, now()),
         motivo_inativacao   = 'Lista negra',
         ultima_movimentacao = now()
   where id = p_candidato_id;

  return coalesce(v_emails, '{}'::text[]);
end $$;

-- Bloqueia um e-mail (o pipeline passa a ignorar o remetente e os currículos que o trouxerem). Quem já está no banco
-- com esse e-mail — ou o candidato indicado em p_candidato_id — vai junto para a lista negra, com todos os endereços
-- ligados a ele: bloquear só o endereço deixaria a pessoa disponível para atribuição.
create or replace function public.bloquear_email(p_email text, p_motivo text, p_candidato_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_motivo text := nullif(btrim(p_motivo), '');
  v_email  text := lower(nullif(btrim(p_email), ''));
  v_emails text[];
  v_ids    uuid[] := '{}';
  v_id     uuid;
  v_rem    uuid;
begin
  perform public.fn_exige_usuario_ativo();
  if v_motivo is null then
    raise exception 'Informe o motivo do bloqueio.';
  end if;

  if p_candidato_id is not null then
    if not exists (select 1 from public.candidatos where id = p_candidato_id) then
      raise exception 'Candidato não encontrado.';
    end if;
    v_email := coalesce(v_email, (select lower(nullif(btrim(email), '')) from public.candidatos where id = p_candidato_id));
    v_ids := array[p_candidato_id];
  end if;
  if v_email is null or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Informe um e-mail válido.';
  end if;

  v_emails := array[v_email];
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_ids
    from unnest(v_ids || array(select id from public.candidatos where lower(email) = v_email)) x;
  foreach v_id in array v_ids loop
    v_emails := v_emails || public.fn_lista_negra_candidato(v_id, v_motivo);
  end loop;
  select array_agg(distinct e) into v_emails from unnest(v_emails) e where e is not null and e <> '';

  insert into public.remetentes (email, bloqueado, bloqueado_em, bloqueado_por, motivo_bloqueio)
  select e, true, now(), auth.uid(), v_motivo from unnest(v_emails) e
  on conflict (email) do update
     set bloqueado       = true,
         bloqueado_em    = coalesce(public.remetentes.bloqueado_em, now()),
         bloqueado_por   = case when public.remetentes.bloqueado then public.remetentes.bloqueado_por else auth.uid() end,
         motivo_bloqueio = case when public.remetentes.bloqueado then public.remetentes.motivo_bloqueio else excluded.motivo_bloqueio end;
  select id into v_rem from public.remetentes where email = v_email;

  perform public.fn_registra_auditoria(
    'lista_negra_bloqueio', case when cardinality(v_ids) = 0 then 'remetentes' else 'candidatos' end,
    coalesce(v_ids[1], v_rem), null,
    jsonb_build_object('enderecos', cardinality(v_emails), 'candidatos', cardinality(v_ids)),
    'Bloqueio na lista negra. Motivo: ' || v_motivo);

  return jsonb_build_object('enderecos_bloqueados', cardinality(v_emails), 'candidatos_inativados', cardinality(v_ids));
end $$;

-- Tira da lista negra. Com p_candidato_id libera o candidato e todos os endereços dele; ele continua INATIVO (o RH
-- decide se o reativa). Sem candidato, libera só o endereço (e o candidato cujo e-mail é esse).
create or replace function public.desbloquear_email(p_email text, p_candidato_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_email  text := lower(nullif(btrim(p_email), ''));
  v_cand   public.candidatos%rowtype;
  v_emails text[];
  v_n      int;
begin
  perform public.fn_exige_usuario_ativo();

  if p_candidato_id is not null then
    select * into v_cand from public.candidatos where id = p_candidato_id for update;
    if not found then
      raise exception 'Candidato não encontrado.';
    end if;
    v_email := coalesce(v_email, lower(nullif(btrim(v_cand.email), '')));
  end if;
  if v_email is null then
    raise exception 'Informe o e-mail.';
  end if;

  v_emails := array[v_email];
  if p_candidato_id is not null then
    select array_agg(distinct e) into v_emails
      from unnest(
             v_emails
             || array(select lower(r.email::text) from public.curriculos cu
                        join public.remetentes r on r.id = cu.remetente_id where cu.candidato_id = p_candidato_id)
             || case when v_cand.email is not null then array[lower(btrim(v_cand.email))] else '{}'::text[] end) e
     where e is not null and e <> '';
  end if;

  update public.remetentes
     set bloqueado = false, bloqueado_em = null, bloqueado_por = null, motivo_bloqueio = null
   where bloqueado and lower(email::text) = any (v_emails);
  get diagnostics v_n = row_count;
  if v_n = 0 and p_candidato_id is null then
    raise exception 'Este e-mail não está na lista negra.';
  end if;

  update public.candidatos
     set lista_negra = false, lista_negra_em = null, lista_negra_por = null, lista_negra_motivo = null,
         ultima_movimentacao = now()
   where lista_negra
     and (id = p_candidato_id or lower(email) = any (v_emails));

  perform public.fn_registra_auditoria(
    'lista_negra_desbloqueio', case when p_candidato_id is null then 'remetentes' else 'candidatos' end,
    coalesce(p_candidato_id, (select id from public.remetentes where lower(email::text) = v_email limit 1)),
    null, jsonb_build_object('enderecos', v_n), 'Removido da lista negra');

  return jsonb_build_object('enderecos_liberados', v_n);
end $$;

-- Reativar não vale para quem está na lista negra: primeiro sai dela (desbloquear_email).
create or replace function public.alterar_status_banco(p_candidato_id uuid, p_novo text, p_motivo text default null)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_atual public.status_banco_talentos;
  v_negra boolean;
begin
  perform public.fn_exige_usuario_ativo();
  if p_novo not in ('ativo', 'inativo') then
    raise exception 'Só é possível inativar ou reativar.';
  end if;

  select status_banco, lista_negra into v_atual, v_negra from public.candidatos where id = p_candidato_id for update;
  if not found then
    raise exception 'Candidato não encontrado.';
  end if;
  if v_atual = 'em_processo' then
    raise exception 'O candidato está em processo seletivo. Encerre a candidatura primeiro.';
  elsif v_atual = 'expurgado' then
    raise exception 'Os dados deste candidato foram excluídos.';
  elsif v_atual::text = p_novo then
    return;
  elsif p_novo = 'ativo' and v_negra then
    raise exception 'Este candidato está na lista negra. Tire-o da lista negra antes de reativá-lo.';
  end if;

  update public.candidatos
     set status_banco        = p_novo::public.status_banco_talentos,
         inativado_em        = case when p_novo = 'inativo' then now() else null end,
         motivo_inativacao   = case when p_novo = 'inativo' then nullif(btrim(p_motivo), '') else null end,
         retencao_permanente = case when p_novo = 'ativo' then false else retencao_permanente end,
         ultima_movimentacao = now()
   where id = p_candidato_id;

  perform public.fn_registra_auditoria('alteracao_candidato', 'candidatos', p_candidato_id,
    jsonb_build_object('status_banco', v_atual), jsonb_build_object('status_banco', p_novo),
    case when p_novo = 'inativo' then 'Candidato inativado pelo RH' else 'Candidato reativado pelo RH' end);
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  3) Descarte por vaga: reprovado/descartado numa vaga não volta a ela. Cada vaga tem o seu id, então uma vaga
--     nova (mesmo com o mesmo título) é outra história. "Devolver ao banco" (cancelado) NÃO conta: o RH não reprovou.
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_atribuir_candidato_vaga(
  p_candidato_id uuid, p_vaga_id uuid, p_usuario_id uuid, p_observacao text default null)
returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status      public.status_banco_talentos;
  v_negra       boolean;
  v_vaga_status public.status_registro;
  v_id          uuid;
begin
  select status_banco, lista_negra into v_status, v_negra from public.candidatos where id = p_candidato_id for update;
  if not found then
    raise exception 'Candidato não encontrado.';
  end if;
  if v_negra then
    raise exception 'Este candidato está na lista negra e não pode ser atribuído a vagas.';
  elsif v_status = 'em_processo' then
    raise exception 'Este candidato já está em um processo seletivo. Encerre a candidatura atual antes de atribuí-lo a outra vaga.';
  elsif v_status = 'inativo' then
    raise exception 'Candidato inativo. Reative-o no Banco de Talentos antes de atribuir a uma vaga.';
  elsif v_status = 'expurgado' then
    raise exception 'Os dados deste candidato foram excluídos.';
  end if;

  select status into v_vaga_status from public.vagas where id = p_vaga_id;
  if not found then
    raise exception 'Vaga não encontrada.';
  end if;
  if v_vaga_status <> 'ativo' then
    raise exception 'Esta vaga não está mais aberta.';
  end if;

  if exists (select 1 from public.candidaturas
              where candidato_id = p_candidato_id and vaga_id = p_vaga_id and status in ('reprovado', 'descartado')) then
    raise exception 'Este candidato já foi reprovado nesta vaga. Ele só pode voltar em uma vaga nova.';
  end if;

  insert into public.candidaturas
         (candidato_id, vaga_id, status, atribuido_por, data_atribuicao, vaga_confirmada_rh,
          avaliacao_pendente, origem, observacao_atribuicao)
  values (p_candidato_id, p_vaga_id, 'aguardando', p_usuario_id, now(), true,
          true, 'atribuicao_manual', nullif(btrim(p_observacao), ''))
  returning id into v_id;

  perform public.fn_registra_auditoria(
    'atribuicao_candidato', 'candidaturas', v_id, null,
    jsonb_build_object('candidato_id', p_candidato_id, 'vaga_id', p_vaga_id),
    'Candidato atribuído à vaga pelo RH');
  return v_id;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Views: o banco passa a informar a lista negra; e a tela da lista negra
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.vw_banco_talentos with (security_invoker = true) as
select
  c.id,
  c.nome, c.nome_norm, c.sexo, c.data_nascimento, c.nascimento_ref,
  case when c.nascimento_ref is not null
       then extract(year from age(current_date, c.nascimento_ref))::int end            as idade,
  (c.data_nascimento is null and c.nascimento_ref is not null)                         as idade_estimada,
  c.cidade, c.cidade_norm, c.uf, c.telefone, c.telefone_e164, c.email,
  c.escolaridade, c.escolaridade_ord, c.anos_experiencia, c.cnh,
  c.status_banco, c.origem_entrada, c.data_entrada, c.ultima_atualizacao, c.ultima_movimentacao,
  c.ultimo_contato_em, c.retencao_permanente, c.consentimento_em, c.consentimento_origem,
  c.sanitizacao_adiada_ate,
  -- sugestão atual da IA
  c.area_sugerida, c.cargo_sugerido, c.nivel_sugerido, c.ia_confianca, c.revisao_manual,
  c.reanalise_solicitada_em,
  a.texto_resumo_ia                                                                    as resumo_ia,
  a.pontos_positivos, a.pontos_negativos, a.data_analise, a.versao_modelo_ia, a.motivo_revisao,
  -- currículo atual
  cur.id                                                                               as curriculo_id,
  cur.storage_path, cur.nome_arquivo, cur.origem                                       as curriculo_origem,
  cur.recebido_em                                                                      as curriculo_recebido_em,
  -- histórico de vagas
  coalesce(h.total_candidaturas, 0)                                                    as total_candidaturas,
  coalesce(h.total_reprovacoes, 0)                                                     as total_reprovacoes,
  ab.id                                                                                as candidatura_atual_id,
  ab.status                                                                            as candidatura_atual_status,
  ab.vaga_id                                                                           as vaga_atual_id,
  ab.vaga_titulo                                                                       as vaga_atual_titulo,
  exists (select 1 from public.sanitizacao_sugestoes s
           where s.candidato_id = c.id and s.status = 'pendente')                      as sanitizacao_pendente,
  -- lista negra (colunas novas sempre no fim: é o que o CREATE OR REPLACE VIEW permite)
  c.lista_negra, c.lista_negra_em, c.lista_negra_motivo,
  public.fn_nome_usuario(c.lista_negra_por)                                            as lista_negra_por_nome
from public.candidatos c
left join public.analises_ia a on a.id = c.analise_atual_id
left join lateral (
  select cu.id, cu.storage_path, cu.nome_arquivo, cu.origem, cu.recebido_em
    from public.curriculos cu where cu.candidato_id = c.id and cu.atual limit 1
) cur on true
left join lateral (
  select count(*)                                    as total_candidaturas,
         count(*) filter (where ca.status = 'reprovado') as total_reprovacoes
    from public.candidaturas ca
   where ca.candidato_id = c.id and ca.origem <> 'triagem_legada'
) h on true
left join lateral (
  select ca.id, ca.status, ca.vaga_id, v.titulo as vaga_titulo
    from public.candidaturas ca left join public.vagas v on v.id = ca.vaga_id
   where ca.candidato_id = c.id and ca.encerrada_em is null limit 1
) ab on true
where c.status_banco <> 'expurgado';

-- Endereços bloqueados, com quem bloqueou e (se houver) o candidato ligado a eles
create or replace view public.vw_lista_negra with (security_invoker = true) as
select
  r.id, r.email::text as email, r.bloqueado_em, r.motivo_bloqueio,
  r.bloqueado_por, public.fn_nome_usuario(r.bloqueado_por) as bloqueado_por_nome,
  r.total_envios, r.ultimo_envio_em,
  k.id as candidato_id, k.nome as candidato_nome
from public.remetentes r
left join lateral (
  select c.id, c.nome from public.candidatos c
   where c.lista_negra
     and (lower(c.email) = lower(r.email::text)
          or exists (select 1 from public.curriculos cu where cu.candidato_id = c.id and cu.remetente_id = r.id))
   order by c.lista_negra_em desc nulls last limit 1
) k on true
where r.bloqueado;

-- ───────────────────────────────────────────────────────────────────────
--  Privilégios
-- ───────────────────────────────────────────────────────────────────────
revoke all on public.vw_lista_negra from anon, authenticated;
grant select on public.vw_lista_negra to authenticated;
grant all on public.vw_lista_negra to service_role;

revoke execute on function
  public.fn_lista_negra_candidato(uuid, text),
  public.bloquear_email(text, text, uuid),
  public.desbloquear_email(text, uuid)
from public, anon, authenticated;
grant execute on function
  public.bloquear_email(text, text, uuid),
  public.desbloquear_email(text, uuid)
to authenticated;
grant execute on function public.fn_lista_negra_candidato(uuid, text) to service_role;
grant execute on function public.bloquear_email(text, text, uuid), public.desbloquear_email(text, uuid) to service_role;
