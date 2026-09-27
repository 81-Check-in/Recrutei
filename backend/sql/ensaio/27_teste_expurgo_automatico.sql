-- Testes da 047: a sanitização só inativa e o expurgo é automático, N meses depois de inativar. Termina em ROLLBACK.
-- (o expurgo em si — o que é apagado e o que sobra — é o de sempre, conferido também em 11_teste_sanitizacao.sql)
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.como(p_usuario uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_usuario::text, ''), true);
  reset role;
  if p_usuario is not null then set local role authenticated; end if;
end $$;
create or replace function pg_temp.deve_falhar(p_sql text, p_trecho text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_trecho in sqlerrm) = 0 then
      raise exception 'falhou com a mensagem errada. Esperado conter [%], veio [%]', p_trecho, sqlerrm;
    end if;
    return;
  end;
  raise exception 'deveria ter falhado (esperado: %)', p_trecho;
end $$;
-- candidato inativo há N meses, com dados pessoais e um arquivo de currículo
create or replace function pg_temp.inativo(p_nome text, p_meses numeric, p_hash text default null, p_arquivo text default null) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into candidatos (nome, hash_identidade, email, telefone, cidade, data_entrada, ultima_atualizacao)
    values (p_nome, p_hash, lower(replace(p_nome, ' ', '.')) || '@x.test', '61999', 'Gama', now(), now()) returning id into v;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia)
    values (v, 1, 'Logística', 'Auxiliar', 'pleno', 90, 'teste');
  if p_arquivo is not null then
    insert into curriculos (candidato_id, storage_path, nome_arquivo, texto_extraido, origem)
      values (v, p_arquivo, 'cv.pdf', 'Texto com dados pessoais de ' || p_nome, 'anexo_pdf');
  end if;
  update candidatos set status_banco = 'inativo', inativado_em = now() - make_interval(secs => p_meses * 30 * 86400),
         motivo_inativacao = 'teste' where id = v;
  return v;
end $$;
-- candidato ATIVO, muito antigo e parado (nunca é expurgado: só inativo é)
create or replace function pg_temp.novo_ativo(p_nome text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into candidatos (nome, email, data_entrada, ultima_atualizacao) values (p_nome, 'ativo@x.test', now(), now()) returning id into v;
  update candidatos set data_entrada = now() - interval '30 months', ultima_movimentacao = now() - interval '30 months' where id = v;
  return v;
end $$;
create or replace function pg_temp.expurgado(p_cand uuid) returns boolean language sql as $$
  select status_banco = 'expurgado' and nome is null and email is null and telefone is null from public.candidatos where id = p_cand
$$;
create or replace function pg_temp.motivos(p_cand uuid) returns text language sql as $$
  select coalesce(array_to_string(motivos, ','), '-') || '|' || pontos || '|' || prioridade
    from public.fn_sanitizacao_avaliar(public.fn_sanitizacao_parametros()) where candidato_id = p_cand
$$;

-- gatilho de teste: o expurgo de um candidato chamado "Explode" falha (para provar que um erro não trava os demais)
create function public.tmp_falha_no_expurgo() returns trigger language plpgsql as $$
begin
  if old.nome = 'Explode' and new.status_banco = 'expurgado' then raise exception 'boom de teste'; end if;
  return new;
end $$;
create trigger tmp_falha_no_expurgo before update on public.candidatos for each row execute function public.tmp_falha_no_expurgo();

do $$
declare
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  v_venc uuid; v_5m uuid; v_perm uuid; v_proc uuid; v_reativado uuid; v_reinativado uuid; v_ativo_velho uuid; v_negra uuid;
  v_falha uuid; v_ok1 uuid; v_ok2 uuid; v_13m uuid; v_lim1 uuid; v_lim2 uuid; v_lim3 uuid; v_ver uuid;
  r jsonb;
begin
  -- ── parâmetro: padrão de 6 meses, mínimo de 1, valor ruim cai no padrão ──
  assert (select valor from configuracoes where chave = 'expurgo_meses_apos_inativar') = to_jsonb(6), 'padrão: 6 meses';
  assert fn_expurgo_meses() = 6, 'fn_expurgo_meses: padrão 6';
  update configuracoes set valor = '"abc"' where chave = 'expurgo_meses_apos_inativar';
  assert fn_expurgo_meses() = 6, 'valor inválido cai no padrão';
  update configuracoes set valor = to_jsonb(0) where chave = 'expurgo_meses_apos_inativar';
  assert fn_expurgo_meses() = 1, 'zero não vale: mínimo de 1 mês';
  update configuracoes set valor = to_jsonb(-5) where chave = 'expurgo_meses_apos_inativar';
  assert fn_expurgo_meses() = 1, 'negativo não vale: mínimo de 1 mês';
  update configuracoes set valor = to_jsonb(6) where chave = 'expurgo_meses_apos_inativar';

  -- ── privilégios: só o robô (service_role) executa ──
  assert not has_function_privilege('anon', 'public.fn_expurgar_inativos_vencidos(integer)', 'execute'), 'anônimo não executa o expurgo';
  assert not has_function_privilege('authenticated', 'public.fn_expurgar_inativos_vencidos(integer)', 'execute'), 'usuário do painel não executa o expurgo';
  assert not has_function_privilege('authenticated', 'public.fn_manutencao_diaria()', 'execute'), 'usuário do painel não executa a manutenção';
  assert not has_function_privilege('authenticated', 'public.fn_expurgo_meses()', 'execute'), 'nem o auxiliar';
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    assert has_function_privilege('service_role', 'public.fn_expurgar_inativos_vencidos(integer)', 'execute'), 'o robô executa o expurgo';
  end if;

  -- Ponto de partida limpo: o que já era inativo na base de teste não conta (a contagem recomeça agora)
  update candidatos set inativado_em = now() where status_banco = 'inativo';
  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int = 0 and (r ->> 'restantes')::int = 0, 'nada vencido no começo: ' || r::text;

  -- ── quem é expurgado e quem não é ──
  v_venc        := pg_temp.inativo('Inativo Vencido', 7, 'hash-vencido', '2026/09/vencido.pdf');
  v_5m          := pg_temp.inativo('Inativo Cinco Meses', 5, 'hash-cinco', '2026/09/cinco.pdf');
  v_perm        := pg_temp.inativo('Contratado Permanente', 12, 'hash-perm', '2026/09/perm.pdf');
  update candidatos set retencao_permanente = true where id = v_perm;
  v_proc        := pg_temp.inativo('Em Processo Antigo', 12);
  update candidatos set status_banco = 'em_processo' where id = v_proc;
  v_ativo_velho := pg_temp.novo_ativo('Ativo Muito Antigo');
  v_negra       := pg_temp.inativo('Bloqueado Vencido', 8, 'hash-negra');
  update candidatos set lista_negra = true where id = v_negra;

  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int = 2 and (r ->> 'falhas')::int = 0 and (r ->> 'restantes')::int = 0 and (r ->> 'meses')::int = 6,
    'expurgou os 2 vencidos (inativo há 7 e 8 meses): ' || r::text;
  assert pg_temp.expurgado(v_venc), 'inativo há 7 meses foi expurgado';
  assert (select hash_identidade from candidatos where id = v_venc) = 'hash-vencido', 'sobrou o hash de identidade (reconhece o reenvio)';
  assert (select expurgado_em is not null and inativado_em is not null from candidatos where id = v_venc), 'sobram as datas';
  assert (select texto_extraido is null and storage_path is null from curriculos where candidato_id = v_venc), 'currículo esvaziado';
  assert exists (select 1 from arquivos_para_remover where storage_path = '2026/09/vencido.pdf' and removido_em is null), 'arquivo na fila do Storage';
  assert not pg_temp.expurgado(v_5m) and (select nome from candidatos where id = v_5m) = 'Inativo Cinco Meses', 'inativo há 5 meses não é tocado';
  assert not exists (select 1 from arquivos_para_remover where storage_path = '2026/09/cinco.pdf'), 'arquivo de quem não venceu fica';
  assert not pg_temp.expurgado(v_perm) and (select status_banco::text from candidatos where id = v_perm) = 'inativo',
    'contratado (retenção permanente) nunca é expurgado, por mais tempo que tenha';
  assert (select status_banco::text from candidatos where id = v_proc) = 'em_processo', 'quem não está inativo não é tocado';
  assert (select status_banco::text || '/' || (nome is not null) from candidatos where id = v_ativo_velho) = 'ativo/true',
    'ativo não é expurgado, por mais antigo que seja';
  assert pg_temp.expurgado(v_negra) and (select lista_negra from candidatos where id = v_negra), 'o bloqueio sobrevive ao expurgo';
  assert exists (select 1 from logs_auditoria where acao = 'exclusao_manual_lgpd' and entidade_id = v_venc and detalhe like 'Expurgo automático: mais de 6 meses inativo'),
    'cada expurgo auditado, com o motivo';
  assert exists (select 1 from logs_auditoria where acao = 'expurgo_automatico' and entidade = 'candidatos' and (dados_depois ->> 'expurgados')::int = 2),
    'resumo da execução auditado';
  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int = 0, 'segunda execução não faz nada (idempotente)';
  assert (select count(*) from logs_auditoria where acao = 'expurgo_automatico' and entidade = 'candidatos') = 1, 'execução sem nada a fazer não polui a auditoria';

  -- ── reativar (ou inativar de novo) reinicia a contagem ──
  v_reativado := pg_temp.inativo('Reativado', 7);
  perform pg_temp.como(beto);
  perform alterar_status_banco(v_reativado, 'ativo');
  perform pg_temp.como(null);
  assert (select status_banco::text || '/' || (inativado_em is null) from candidatos where id = v_reativado) = 'ativo/true', 'reativar zera a data';
  v_reinativado := pg_temp.inativo('Reinativado', 7);
  perform pg_temp.como(beto);
  perform alterar_status_banco(v_reinativado, 'ativo');
  perform alterar_status_banco(v_reinativado, 'inativo');
  perform pg_temp.como(null);
  assert (select inativado_em > now() - interval '1 minute' from candidatos where id = v_reinativado), 'inativar de novo recomeça a contagem';
  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int = 0 and not pg_temp.expurgado(v_reativado) and not pg_temp.expurgado(v_reinativado),
    'reativado e reinativado não são expurgados: ' || r::text;

  -- ── o prazo é parâmetro ──
  v_13m := pg_temp.inativo('Inativo Treze Meses', 13);
  update configuracoes set valor = to_jsonb(12) where chave = 'expurgo_meses_apos_inativar';
  perform pg_temp.inativo('Inativo Sete Meses B', 7, 'hash-7b');
  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int = 1 and (r ->> 'meses')::int = 12 and pg_temp.expurgado(v_13m), 'com 12 meses só o de 13 vence: ' || r::text;
  update configuracoes set valor = to_jsonb(6) where chave = 'expurgo_meses_apos_inativar';
  assert (select count(*) from candidatos where nome = 'Inativo Sete Meses B') = 1, 'o de 7 meses seguiu intocado';
  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int = 1, 'voltando a 6 meses, o de 7 vence: ' || r::text;

  -- ── limite por execução: o resto sai no dia seguinte ──
  v_lim1 := pg_temp.inativo('Lote Um', 8);
  v_lim2 := pg_temp.inativo('Lote Dois', 9);
  v_lim3 := pg_temp.inativo('Lote Tres', 10);
  r := fn_expurgar_inativos_vencidos(2);
  assert (r ->> 'expurgados')::int = 2 and (r ->> 'restantes')::int = 1, 'limite de 2: ' || r::text;
  assert pg_temp.expurgado(v_lim3) and pg_temp.expurgado(v_lim2) and not pg_temp.expurgado(v_lim1), 'os mais antigos primeiro';
  r := fn_expurgar_inativos_vencidos(2);
  assert (r ->> 'expurgados')::int = 1 and (r ->> 'restantes')::int = 0 and pg_temp.expurgado(v_lim1), 'o resto sai na execução seguinte';

  -- ── um candidato que falha não trava os demais ──
  v_falha := pg_temp.inativo('Explode', 9);
  v_ok1   := pg_temp.inativo('Depois Um', 8);
  v_ok2   := pg_temp.inativo('Depois Dois', 7);
  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int = 2 and (r ->> 'falhas')::int = 1 and (r ->> 'restantes')::int = 1, 'uma falha, dois expurgados: ' || r::text;
  assert pg_temp.expurgado(v_ok1) and pg_temp.expurgado(v_ok2) and not pg_temp.expurgado(v_falha), 'os outros foram apagados; o que falhou continua inteiro';
  assert (select nome from candidatos where id = v_falha) = 'Explode', 'a falha desfez só o dele';
  drop trigger tmp_falha_no_expurgo on public.candidatos;
  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int = 1 and pg_temp.expurgado(v_falha), 'sem o defeito, o pendente é expurgado na execução seguinte';

  -- ── manutenção diária: expurga e devolve os arquivos NA MESMA chamada ──
  v_ver := pg_temp.inativo('Vence Na Manutencao', 7, 'hash-manut', '2026/09/manutencao.pdf');
  r := fn_manutencao_diaria();
  assert pg_temp.expurgado(v_ver), 'a manutenção diária expurga os vencidos';
  assert (r -> 'expurgo' ->> 'expurgados')::int = 1, 'e informa quantos: ' || r::text;
  assert r -> 'arquivos_para_remover' @> '["2026/09/manutencao.pdf"]'::jsonb, 'o arquivo de quem acabou de ser apagado já vem na lista do dia';

  -- se o expurgo quebrar por inteiro, a manutenção segue e informa o erro
  create or replace function public.fn_expurgar_inativos_vencidos(p_limite integer default 300) returns jsonb
    language plpgsql as $f$ begin raise exception 'quebrou de propósito'; end $f$;
  r := fn_manutencao_diaria();
  assert r -> 'expurgo' ->> 'erro' = 'quebrou de propósito' and r ? 'arquivos_para_remover' and r ? 'sanitizacao_pendentes',
    'falha no expurgo não derruba a manutenção: ' || r::text;

  raise notice 'TESTE DO EXPURGO AUTOMÁTICO (parte 1: expurgo): tudo certo';
end $$;

-- (a redefinição acima, que quebra o expurgo de propósito, só vale dentro deste teste: tudo termina em ROLLBACK)
rollback;

begin;
create or replace function pg_temp.como(p_usuario uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_usuario::text, ''), true);
  reset role;
  if p_usuario is not null then set local role authenticated; end if;
end $$;
create or replace function pg_temp.deve_falhar(p_sql text, p_trecho text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_trecho in sqlerrm) = 0 then
      raise exception 'falhou com a mensagem errada. Esperado conter [%], veio [%]', p_trecho, sqlerrm;
    end if;
    return;
  end;
  raise exception 'deveria ter falhado (esperado: %)', p_trecho;
end $$;
create or replace function pg_temp.novo(p_nome text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into candidatos (nome, data_entrada, ultima_atualizacao) values (p_nome, now(), now()) returning id into v;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia)
    values (v, 1, 'Logística', 'Auxiliar', 'pleno', 90, 'teste');
  return v;
end $$;
create or replace function pg_temp.motivos(p_cand uuid) returns text language sql as $$
  select coalesce(array_to_string(motivos, ','), '-') || '|' || pontos || '|' || prioridade
    from public.fn_sanitizacao_avaliar(public.fn_sanitizacao_parametros()) where candidato_id = p_cand
$$;

do $$
declare
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  v_ativo uuid; v_inativo uuid; v_prazo_inativo uuid; v_man uuid; v_sug uuid; v_sug2 uuid; v_dec uuid;
  ant timestamptz;
begin
  -- ── o inativo NÃO volta para a fila (antes voltava toda semana) ──
  v_ativo := pg_temp.novo('Ativo Parado');
  v_inativo := pg_temp.novo('Inativo Parado');
  update candidatos set ultima_movimentacao = now() - interval '9 months' where id in (v_ativo, v_inativo);
  update candidatos set status_banco = 'inativo', inativado_em = now() - interval '2 months' where id = v_inativo;
  update candidatos set ultima_movimentacao = now() - interval '9 months' where id = v_inativo;
  assert pg_temp.motivos(v_ativo) = 'sem_movimentacao|2|media', 'ativo parado continua sendo sugerido: ' || coalesce(pg_temp.motivos(v_ativo), 'null');
  assert pg_temp.motivos(v_inativo) is null, 'inativo parado não é sugerido: ' || coalesce(pg_temp.motivos(v_inativo), 'null');
  v_prazo_inativo := pg_temp.novo('Inativo Prazo Legal');
  update candidatos set status_banco = 'inativo', inativado_em = now(), data_entrada = now() - interval '30 months' where id = v_prazo_inativo;
  assert pg_temp.motivos(v_prazo_inativo) is null, 'nem o prazo legal traz o inativo de volta (o expurgo cuida dele): ' || coalesce(pg_temp.motivos(v_prazo_inativo), 'null');
  perform fn_gerar_sugestoes_sanitizacao('job', true);
  assert not exists (select 1 from sanitizacao_sugestoes where candidato_id in (v_inativo, v_prazo_inativo)), 'a lista gerada não tem inativos';
  assert exists (select 1 from sanitizacao_sugestoes where candidato_id = v_ativo and status = 'pendente'), 'a lista gerada tem o ativo parado';

  -- ── inativar uma vez basta: o ciclo "inativa → volta a semana seguinte → inativa" acabou ──
  select id into v_sug from sanitizacao_sugestoes where candidato_id = v_ativo and status = 'pendente';
  perform pg_temp.como(beto);
  perform sanitizacao_decidir(v_sug, 'inativar');
  perform pg_temp.como(null);
  update candidatos set ultima_movimentacao = now() - interval '2 months' where id = v_ativo;    -- passa o portão de novo
  update sanitizacao_ciclos set gerada_em = now() - interval '8 days';
  perform fn_gerar_sugestoes_sanitizacao('job');
  assert not exists (select 1 from sanitizacao_sugestoes where candidato_id = v_ativo and status = 'pendente'), 'inativado não volta à fila na semana seguinte';

  -- ── inativado à mão depois da sugestão: a pendência sai da fila; decidir na mão não a reabre ──
  v_man := pg_temp.novo('Inativado A Mao');
  update candidatos set ultima_movimentacao = now() - interval '2 months' where id = v_man;
  perform pg_temp.como(beto);
  v_sug := (sanitizacao_enviar_candidato(v_man) ->> 'sugestao_id')::uuid;
  perform alterar_status_banco(v_man, 'inativo');
  perform pg_temp.como(null);
  update candidatos set inativado_em = now() - interval '3 months' where id = v_man;
  ant := (select inativado_em from candidatos where id = v_man);
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'manter')$f$, v_sug), 'já foi inativado');
  perform pg_temp.como(null);
  assert (select status from sanitizacao_sugestoes where id = v_sug) = 'pendente', 'manter num inativo é recusado e não decide nada';
  perform pg_temp.como(beto);
  perform sanitizacao_decidir(v_sug, 'inativar');
  perform pg_temp.como(null);
  assert (select status from sanitizacao_sugestoes where id = v_sug) = 'inativado', 'inativar num já inativo só fecha a sugestão';
  assert (select inativado_em from candidatos where id = v_man) = ant, 'e não reinicia a contagem do expurgo';

  v_dec := pg_temp.novo('Inativado A Mao Sem Decidir');
  perform pg_temp.como(beto);
  v_sug2 := (sanitizacao_enviar_candidato(v_dec) ->> 'sugestao_id')::uuid;
  perform alterar_status_banco(v_dec, 'inativo');
  perform pg_temp.como(null);
  update sanitizacao_ciclos set gerada_em = now() - interval '8 days';
  perform fn_gerar_sugestoes_sanitizacao('job');
  assert (select status || '/' || observacao from sanitizacao_sugestoes where id = v_sug2) = 'expirada/Candidato entrou em processo, foi inativado ou teve os dados excluídos',
    'a rotina tira da fila quem foi inativado à mão';

  -- ── o botão "Sanitizar" (qualquer usuário) recusa quem já está inativo ──
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select sanitizacao_enviar_candidato(%L)$f$, v_inativo), 'já está inativo');
  perform pg_temp.como(null);

  -- ── excluir não existe mais na fila: nem para o administrador, nem em lote ──
  perform pg_temp.como(admin);
  perform pg_temp.deve_falhar($f$select sanitizacao_decidir(gen_random_uuid(), 'excluir')$f$, 'apagados sozinhos depois de 6 meses');
  perform pg_temp.deve_falhar($f$select sanitizacao_decidir_lote(array[gen_random_uuid()], 'excluir')$f$, 'só mantém ou inativa');
  perform pg_temp.como(null);
  perform pg_temp.deve_falhar($f$select fn_sanitizacao_aplicar(gen_random_uuid(), 'excluir', null, null, null, true)$f$, 'só mantém ou inativa');

  -- ── reaplicar a 047 sobre o que já foi remendado não quebra (idempotência) é conferido por ensaio.sh ──
  assert position('c.status_banco = ''ativo''' in pg_get_functiondef('public.fn_sanitizacao_avaliar(jsonb)'::regprocedure)) > 0
     and position('c.status_banco in (''ativo'', ''inativo'')' in pg_get_functiondef('public.fn_sanitizacao_avaliar(jsonb)'::regprocedure)) = 0,
    'a avaliação só olha ativos';

  raise notice 'TESTE DO EXPURGO AUTOMÁTICO (parte 2: sanitização só inativa): tudo certo';
end $$;

rollback;
