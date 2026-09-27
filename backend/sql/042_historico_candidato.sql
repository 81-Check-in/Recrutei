-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — HISTÓRICO DO CANDIDATO (042)
--
--  Rodar depois da 041. Pode rodar de novo sem problema.
--
--  Substitui a planilha Excel do processo seletivo: uma linha por ENTREVISTA com o desfecho de quem veio e de quem não veio.
--
--    • historico_candidatos — tabela PRÓPRIA, com nome, celular, data, setor da vaga, status e observação copiados na hora. É de propósito:
--      o histórico de quem veio e não veio permanece mesmo depois que os dados do candidato são excluídos do Banco de Talentos
--      (sanitização/LGPD). Por isso ele NÃO some junto e há uma exclusão própria, só do administrador (historico_excluir).
--    • Status: aprovado, reprovado, não compareceu (vêm SOZINHOS da tela Entrevistas), e sem interesse e desistência (o RH registra
--      no próprio Histórico: desistência é depois de aprovado, ex.: na documentação ou no treinamento).
--    • fn_historico_sincroniza_entrevista() — gatilho em entrevistas: ao registrar o resultado (ou corrigir a observação/data), a linha do
--      histórico é criada/atualizada; voltando a "agendada/remarcada/cancelada" ela some. Se o RH alterou a linha à mão, o gatilho
--      deixa de mexer nela (alterado_manual).
--    • historico_registrar / historico_alterar / historico_excluir — as gravações do painel (o painel só lê a tabela). Tudo na auditoria,
--      só com o NOME dos campos, nunca os valores.
--    • vw_historico_candidatos — o histórico mais o que ainda existe do cadastro (e-mail, cidade, região, função, nível...), que fica vazio
--      quando os dados do candidato foram excluídos.
--
--  Importar a planilha antiga (origem 'planilha'): função à parte, depois de ver o arquivo.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.historico_candidatos (
  id                uuid primary key default gen_random_uuid(),
  entrevista_id     uuid unique references public.entrevistas (id) on delete set null,
  candidato_id      uuid references public.candidatos (id) on delete set null,
  vaga_id           uuid references public.vagas (id) on delete set null,
  nome              text not null check (length(btrim(nome)) between 1 and 200),
  nome_norm         text generated always as (public.norm_busca(nome)) stored,
  telefone          text check (telefone is null or length(telefone) <= 40),
  telefone_digitos  text generated always as (regexp_replace(coalesce(telefone, ''), '\D', '', 'g')) stored,
  data_evento       date not null,
  setor_vaga        text check (setor_vaga is null or length(setor_vaga) <= 120),
  vaga_titulo       text check (vaga_titulo is null or length(vaga_titulo) <= 200),
  status            text not null check (status in ('aprovado', 'reprovado', 'sem_interesse', 'nao_compareceu', 'desistencia')),
  observacao        text check (observacao is null or length(observacao) <= 4000),
  origem            text not null default 'sistema' check (origem in ('sistema', 'manual', 'planilha')),
  alterado_manual   boolean not null default false,
  registrado_por    uuid,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  atualizado_por    uuid
);
comment on table public.historico_candidatos is
  'Histórico do processo seletivo: uma linha por entrevista (quem veio e quem não veio), com cópia própria de nome e celular. Sobrevive à exclusão dos dados do candidato; a exclusão daqui é só do administrador.';

create index if not exists idx_historico_data     on public.historico_candidatos (data_evento desc, criado_em desc);
create index if not exists idx_historico_status   on public.historico_candidatos (status);
create index if not exists idx_historico_candidato on public.historico_candidatos (candidato_id) where candidato_id is not null;
create index if not exists idx_historico_nome     on public.historico_candidatos using gin (nome_norm extensions.gin_trgm_ops);
create index if not exists idx_historico_telefone on public.historico_candidatos using gin (telefone_digitos extensions.gin_trgm_ops);

alter table public.historico_candidatos enable row level security;
drop policy if exists historico_leitura on public.historico_candidatos;
create policy historico_leitura on public.historico_candidatos for select to authenticated using (public.fn_usuario_ativo());

revoke all on public.historico_candidatos from anon, authenticated;
grant select on public.historico_candidatos to authenticated;
grant all on public.historico_candidatos to service_role;

-- ───────────────────────────────────────────────────────────────────────
--  1) Preenchimento automático a partir de Entrevistas
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_historico_sincroniza_entrevista()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_cand   uuid;
  v_nome   text;
  v_tel    text;
  v_vaga   uuid;
  v_titulo text;
  v_setor  text;
begin
  -- não é um desfecho (agendada, remarcada, cancelada): não há linha; se já houve (resultado corrigido), some, salvo se o RH mexeu nela
  if new.resultado::text not in ('aprovado', 'reprovado', 'nao_compareceu') then
    delete from public.historico_candidatos where entrevista_id = new.id and not alterado_manual;
    return new;
  end if;

  select ca.candidato_id,
         coalesce(nullif(btrim(c.nome), ''), nullif(btrim(ca.dados_pessoais ->> 'nome'), ''), 'Nome não informado'),
         coalesce(nullif(btrim(c.telefone), ''), nullif(btrim(c.telefone_e164), ''), nullif(btrim(ca.dados_pessoais ->> 'telefone'), '')),
         ca.vaga_id, v.titulo, s.nome
    into v_cand, v_nome, v_tel, v_vaga, v_titulo, v_setor
    from public.candidaturas ca
    left join public.candidatos c on c.id = ca.candidato_id
    left join public.vagas v on v.id = ca.vaga_id
    left join public.setores s on s.id = v.setor_id
   where ca.id = new.candidatura_id;
  if not found then
    return new;
  end if;

  insert into public.historico_candidatos
    (entrevista_id, candidato_id, vaga_id, nome, telefone, data_evento, setor_vaga, vaga_titulo, status, observacao, origem, registrado_por)
  values
    (new.id, v_cand, v_vaga, v_nome, v_tel, (new.data_hora at time zone 'America/Sao_Paulo')::date, v_setor, v_titulo,
     new.resultado::text, nullif(btrim(new.observacoes), ''), 'sistema', new.resultado_registrado_por)
  on conflict (entrevista_id) do update
     set candidato_id  = excluded.candidato_id,
         vaga_id       = excluded.vaga_id,
         nome          = excluded.nome,
         telefone      = excluded.telefone,
         data_evento   = excluded.data_evento,
         setor_vaga    = excluded.setor_vaga,
         vaga_titulo   = excluded.vaga_titulo,
         status        = excluded.status,
         observacao    = excluded.observacao,
         registrado_por = coalesce(excluded.registrado_por, public.historico_candidatos.registrado_por),
         atualizado_em = now()
   where not public.historico_candidatos.alterado_manual;      -- o que o RH corrigiu à mão não é refeito
  return new;
end $$;

drop trigger if exists trg_historico_sincroniza on public.entrevistas;
create trigger trg_historico_sincroniza
  after insert or update of resultado, observacoes, data_hora on public.entrevistas
  for each row execute function public.fn_historico_sincroniza_entrevista();

-- entrevistas que já têm desfecho (quem já veio ou faltou antes desta tabela existir)
insert into public.historico_candidatos
  (entrevista_id, candidato_id, vaga_id, nome, telefone, data_evento, setor_vaga, vaga_titulo, status, observacao, origem, registrado_por)
select e.id, ca.candidato_id,  ca.vaga_id,
       coalesce(nullif(btrim(c.nome), ''), nullif(btrim(ca.dados_pessoais ->> 'nome'), ''), 'Nome não informado'),
       coalesce(nullif(btrim(c.telefone), ''), nullif(btrim(c.telefone_e164), ''), nullif(btrim(ca.dados_pessoais ->> 'telefone'), '')),
       (e.data_hora at time zone 'America/Sao_Paulo')::date, s.nome, v.titulo, e.resultado::text, nullif(btrim(e.observacoes), ''),
       'sistema', e.resultado_registrado_por
  from public.entrevistas e
  join public.candidaturas ca on ca.id = e.candidatura_id
  left join public.candidatos c on c.id = ca.candidato_id
  left join public.vagas v on v.id = ca.vaga_id
  left join public.setores s on s.id = v.setor_id
 where e.resultado::text in ('aprovado', 'reprovado', 'nao_compareceu')
on conflict (entrevista_id) do nothing;

-- ───────────────────────────────────────────────────────────────────────
--  2) Gravações do painel (o painel só LÊ a tabela)
-- ───────────────────────────────────────────────────────────────────────
-- Registro à mão: quem desistiu, quem não teve interesse, ou qualquer linha que o sistema não criou sozinho
create or replace function public.historico_registrar(p_dados jsonb)
returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_nome   text := nullif(btrim(p_dados ->> 'nome'), '');
  v_tel    text := nullif(btrim(p_dados ->> 'telefone'), '');
  v_status text := nullif(btrim(p_dados ->> 'status'), '');
  v_setor  text := nullif(btrim(p_dados ->> 'setor_vaga'), '');
  v_vaga   text := nullif(btrim(p_dados ->> 'vaga_titulo'), '');
  v_obs    text := nullif(btrim(p_dados ->> 'observacao'), '');
  v_data   date;
  v_id     uuid;
begin
  perform public.fn_exige_usuario_ativo();
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' then
    raise exception 'Dados inválidos.';
  end if;
  if v_nome is null then
    raise exception 'Informe o nome.';
  end if;
  if length(v_nome) > 200 then
    raise exception 'O nome é muito longo (máximo 200 caracteres).';
  end if;
  if v_status is null or v_status not in ('aprovado', 'reprovado', 'sem_interesse', 'nao_compareceu', 'desistencia') then
    raise exception 'Escolha o status.';
  end if;
  begin
    v_data := coalesce(nullif(btrim(p_dados ->> 'data_evento'), ''), current_date::text)::date;
  exception when others then
    raise exception 'Data inválida.';
  end;
  if v_tel is not null and length(regexp_replace(v_tel, '\D', '', 'g')) < 8 then
    raise exception 'Telefone inválido: informe ao menos 8 números.';
  end if;

  insert into public.historico_candidatos
    (nome, telefone, data_evento, setor_vaga, vaga_titulo, status, observacao, origem, alterado_manual, registrado_por, atualizado_por)
  values (v_nome, v_tel, v_data, v_setor, v_vaga, v_status, v_obs, 'manual', true, auth.uid(), auth.uid())
  returning id into v_id;

  perform public.fn_registra_auditoria('criacao', 'historico_candidatos', v_id, null,
    jsonb_build_object('status', v_status), 'Registro criado à mão no Histórico do candidato');
  return v_id;
end $$;

-- Corrige uma linha (status, observação, data, nome, celular, setor, vaga). A partir daí ela deixa de acompanhar a entrevista.
create or replace function public.historico_alterar(p_id uuid, p_dados jsonb)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_campos text[];
  v_status text := nullif(btrim(p_dados ->> 'status'), '');
  v_nome   text := nullif(btrim(p_dados ->> 'nome'), '');
  v_tel    text := nullif(btrim(p_dados ->> 'telefone'), '');
  v_data   date;
begin
  perform public.fn_exige_usuario_ativo();
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' then
    raise exception 'Dados inválidos.';
  end if;
  if p_dados ? 'status' and (v_status is null or v_status not in ('aprovado', 'reprovado', 'sem_interesse', 'nao_compareceu', 'desistencia')) then
    raise exception 'Escolha o status.';
  end if;
  if p_dados ? 'nome' and v_nome is null then
    raise exception 'Informe o nome.';
  end if;
  if p_dados ? 'nome' and length(v_nome) > 200 then
    raise exception 'O nome é muito longo (máximo 200 caracteres).';
  end if;
  if p_dados ? 'telefone' and v_tel is not null and length(regexp_replace(v_tel, '\D', '', 'g')) < 8 then
    raise exception 'Telefone inválido: informe ao menos 8 números.';
  end if;
  if p_dados ? 'data_evento' then
    begin
      v_data := nullif(btrim(p_dados ->> 'data_evento'), '')::date;
    exception when others then
      raise exception 'Data inválida.';
    end;
    if v_data is null then
      raise exception 'Informe a data.';
    end if;
  end if;

  select coalesce(array_agg(k order by k), '{}') into v_campos
    from jsonb_object_keys(p_dados) k
   where k in ('nome', 'telefone', 'data_evento', 'setor_vaga', 'vaga_titulo', 'status', 'observacao');

  update public.historico_candidatos h set
    nome        = case when p_dados ? 'nome'        then v_nome else h.nome end,
    telefone    = case when p_dados ? 'telefone'    then v_tel else h.telefone end,
    data_evento = case when p_dados ? 'data_evento' then v_data else h.data_evento end,
    setor_vaga  = case when p_dados ? 'setor_vaga'  then nullif(btrim(p_dados ->> 'setor_vaga'), '') else h.setor_vaga end,
    vaga_titulo = case when p_dados ? 'vaga_titulo' then nullif(btrim(p_dados ->> 'vaga_titulo'), '') else h.vaga_titulo end,
    status      = case when p_dados ? 'status'      then v_status else h.status end,
    observacao  = case when p_dados ? 'observacao'  then nullif(btrim(p_dados ->> 'observacao'), '') else h.observacao end,
    alterado_manual = true,
    atualizado_em   = now(),
    atualizado_por  = auth.uid()
  where h.id = p_id;
  if not found then
    raise exception 'Registro não encontrado.';
  end if;

  perform public.fn_registra_auditoria('atualizacao', 'historico_candidatos', p_id, null,
    jsonb_build_object('campos', to_jsonb(v_campos)), 'Registro do Histórico do candidato alterado pelo RH');
end $$;

-- Exclusão de uma linha: só o administrador (direito de exclusão da pessoa, LGPD)
create or replace function public.historico_excluir(p_id uuid)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status text;
begin
  perform public.fn_exige_usuario_ativo();
  if not public.fn_usuario_admin() then
    raise exception 'Somente o administrador pode excluir um registro do histórico.';
  end if;
  delete from public.historico_candidatos where id = p_id returning status into v_status;
  if not found then
    raise exception 'Registro não encontrado.';
  end if;
  perform public.fn_registra_auditoria('exclusao_manual_lgpd', 'historico_candidatos', p_id, null,
    jsonb_build_object('status', v_status), 'Registro excluído do Histórico do candidato');
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  3) A tela: o histórico + o que ainda existe do cadastro
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.vw_historico_candidatos with (security_invoker = true) as
select
  h.id, h.entrevista_id, h.candidato_id, h.vaga_id,
  h.nome, h.nome_norm, h.telefone, h.telefone_digitos,
  h.data_evento, h.setor_vaga, h.vaga_titulo, h.status, h.observacao, h.origem, h.alterado_manual,
  h.registrado_por, public.fn_nome_usuario(h.registrado_por) as registrado_por_nome,
  h.criado_em, h.atualizado_em,
  e.entrevistador,
  -- o que ainda existe do cadastro (vazio quando os dados do candidato foram excluídos)
  c.status_banco as candidato_situacao, c.email, c.cidade, c.uf, rg.nome as regiao_nome,
  c.area_sugerida, c.cargo_sugerido, c.nivel_sugerido, c.escolaridade, c.anos_experiencia
from public.historico_candidatos h
left join public.entrevistas e on e.id = h.entrevista_id
left join public.candidatos c on c.id = h.candidato_id and c.status_banco <> 'expurgado'
left join public.regioes_df rg on rg.id = c.regiao_id;

revoke all on public.vw_historico_candidatos from anon, authenticated;
grant select on public.vw_historico_candidatos to authenticated;
grant all on public.vw_historico_candidatos to service_role;

revoke execute on function
  public.fn_historico_sincroniza_entrevista(),
  public.historico_registrar(jsonb),
  public.historico_alterar(uuid, jsonb),
  public.historico_excluir(uuid)
from public, anon, authenticated;
grant execute on function
  public.historico_registrar(jsonb),
  public.historico_alterar(uuid, jsonb),
  public.historico_excluir(uuid)
to authenticated;
grant execute on function
  public.historico_registrar(jsonb),
  public.historico_alterar(uuid, jsonb),
  public.historico_excluir(uuid)
to service_role;
