-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · PASSO 3 de 6: regras (gatilhos e funções)
--
--  O que este arquivo garante, no próprio banco (vale para o painel, o pipeline e qualquer SQL):
--   • Atribuir candidato a vaga é sempre manual (função atribuir_candidato_vaga) e só a partir do
--     banco: candidato "ativo", vaga aberta, no máximo UMA candidatura aberta por candidato.
--   • Candidatura reprovada/cancelada/descartada FECHA e o candidato volta sozinho para "ativo" no
--     Banco de Talentos — a candidatura antiga continua no histórico.
--   • Currículo novo vira o "atual" do candidato; os anteriores ficam como versões.
--   • A análise mais recente da IA é copiada para o candidato (para filtrar e indexar).
--
--  Pode rodar de novo sem problema (create or replace).
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  Auxiliares
-- ───────────────────────────────────────────────────────────────────────
-- Nome de um colega. A RLS de "usuarios" só deixa cada um ver a própria linha; as telas precisam
-- mostrar "atribuído por" / "decidido por", então só o NOME sai por aqui, e só para usuário ativo.
create or replace function public.fn_nome_usuario(p_id uuid)
returns text
language sql stable security definer
set search_path to 'public'
as $$
  select u.nome from public.usuarios u where u.id = p_id and public.fn_usuario_ativo();
$$;

create or replace function public.fn_exige_usuario_ativo()
returns void
language plpgsql stable security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null then
    raise exception 'Sessão expirada. Entre novamente.';
  end if;
  if not public.fn_usuario_ativo() then
    raise exception 'Usuário inativo. Contate o administrador.';
  end if;
end $$;

create or replace function public.fn_exige_admin()
returns void
language plpgsql stable security definer
set search_path to 'public'
as $$
begin
  perform public.fn_exige_usuario_ativo();
  if not public.fn_usuario_admin() then
    raise exception 'Somente o administrador pode fazer isto.';
  end if;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  CANDIDATOS: carimbos de data
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_candidato_carimbos()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.updated_at := now();
  -- mudou algum dado do candidato: conta como atualização e como movimentação
  if (new.nome, new.sexo, new.data_nascimento, new.idade_informada, new.cidade, new.uf, new.telefone,
      new.telefone_e164, new.email, new.escolaridade, new.anos_experiencia, new.cnh)
     is distinct from
     (old.nome, old.sexo, old.data_nascimento, old.idade_informada, old.cidade, old.uf, old.telefone,
      old.telefone_e164, old.email, old.escolaridade, old.anos_experiencia, old.cnh) then
    new.ultima_atualizacao := now();
    new.ultima_movimentacao := now();
  end if;
  return new;
end $$;

drop trigger if exists trg_candidatos_carimbos on public.candidatos;
create trigger trg_candidatos_carimbos
  before update on public.candidatos
  for each row execute function public.fn_candidato_carimbos();

-- ───────────────────────────────────────────────────────────────────────
--  ANALISES_IA: a mais recente vira a sugestão atual do candidato
--  (não mexe em ultima_movimentacao: reanálise automática não é movimento do candidato)
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_analise_sincroniza_candidato()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  update public.candidatos c
     set analise_atual_id        = new.id,
         area_sugerida           = new.area_sugerida,
         cargo_sugerido          = new.cargo_sugerido,
         nivel_sugerido          = new.nivel_sugerido,
         ia_confianca            = new.confianca,
         revisao_manual          = new.revisao_manual,
         reanalise_solicitada_em = null,
         ultima_atualizacao      = now()
   where c.id = new.candidato_id
     and not exists (select 1 from public.analises_ia a
                      where a.candidato_id = new.candidato_id and a.sequencia > new.sequencia);
  return new;
end $$;

drop trigger if exists trg_analise_sincroniza_candidato on public.analises_ia;
create trigger trg_analise_sincroniza_candidato
  after insert on public.analises_ia
  for each row execute function public.fn_analise_sincroniza_candidato();

-- ───────────────────────────────────────────────────────────────────────
--  CURRICULOS: só um "atual" por candidato; o envio conta para o remetente
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_curriculo_antes_de_inserir()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.candidato_id is not null and new.atual then
    update public.curriculos set atual = false where candidato_id = new.candidato_id and atual;
  end if;
  return new;
end $$;

create or replace function public.fn_curriculo_depois_de_inserir()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  -- antes esta contagem era feita pela candidatura; o que chega por e-mail é o currículo
  if new.remetente_id is not null then
    update public.remetentes
       set total_envios = total_envios + 1, ultimo_envio_em = new.recebido_em
     where id = new.remetente_id;
  end if;
  if new.candidato_id is not null then
    update public.candidatos
       set ultima_movimentacao = now(), ultima_atualizacao = now()
     where id = new.candidato_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_curriculo_antes_de_inserir on public.curriculos;
create trigger trg_curriculo_antes_de_inserir
  before insert on public.curriculos
  for each row execute function public.fn_curriculo_antes_de_inserir();

drop trigger if exists trg_curriculo_depois_de_inserir on public.curriculos;
create trigger trg_curriculo_depois_de_inserir
  after insert on public.curriculos
  for each row execute function public.fn_curriculo_depois_de_inserir();

-- ───────────────────────────────────────────────────────────────────────
--  CANDIDATURAS: carimbos e devolução automática ao Banco de Talentos
-- ───────────────────────────────────────────────────────────────────────
-- Estados que FECHAM uma candidatura. Fora disso, ela está aberta e o candidato "em processo".
create or replace function public.fn_candidatura_carimbos()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  v_fecha boolean := new.status in ('reprovado', 'cancelado', 'descartado', 'contratado');
begin
  if tg_op = 'INSERT' then
    if new.status in ('aguardando', 'selecionado') then
      new.data_atribuicao := coalesce(new.data_atribuicao, now());
      new.atribuido_por   := coalesce(new.atribuido_por, auth.uid());
      -- selecionado_em/por alimentam as métricas do painel ("selecionados"): atribuir = selecionar
      new.selecionado_em  := coalesce(new.selecionado_em, new.data_atribuicao);
      new.selecionado_por := coalesce(new.selecionado_por, new.atribuido_por);
    end if;
    if v_fecha then
      new.encerrada_em := coalesce(new.encerrada_em, now());
    end if;
  elsif new.status is distinct from old.status then
    if new.status in ('aguardando', 'selecionado') and old.status not in ('aguardando', 'selecionado') then
      new.data_atribuicao := coalesce(new.data_atribuicao, now());
      new.atribuido_por   := coalesce(new.atribuido_por, auth.uid());
      new.selecionado_em  := coalesce(new.selecionado_em, new.data_atribuicao);
      new.selecionado_por := coalesce(new.selecionado_por, new.atribuido_por);
    end if;
    if new.status = 'descartado' then
      new.descartado_em  := coalesce(new.descartado_em, now());
      new.descartado_por := coalesce(new.descartado_por, auth.uid());
    end if;
    if v_fecha then
      new.encerrada_em := coalesce(new.encerrada_em, now());
    elsif old.status in ('reprovado', 'cancelado', 'descartado', 'contratado') then
      new.encerrada_em := null;          -- reaberta
    end if;
    new.data_ultimo_evento := now();
  end if;

  if v_fecha and new.resultado_final is null then
    new.resultado_final := case new.status
      when 'reprovado'  then 'Reprovado'
      when 'cancelado'  then 'Candidatura cancelada'
      when 'descartado' then coalesce(new.motivo_descarte, 'Descartado')
      else 'Contratado' end;
  end if;
  return new;
end $$;

-- Recalcula a situação do candidato no banco a partir das candidaturas dele:
--   candidatura aberta  → em_processo
--   nenhuma aberta      → volta a "ativo" (se estava em processo) — a candidatura fechada fica no histórico
--   contratado agora    → inativo e retenção permanente (contratado sai do banco e não vai à sanitização)
-- "ativo" e "inativo" definidos à mão pelo RH nunca são mexidos aqui.
create or replace function public.fn_recalcular_status_banco(p_candidato_id uuid, p_contratou boolean default false)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_atual  public.status_banco_talentos;
  v_novo   public.status_banco_talentos;
  v_aberta boolean;
begin
  if p_candidato_id is null then return; end if;

  select status_banco into v_atual from public.candidatos where id = p_candidato_id for update;
  if not found or v_atual = 'expurgado' then return; end if;

  select exists (select 1 from public.candidaturas
                  where candidato_id = p_candidato_id and encerrada_em is null)
    into v_aberta;

  if p_contratou then
    v_novo := 'inativo';
  elsif v_aberta then
    v_novo := 'em_processo';
  elsif v_atual = 'em_processo' then
    v_novo := 'ativo';
  else
    v_novo := v_atual;
  end if;

  if v_novo = v_atual and not p_contratou then return; end if;

  update public.candidatos
     set status_banco        = v_novo,
         retencao_permanente = retencao_permanente or p_contratou,
         inativado_em        = case when v_novo = 'inativo' then coalesce(inativado_em, now()) else inativado_em end,
         motivo_inativacao   = case when p_contratou then 'contratado' else motivo_inativacao end,
         ultima_movimentacao = now()
   where id = p_candidato_id;

  if v_atual = 'em_processo' and v_novo = 'ativo' then
    perform public.fn_registra_auditoria(
      'retorno_banco_talentos', 'candidatos', p_candidato_id,
      jsonb_build_object('status_banco', v_atual), jsonb_build_object('status_banco', v_novo),
      'Candidatura encerrada: o candidato voltou ao Banco de Talentos');
  end if;
end $$;

create or replace function public.fn_candidatura_sincroniza_banco()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'DELETE' then
    perform public.fn_recalcular_status_banco(old.candidato_id);
    return old;
  end if;
  if new.candidato_id is null then return new; end if;

  perform public.fn_recalcular_status_banco(
    new.candidato_id,
    new.status = 'contratado' and (tg_op = 'INSERT' or old.status is distinct from new.status));

  if tg_op = 'INSERT' or new.status is distinct from old.status then
    update public.candidatos set ultima_movimentacao = now() where id = new.candidato_id;
  end if;
  return new;
end $$;

-- Gatilhos antigos da candidatura: a retenção automática por status/tempo acabou (a limpeza agora é a
-- sanitização, com decisão do RH); o carimbo de decisão e a contagem de envios mudaram de lugar.
drop trigger if exists trg_cand_marco_retencao on public.candidaturas;
drop trigger if exists trg_cand_carimba_decisao on public.candidaturas;
drop trigger if exists trg_cand_incrementa_envios on public.candidaturas;
drop function if exists public.fn_atualiza_marco_retencao();
drop function if exists public.fn_carimba_decisao();
drop function if exists public.fn_incrementa_envios_remetente();

drop trigger if exists trg_candidatura_carimbos on public.candidaturas;
create trigger trg_candidatura_carimbos
  before insert or update of status on public.candidaturas
  for each row execute function public.fn_candidatura_carimbos();

drop trigger if exists trg_candidatura_sincroniza_banco on public.candidaturas;
create trigger trg_candidatura_sincroniza_banco
  after insert or update of status, encerrada_em, candidato_id or delete on public.candidaturas
  for each row execute function public.fn_candidatura_sincroniza_banco();

-- ───────────────────────────────────────────────────────────────────────
--  ENTREVISTAS: "aguardando" entra na regra; reprovar na entrevista fecha a candidatura
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_sincroniza_status_entrevista()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if tg_op = 'INSERT' then
    update public.candidaturas
       set status = 'entrevista_agendada'
     where id = new.candidatura_id
       and status in ('aguardando', 'selecionado', 'nao_compareceu', 'entrevista_realizada');
    return new;
  end if;

  if new.resultado is distinct from old.resultado then
    update public.candidaturas
       set status = case new.resultado
                      when 'aprovado'       then 'aprovado'::public.status_candidatura
                      when 'reprovado'      then 'reprovado'::public.status_candidatura
                      when 'nao_compareceu' then 'nao_compareceu'::public.status_candidatura
                      else status
                    end,
           -- reprovou: o motivo digitado na entrevista vira o resultado final da candidatura
           resultado_final = case when new.resultado = 'reprovado'
                                  then coalesce(nullif(btrim(new.observacoes), ''), 'Reprovado na entrevista')
                                  else resultado_final end
     where id = new.candidatura_id;

    new.resultado_registrado_em  := coalesce(new.resultado_registrado_em, now());
    new.resultado_registrado_por := coalesce(new.resultado_registrado_por, auth.uid());
  end if;

  return new;
end $$;

-- Excluir entrevista marcada por engano: o candidato volta a "aguardando" (era "selecionado")
create or replace function public.excluir_entrevista(p_id uuid)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
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
       set status = 'aguardando'
     where id = v.candidatura_id and status = 'entrevista_agendada';
  end if;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  ATRIBUIÇÃO MANUAL (RH) — candidato do banco → vaga aberta
-- ───────────────────────────────────────────────────────────────────────
-- Interna: recebe o usuário como parâmetro (o pipeline usa quando o RH envia currículo já escolhendo a
-- vaga). Só o backend (service_role) executa; o painel usa atribuir_candidato_vaga().
create or replace function public.fn_atribuir_candidato_vaga(
  p_candidato_id uuid, p_vaga_id uuid, p_usuario_id uuid, p_observacao text default null)
returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status      public.status_banco_talentos;
  v_vaga_status public.status_registro;
  v_id          uuid;
begin
  select status_banco into v_status from public.candidatos where id = p_candidato_id for update;
  if not found then
    raise exception 'Candidato não encontrado.';
  end if;
  if v_status = 'em_processo' then
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

create or replace function public.atribuir_candidato_vaga(
  p_candidato_id uuid, p_vaga_id uuid, p_observacao text default null)
returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
begin
  perform public.fn_exige_usuario_ativo();
  return public.fn_atribuir_candidato_vaga(p_candidato_id, p_vaga_id, auth.uid(), p_observacao);
end $$;

-- Encerra a candidatura aberta (reprovado ou cancelado): o candidato volta ao Banco de Talentos
create or replace function public.encerrar_candidatura(
  p_candidatura_id uuid, p_status text, p_motivo text default null)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v public.candidaturas%rowtype;
begin
  perform public.fn_exige_usuario_ativo();
  if p_status not in ('reprovado', 'cancelado') then
    raise exception 'Status inválido: use reprovado ou cancelado.';
  end if;

  select * into v from public.candidaturas where id = p_candidatura_id for update;
  if not found then
    raise exception 'Candidatura não encontrada.';
  end if;
  if v.encerrada_em is not null then
    raise exception 'Esta candidatura já foi encerrada.';
  end if;

  -- entrevista ainda marcada deixa de valer (some da agenda)
  update public.entrevistas
     set resultado = 'cancelada'
   where candidatura_id = p_candidatura_id and resultado in ('agendada', 'remarcada');

  update public.candidaturas
     set status          = p_status::public.status_candidatura,
         resultado_final = coalesce(nullif(btrim(p_motivo), ''),
                                    case p_status when 'reprovado' then 'Reprovado' else 'Candidatura cancelada' end)
   where id = p_candidatura_id;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Ações do RH sobre o candidato (o painel não escreve em "candidatos" direto)
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.editar_candidato(p_candidato_id uuid, p_dados jsonb)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_campos text[];
  v_sexo   text := nullif(lower(btrim(p_dados ->> 'sexo')), '');
  v_uf     text := nullif(upper(btrim(p_dados ->> 'uf')), '');
  v_esc    text := nullif(lower(btrim(p_dados ->> 'escolaridade')), '');
begin
  perform public.fn_exige_usuario_ativo();
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' then
    raise exception 'Dados inválidos.';
  end if;
  if p_dados ? 'sexo' and v_sexo is not null and v_sexo not in ('masculino', 'feminino') then
    raise exception 'Sexo deve ser masculino ou feminino.';
  end if;
  if p_dados ? 'uf' and v_uf is not null and v_uf !~ '^[A-Z]{2}$' then
    raise exception 'UF deve ter 2 letras (ex.: DF).';
  end if;
  if p_dados ? 'escolaridade' and v_esc is not null
     and v_esc not in ('nenhuma', 'fundamental', 'medio', 'tecnico', 'superior', 'pos') then
    raise exception 'Escolaridade inválida.';
  end if;

  select coalesce(array_agg(k order by k), '{}') into v_campos
    from jsonb_object_keys(p_dados) k
   where k in ('nome', 'sexo', 'data_nascimento', 'idade_informada', 'cidade', 'uf', 'telefone',
               'telefone_e164', 'email', 'escolaridade', 'anos_experiencia', 'cnh');

  update public.candidatos c set
    nome             = case when p_dados ? 'nome'             then nullif(btrim(p_dados ->> 'nome'), '') else c.nome end,
    sexo             = case when p_dados ? 'sexo'             then v_sexo else c.sexo end,
    data_nascimento  = case when p_dados ? 'data_nascimento'  then nullif(p_dados ->> 'data_nascimento', '')::date else c.data_nascimento end,
    idade_informada  = case when p_dados ? 'idade_informada'  then nullif(p_dados ->> 'idade_informada', '')::smallint else c.idade_informada end,
    idade_informada_em = case when p_dados ? 'idade_informada' then current_date else c.idade_informada_em end,
    cidade           = case when p_dados ? 'cidade'           then nullif(btrim(p_dados ->> 'cidade'), '') else c.cidade end,
    uf               = case when p_dados ? 'uf'               then v_uf else c.uf end,
    telefone         = case when p_dados ? 'telefone'         then nullif(btrim(p_dados ->> 'telefone'), '') else c.telefone end,
    telefone_e164    = case when p_dados ? 'telefone_e164'    then nullif(btrim(p_dados ->> 'telefone_e164'), '') else c.telefone_e164 end,
    email            = case when p_dados ? 'email'            then nullif(lower(btrim(p_dados ->> 'email')), '') else c.email end,
    escolaridade     = case when p_dados ? 'escolaridade'     then v_esc else c.escolaridade end,
    anos_experiencia = case when p_dados ? 'anos_experiencia' then nullif(p_dados ->> 'anos_experiencia', '')::numeric else c.anos_experiencia end,
    cnh              = case when p_dados ? 'cnh'              then nullif(upper(btrim(p_dados ->> 'cnh')), '') else c.cnh end
  where c.id = p_candidato_id and c.status_banco <> 'expurgado';

  if not found then
    raise exception 'Candidato não encontrado (ou já excluído).';
  end if;

  -- só os NOMES dos campos vão para a auditoria, nunca os valores (LGPD)
  perform public.fn_registra_auditoria('alteracao_candidato', 'candidatos', p_candidato_id, null,
    jsonb_build_object('campos', to_jsonb(v_campos)), 'Dados do candidato editados pelo RH');
end $$;

create or replace function public.solicitar_reanalise(p_candidato_id uuid)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  perform public.fn_exige_usuario_ativo();
  if not exists (select 1 from public.curriculos
                  where candidato_id = p_candidato_id and atual and texto_extraido is not null) then
    raise exception 'Este candidato não tem texto de currículo para analisar.';
  end if;
  update public.candidatos set reanalise_solicitada_em = now()
   where id = p_candidato_id and status_banco <> 'expurgado';
  if not found then
    raise exception 'Candidato não encontrado (ou já excluído).';
  end if;
end $$;

create or replace function public.registrar_contato_candidato(p_candidato_id uuid)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  perform public.fn_exige_usuario_ativo();
  update public.candidatos set ultimo_contato_em = now(), ultima_movimentacao = now()
   where id = p_candidato_id and status_banco <> 'expurgado';
  if not found then
    raise exception 'Candidato não encontrado (ou já excluído).';
  end if;
end $$;

create or replace function public.registrar_consentimento(p_candidato_id uuid, p_origem text default 'confirmado_pelo_candidato')
returns void
language plpgsql security definer
set search_path to 'public'
as $$
begin
  perform public.fn_exige_usuario_ativo();
  if p_origem not in ('envio_espontaneo', 'confirmado_pelo_candidato') then
    raise exception 'Origem do consentimento inválida.';
  end if;
  update public.candidatos
     set consentimento_em = now(), consentimento_origem = p_origem, ultima_movimentacao = now()
   where id = p_candidato_id and status_banco <> 'expurgado';
  if not found then
    raise exception 'Candidato não encontrado (ou já excluído).';
  end if;
  perform public.fn_registra_auditoria('alteracao_candidato', 'candidatos', p_candidato_id, null,
    jsonb_build_object('consentimento_origem', p_origem), 'Consentimento de permanência no banco registrado');
end $$;

-- Inativar (tirar do banco sem apagar) ou reativar. "em_processo" e "expurgado" não se mexem à mão.
create or replace function public.alterar_status_banco(p_candidato_id uuid, p_novo text, p_motivo text default null)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_atual public.status_banco_talentos;
begin
  perform public.fn_exige_usuario_ativo();
  if p_novo not in ('ativo', 'inativo') then
    raise exception 'Só é possível inativar ou reativar.';
  end if;

  select status_banco into v_atual from public.candidatos where id = p_candidato_id for update;
  if not found then
    raise exception 'Candidato não encontrado.';
  end if;
  if v_atual = 'em_processo' then
    raise exception 'O candidato está em processo seletivo. Encerre a candidatura primeiro.';
  elsif v_atual = 'expurgado' then
    raise exception 'Os dados deste candidato foram excluídos.';
  elsif v_atual::text = p_novo then
    return;
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
--  Privilégios de execução
--  Padrão do Supabase: toda função nova nasce executável por anon/authenticated. Aqui só as funções
--  que o painel chama ficam abertas (a usuário logado); o resto é interno (gatilhos e pipeline).
-- ───────────────────────────────────────────────────────────────────────
revoke execute on function
  public.fn_nome_usuario(uuid),
  public.fn_exige_usuario_ativo(),
  public.fn_exige_admin(),
  public.fn_candidato_carimbos(),
  public.fn_analise_sincroniza_candidato(),
  public.fn_curriculo_antes_de_inserir(),
  public.fn_curriculo_depois_de_inserir(),
  public.fn_candidatura_carimbos(),
  public.fn_recalcular_status_banco(uuid, boolean),
  public.fn_candidatura_sincroniza_banco(),
  public.fn_atribuir_candidato_vaga(uuid, uuid, uuid, text),
  public.atribuir_candidato_vaga(uuid, uuid, text),
  public.encerrar_candidatura(uuid, text, text),
  public.editar_candidato(uuid, jsonb),
  public.solicitar_reanalise(uuid),
  public.registrar_contato_candidato(uuid),
  public.registrar_consentimento(uuid, text),
  public.alterar_status_banco(uuid, text, text)
from public, anon, authenticated;

-- as views chamam fn_nome_usuario com a sessão do painel
grant execute on function public.fn_nome_usuario(uuid) to authenticated;
grant execute on function
  public.atribuir_candidato_vaga(uuid, uuid, text),
  public.encerrar_candidatura(uuid, text, text),
  public.editar_candidato(uuid, jsonb),
  public.solicitar_reanalise(uuid),
  public.registrar_contato_candidato(uuid),
  public.registrar_consentimento(uuid, text),
  public.alterar_status_banco(uuid, text, text)
to authenticated;

grant execute on all functions in schema public to service_role;
