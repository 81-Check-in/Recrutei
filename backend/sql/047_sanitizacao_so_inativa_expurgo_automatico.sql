-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Sanitização só INATIVA; o expurgo passa a ser AUTOMÁTICO, N meses depois de inativar (047)
--
--  O fluxo passa a ter três etapas separadas:
--
--    ATIVO ──(1 mês parado, ou "Sanitizar" no cadastro)──▶ fila da sanitização ──▶ RH: Manter | Inativar
--    INATIVO ──(expurgo_meses_apos_inativar, padrão 6; sozinho, na manutenção diária)──▶ EXPURGADO (esqueleto)
--
--  1) INATIVAÇÃO continua como está: o botão Inativar/Reativar do cadastro (alterar_status_banco) não muda.
--     Toda inativação (manual, pela sanitização ou por descarte) carimba candidatos.inativado_em; é dele que a
--     contagem dos N meses parte. Reativar (ou um reenvio do currículo, que reativa) zera a contagem.
--  2) SANITIZAÇÃO só mantém ou inativa. "Excluir" sai da fila: a decisão é recusada, inclusive para administrador.
--     Quem já está inativo não volta à fila (antes voltava toda semana: "Inativar" num inativo não fazia nada e o
--     candidato era sugerido de novo na semana seguinte).
--  3) EXPURGO automático (fn_expurgar_inativos_vencidos, chamada por fn_manutencao_diaria, que o robô roda 1x por dia):
--     apaga os dados pessoais de quem está INATIVO há mais de N meses, com a mesma rotina do expurgo manual
--     (fn_expurgar_candidato): sobra o esqueleto — hash de identidade, datas e situação — para reconhecer um reenvio.
--     Contratado (retenção permanente) nunca é expurgado. Os arquivos vão para a fila do Storage (arquivos_para_remover)
--     e o robô os remove na MESMA execução. Cada candidato é expurgado isoladamente: um que falhe não trava os demais.
--     No máximo 300 por chamada (os que sobrarem saem no dia seguinte).
--
--  Continua no banco, sem botão no painel: excluir_dados_candidato (LGPD art. 18, só administrador) — o único caminho
--  para apagar um titular ANTES dos N meses.
--
--  Em produção não há candidato inativo (conferido em 2026-09-27): aplicar não apaga nada.
--  Parâmetro novo (editável em Configurações): expurgo_meses_apos_inativar. Mínimo efetivo: 1 mês.
--
--  Pode rodar de novo sem problema.
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  Parâmetro
-- ───────────────────────────────────────────────────────────────────────
insert into public.configuracoes (chave, valor, descricao) values
  ('expurgo_meses_apos_inativar', to_jsonb(6),
   'Banco de Talentos: depois de quantos meses INATIVO o candidato tem os dados pessoais apagados sozinho (sobra só o esqueleto para reconhecer um reenvio). Reativar antes reinicia a contagem. Contratado nunca é apagado.')
on conflict (chave) do nothing;

-- Nunca menos de 1 mês: um valor 0, negativo ou inválido não pode apagar todos os inativos de uma vez
create or replace function public.fn_expurgo_meses()
returns integer
language sql stable security definer
set search_path to 'public'
as $$
  select greatest(public.fn_config_numero('expurgo_meses_apos_inativar', 6)::int, 1);
$$;
revoke execute on function public.fn_expurgo_meses() from public, anon, authenticated;
grant execute on function public.fn_expurgo_meses() to service_role;

-- Inativo sem data de inativação nunca completaria a contagem: carimba (em produção não há nenhum)
update public.candidatos
   set inativado_em = coalesce(ultima_movimentacao, now())
 where status_banco = 'inativo' and inativado_em is null;

-- ───────────────────────────────────────────────────────────────────────
--  Expurgo automático dos inativos vencidos
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_expurgar_inativos_vencidos(p_limite integer default 300)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_meses  integer     := public.fn_expurgo_meses();
  v_corte  timestamptz := now() - make_interval(months => v_meses);
  v_id     uuid;
  v_ok     integer := 0;
  v_falhas integer := 0;
  v_restam integer;
begin
  -- skip locked: quem está sendo mexido agora (ex.: alguém reativando) fica para a próxima
  for v_id in
    select c.id
      from public.candidatos c
     where c.status_banco = 'inativo' and not c.retencao_permanente
       and c.inativado_em < v_corte
     order by c.inativado_em, c.id
     limit greatest(p_limite, 1)
       for update of c skip locked
  loop
    begin
      perform public.fn_expurgar_candidato(v_id, format('Expurgo automático: mais de %s meses inativo', v_meses));
      v_ok := v_ok + 1;
    exception when others then
      v_falhas := v_falhas + 1;
      raise warning 'Expurgo automático: falhou para o candidato %: %', v_id, sqlerrm;
    end;
  end loop;

  select count(*) into v_restam
    from public.candidatos c
   where c.status_banco = 'inativo' and not c.retencao_permanente and c.inativado_em < v_corte;

  if v_ok + v_falhas > 0 then
    perform public.fn_registra_auditoria(
      'expurgo_automatico', 'candidatos', null, null,
      jsonb_build_object('expurgados', v_ok, 'falhas', v_falhas, 'meses', v_meses, 'restantes', v_restam),
      'Expurgo automático dos candidatos inativos');
  end if;

  return jsonb_build_object('expurgados', v_ok, 'falhas', v_falhas, 'meses', v_meses, 'restantes', v_restam);
end $$;

revoke execute on function public.fn_expurgar_inativos_vencidos(integer) from public, anon, authenticated;
grant execute on function public.fn_expurgar_inativos_vencidos(integer) to service_role;

-- ───────────────────────────────────────────────────────────────────────
--  Manutenção diária: é a da 023 + o expurgo dos inativos vencidos.
--  O expurgo roda ANTES de listar os arquivos, para os arquivos de quem acabou de ser apagado saírem no mesmo dia.
--  Se o expurgo falhar por inteiro, a manutenção (partições da auditoria) segue e o erro vai no resultado.
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_manutencao_diaria()
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_proxima date;
  v_nome    text;
  v_expurgo jsonb;
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

  begin
    v_expurgo := public.fn_expurgar_inativos_vencidos();
  exception when others then
    v_expurgo := jsonb_build_object('erro', sqlerrm);
  end;

  return jsonb_build_object(
    'executado_em', now(),
    'expurgo', v_expurgo,
    'arquivos_para_remover',
      coalesce((select jsonb_agg(storage_path order by enfileirado_em)
                  from public.arquivos_para_remover where removido_em is null), '[]'::jsonb),
    'sanitizacao_pendentes',
      (select count(*) from public.sanitizacao_sugestoes where status = 'pendente'));
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Decisão da sanitização: só manter ou inativar
--  (a assinatura de fn_sanitizacao_aplicar não muda — os privilégios da 023 continuam valendo; p_admin fica sem uso)
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
  if p_decisao = 'excluir' then
    raise exception 'A sanitização só mantém ou inativa. Os dados de quem fica inativo são apagados sozinhos depois de % meses.',
      public.fn_expurgo_meses();
  end if;
  if p_decisao not in ('manter', 'inativar') then
    raise exception 'Decisão inválida: use manter ou inativar.';
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
  if v_st = 'em_processo' then
    raise exception 'O candidato entrou em processo seletivo depois que a sugestão foi gerada.';
  elsif v_st = 'expurgado' then
    raise exception 'Os dados deste candidato já foram excluídos.';
  elsif v_st = 'inativo' and p_decisao = 'manter' then
    raise exception 'Este candidato já foi inativado. Reative-o no Banco de Talentos para mantê-lo.';
  end if;

  if p_decisao = 'manter' then
    v_ate := now() + make_interval(months => coalesce(p_adiar_meses, public.fn_config_numero('sanitizacao_adiar_meses', 6)::int));
    update public.candidatos set sanitizacao_adiada_ate = v_ate where id = v.candidato_id;
    update public.sanitizacao_sugestoes
       set status = 'mantido', adiada_ate = v_ate, decidido_por = p_usuario, decidido_em = now(), observacao = v_obs
     where id = v.id;
  else
    -- já inativo (inativado à mão depois da sugestão): só fecha a sugestão; a contagem do expurgo segue da 1ª inativação
    if v_st <> 'inativo' then
      update public.candidatos
         set status_banco = 'inativo', inativado_em = now(), motivo_inativacao = 'sanitização',
             ultima_movimentacao = now()
       where id = v.candidato_id;
    end if;
    update public.sanitizacao_sugestoes
       set status = 'inativado', decidido_por = p_usuario, decidido_em = now(), observacao = v_obs
     where id = v.id;
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

-- Em lote. A decisão é conferida ANTES do laço: "excluir" recusa o pedido todo, em vez de devolver 500 falhas iguais.
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
    raise exception 'A sanitização só mantém ou inativa. Os dados de quem fica inativo são apagados sozinhos depois de % meses.',
      public.fn_expurgo_meses();
  end if;
  if p_decisao not in ('manter', 'inativar') then
    raise exception 'Decisão inválida: use manter ou inativar.';
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
--  Botão "Sanitizar": qualquer usuário do RH; só faz sentido para quem está ATIVO
--  (é a da 043 + a recusa de quem já está inativo)
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.sanitizacao_enviar_candidato(p_candidato_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  c    public.candidatos%rowtype;
  v_id uuid;
begin
  perform public.fn_exige_usuario_ativo();

  select * into c from public.candidatos where id = p_candidato_id for update;
  if not found then
    raise exception 'Candidato não encontrado.';
  end if;
  if c.status_banco = 'expurgado' then
    raise exception 'Os dados deste candidato já foram excluídos.';
  end if;
  if c.status_banco = 'inativo' then
    raise exception 'Este candidato já está inativo; os dados dele são apagados sozinhos depois de % meses.',
      public.fn_expurgo_meses();
  end if;
  if c.status_banco = 'em_processo' then
    raise exception 'Este candidato está em processo seletivo: encerre a candidatura antes de sanitizar.';
  end if;
  if c.retencao_permanente then
    raise exception 'Este candidato tem retenção permanente (contratado) e não entra na sanitização.';
  end if;

  select id into v_id from public.sanitizacao_sugestoes where candidato_id = c.id and status = 'pendente';
  if found then
    return jsonb_build_object('enviada', false, 'ja_na_lista', true, 'sugestao_id', v_id);
  end if;

  insert into public.sanitizacao_sugestoes
         (ciclo_id, origem, enviada_por, candidato_id, motivos, motivo_texto, pontos, prioridade, ultima_movimentacao)
  values (null, 'manual', auth.uid(), c.id, array['envio_manual'], 'Enviado para a sanitização pelo RH',
          (public.fn_sanitizacao_parametros() -> 'pesos' ->> 'limite_alta')::int, 'alta', c.ultima_movimentacao)
  returning id into v_id;

  -- mesma ação da decisão do RH (a ação é um enum: valor novo exigiria uma migração só para isso)
  perform public.fn_registra_auditoria(
    'sanitizacao_decisao', 'candidatos', c.id, null,
    jsonb_build_object('decisao', 'enviar', 'sugestao_id', v_id, 'prioridade', 'alta'),
    'Sanitização: enviado pelo RH');

  return jsonb_build_object('enviada', true, 'ja_na_lista', false, 'sugestao_id', v_id);
end $$;

revoke execute on function public.sanitizacao_enviar_candidato(uuid) from public, anon, authenticated;
grant execute on function public.sanitizacao_enviar_candidato(uuid) to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────
--  Cálculo e geração da lista: em vez de copiar as funções inteiras (e arriscar divergir da versão que está no ar),
--  pega a definição atual e troca só o trecho abaixo. Se o trecho não for achado exatamente uma vez (e ainda não
--  tiver sido trocado), a migração PARA com erro.
--    • fn_sanitizacao_avaliar: só ATIVO entra na lista (o inativo está a caminho do expurgo)
--    • fn_gerar_sugestoes_sanitizacao: pendência de quem foi inativado à mão sai da fila
-- ───────────────────────────────────────────────────────────────────────
create or replace function pg_temp.remendar(p_fn regprocedure, p_de text, p_para text)
returns void
language plpgsql
as $$
declare
  v_def text := pg_get_functiondef(p_fn);
  v_n   integer;
begin
  if position(p_de in v_def) = 0 and position(p_para in v_def) > 0 then
    return;                                                     -- já remendada
  end if;
  v_n := (length(v_def) - length(replace(v_def, p_de, ''))) / length(p_de);
  if v_n <> 1 then
    raise exception '%: esperava achar o trecho [%] uma vez, achei % vez(es)', p_fn, p_de, v_n;
  end if;
  execute replace(v_def, p_de, p_para);
end $$;

select pg_temp.remendar('public.fn_sanitizacao_avaliar(jsonb)'::regprocedure,
  E'c.status_banco in (''ativo'', ''inativo'')',
  E'c.status_banco = ''ativo''   -- inativo já está a caminho do expurgo (fn_expurgar_inativos_vencidos)');

select pg_temp.remendar('public.fn_gerar_sugestoes_sanitizacao(text,boolean)'::regprocedure,
  E'c.status_banco in (''em_processo'', ''expurgado'')',
  E'c.status_banco in (''em_processo'', ''inativo'', ''expurgado'')');
select pg_temp.remendar('public.fn_gerar_sugestoes_sanitizacao(text,boolean)'::regprocedure,
  E'''Candidato entrou em processo ou foi excluído''',
  E'''Candidato entrou em processo, foi inativado ou teve os dados excluídos''');

-- Pendências de quem já está inativo perdem o sentido (em produção não há nenhuma)
update public.sanitizacao_sugestoes s
   set status = 'expirada', decidido_em = now(), observacao = 'Candidato já estava inativo'
  from public.candidatos c
 where c.id = s.candidato_id and s.status = 'pendente' and c.status_banco = 'inativo';
