-- Testes da sanitização (roda depois de 020–023; também vale depois de 025). Termina em ROLLBACK.
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
-- candidato com análise boa e recente (não entra na lista por si só)
create or replace function pg_temp.novo(p_nome text, p_hash text default null, p_analise boolean default true) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into candidatos (nome, hash_identidade, telefone_e164, email, data_entrada, ultima_atualizacao)
    values (p_nome, p_hash, null, null, now(), now()) returning id into v;
  if p_analise then
    insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia)
      values (v, 1, 'Logística', 'Auxiliar', 'pleno', 90, 'teste');
  end if;
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
  v1 uuid; v2 uuid; v3 uuid;
  ok uuid; mov uuid; reprov uuid; reprov_aprov uuid; ader uuid; dados uuid; dados_pend uuid;
  dup_velho uuid; dup_novo uuid; prazo uuid; prazo_consent uuid; multi uuid; proc uuid; perm uuid; adiada uuid;
  cand_id uuid; s text; r jsonb; n int; sug uuid; ciclo uuid;
begin
  select id into v1 from vagas where status = 'ativo' order by titulo limit 1 offset 0;
  select id into v2 from vagas where status = 'ativo' order by titulo limit 1 offset 1;
  select id into v3 from vagas where status = 'ativo' order by titulo limit 1 offset 2;

  -- ── parâmetros: padrão e tolerância a valor ruim ──
  assert (fn_sanitizacao_parametros() ->> 'meses_sem_movimentacao') = '6', 'padrão 6 meses';
  assert (fn_sanitizacao_parametros() -> 'pesos' ->> 'prazo_retencao') = '4', 'peso padrão';
  update configuracoes set valor = '"abc"' where chave = 'sanitizacao_reprovacoes_max';
  assert (fn_sanitizacao_parametros() ->> 'reprovacoes_max') = '3', 'valor inválido cai no padrão';
  update configuracoes set valor = to_jsonb(3) where chave = 'sanitizacao_reprovacoes_max';
  update configuracoes set valor = '{"prazo_retencao": 10}'::jsonb where chave = 'sanitizacao_pesos';
  assert (fn_sanitizacao_parametros() -> 'pesos' ->> 'prazo_retencao') = '10'
     and (fn_sanitizacao_parametros() -> 'pesos' ->> 'duplicidade') = '3', 'pesos parciais mesclam com o padrão';
  update configuracoes set valor = '{"sem_movimentacao":2,"reprovacoes":2,"baixa_aderencia":1,"dados_incompletos":2,"duplicidade":3,"prazo_retencao":4,"limite_alta":4,"limite_media":2}'::jsonb
   where chave = 'sanitizacao_pesos';

  -- ── cada critério isolado ──
  ok  := pg_temp.novo('Ok Recente');
  assert pg_temp.motivos(ok) is null, 'candidato recente e bem classificado não entra na lista';

  mov := pg_temp.novo('Parado');
  update candidatos set ultima_movimentacao = now() - interval '8 months' where id = mov;
  assert pg_temp.motivos(mov) = 'sem_movimentacao|2|media', 'sem movimentação: ' || pg_temp.motivos(mov);

  reprov := pg_temp.novo('Reprovado Tres');
  insert into candidaturas (candidato_id, vaga_id, status) values (reprov, v1, 'reprovado'), (reprov, v2, 'reprovado'), (reprov, v3, 'reprovado');
  assert pg_temp.motivos(reprov) = 'reprovacoes|2|media', 'reprovado em 3 vagas: ' || coalesce(pg_temp.motivos(reprov), 'null');

  reprov_aprov := pg_temp.novo('Reprovado Mas Aprovado');
  insert into candidaturas (candidato_id, vaga_id, status) values
    (reprov_aprov, v1, 'reprovado'), (reprov_aprov, v2, 'reprovado'), (reprov_aprov, v3, 'reprovado');
  update candidaturas set status = 'aprovado', encerrada_em = null where candidato_id = reprov_aprov and vaga_id = v3;
  assert pg_temp.motivos(reprov_aprov) is null, 'com uma aprovação, reprovações não contam';

  -- duas reprovações na MESMA vaga contam como uma só vaga
  cand_id := pg_temp.novo('Reprovado Mesma Vaga');
  insert into candidaturas (candidato_id, vaga_id, status) values (cand_id, v1, 'reprovado'), (cand_id, v1, 'reprovado'), (cand_id, v2, 'reprovado');
  assert pg_temp.motivos(cand_id) is null, 'vagas diferentes é que contam';

  ader := pg_temp.novo('Baixa Aderencia');
  insert into candidaturas (candidato_id, vaga_id, status) values (ader, v1, 'cancelado') returning id into cand_id;
  insert into avaliacoes (candidatura_id, vaga_id, nota, versao_criterios, modelo_ia) values (cand_id, v1, 20, 1, 'teste');
  assert pg_temp.motivos(ader) = 'baixa_aderencia|1|baixa', 'baixa aderência: ' || coalesce(pg_temp.motivos(ader), 'null');

  dados := pg_temp.novo('Sem Analise', null, false);
  assert pg_temp.motivos(dados) = 'dados_incompletos|2|media', 'sem análise: ' || coalesce(pg_temp.motivos(dados), 'null');
  dados_pend := pg_temp.novo('Analise Pendente', null, false);
  update candidatos set reanalise_solicitada_em = now() where id = dados_pend;
  assert pg_temp.motivos(dados_pend) is null, 'análise pendente não conta como dado incompleto';
  cand_id := pg_temp.novo('Confianca Baixa');
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia)
    values (cand_id, 2, 'Logística', 'Auxiliar', 'pleno', 30, 'teste');
  assert pg_temp.motivos(cand_id) = 'dados_incompletos|2|media', 'confiança abaixo do mínimo';

  dup_velho := pg_temp.novo('Duplicado Mesmo Hash', 'hash-dup');
  update candidatos set ultima_atualizacao = now() - interval '5 days' where id = dup_velho;
  dup_novo  := pg_temp.novo('Duplicado Mesmo Hash', 'hash-dup');
  assert pg_temp.motivos(dup_velho) = 'duplicidade|3|media', 'o mais antigo do par é sugerido: ' || coalesce(pg_temp.motivos(dup_velho), 'null');
  assert pg_temp.motivos(dup_novo) is null, 'o mais recente fica';
  -- mesmo telefone mas nomes diferentes (família) NÃO é duplicidade
  cand_id := pg_temp.novo('Maria Aparecida Souza');
  update candidatos set telefone_e164 = '5561999990000' where id = cand_id;
  update candidatos set ultima_atualizacao = now() - interval '9 days' where id = cand_id;   -- (o gatilho carimba "agora" ao mudar dados)
  perform pg_temp.novo('Jose Roberto Lima');
  update candidatos set telefone_e164 = '5561999990000' where nome = 'Jose Roberto Lima';
  assert pg_temp.motivos(cand_id) is null, 'mesmo telefone com nomes diferentes não é duplicidade';
  -- mesmo telefone e nome parecido é
  perform pg_temp.novo('Maria A Souza');
  update candidatos set telefone_e164 = '5561999990000' where nome = 'Maria A Souza';
  assert pg_temp.motivos(cand_id) = 'duplicidade|3|media', 'telefone igual + nome parecido: ' || coalesce(pg_temp.motivos(cand_id), 'null');

  prazo := pg_temp.novo('Prazo Vencido');
  update candidatos set data_entrada = now() - interval '30 months' where id = prazo;
  assert pg_temp.motivos(prazo) = 'prazo_retencao|4|alta', 'prazo LGPD: ' || coalesce(pg_temp.motivos(prazo), 'null');
  prazo_consent := pg_temp.novo('Prazo Com Consentimento');
  update candidatos set data_entrada = now() - interval '30 months', consentimento_em = now() - interval '2 months' where id = prazo_consent;
  assert pg_temp.motivos(prazo_consent) is null, 'consentimento recente renova o prazo';

  multi := pg_temp.novo('Varios Motivos');
  update candidatos set data_entrada = now() - interval '30 months', ultima_movimentacao = now() - interval '9 months' where id = multi;
  assert pg_temp.motivos(multi) = 'sem_movimentacao,prazo_retencao|6|alta', 'soma de motivos: ' || coalesce(pg_temp.motivos(multi), 'null');

  -- quem está fora do alcance
  proc := pg_temp.novo('Em Processo');
  update candidatos set ultima_movimentacao = now() - interval '9 months' where id = proc;
  insert into candidaturas (candidato_id, vaga_id, status) values (proc, v1, 'aguardando');
  update candidatos set ultima_movimentacao = now() - interval '9 months' where id = proc;
  assert pg_temp.motivos(proc) is null, 'candidato em processo nunca é sugerido';
  perm := pg_temp.novo('Retencao Permanente');
  update candidatos set ultima_movimentacao = now() - interval '9 months', retencao_permanente = true where id = perm;
  assert pg_temp.motivos(perm) is null, 'retenção permanente (contratado) fica de fora';
  adiada := pg_temp.novo('Adiada');
  update candidatos set ultima_movimentacao = now() - interval '9 months', sanitizacao_adiada_ate = now() + interval '1 month' where id = adiada;
  assert pg_temp.motivos(adiada) is null, 'adiada não é sugerida de novo';

  -- ── regras configuráveis: mudar o parâmetro muda o resultado ──
  update configuracoes set valor = to_jsonb(12) where chave = 'sanitizacao_meses_sem_movimentacao';
  assert pg_temp.motivos(mov) is null, '8 meses não passa de um limite de 12';
  update configuracoes set valor = to_jsonb(6) where chave = 'sanitizacao_meses_sem_movimentacao';

  -- ── geração: job (service_role) x painel ──
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar($f$select fn_gerar_sugestoes_sanitizacao('manual', true)$f$, 'Somente o administrador');
  perform pg_temp.deve_falhar($f$select sanitizacao_decidir_lote(array[gen_random_uuid()], 'excluir')$f$, 'Somente o administrador');
  perform pg_temp.como(null);
  r := fn_gerar_sugestoes_sanitizacao('job');
  assert (r ->> 'gerada')::boolean, 'job gera a lista';
  ciclo := (r ->> 'ciclo_id')::uuid;
  assert (r ->> 'total')::int >= 9, 'sugeridos: ' || (r ->> 'total');   -- os 9 casos abaixo (mais outros, se o banco já tiver candidatos)
  assert (select count(*) from sanitizacao_sugestoes where ciclo_id = ciclo and candidato_id in (ok, proc, perm, adiada, reprov_aprov, dados_pend, dup_novo)) = 0,
    'quem não deve entrar não entrou';
  assert (select count(*) from sanitizacao_sugestoes where ciclo_id = ciclo and candidato_id in (mov, reprov, ader, dados, dup_velho, prazo, multi)) = 7,
    'quem deve entrar entrou';
  assert (select prioridade from sanitizacao_sugestoes where ciclo_id = ciclo and candidato_id = multi) = 'alta', 'prioridade alta';
  r := fn_gerar_sugestoes_sanitizacao('job');
  assert not (r ->> 'gerada')::boolean, 'segunda chamada dentro do intervalo não gera de novo';
  perform pg_temp.como(admin);
  r := fn_gerar_sugestoes_sanitizacao('manual', true);
  perform pg_temp.como(null);
  assert (r ->> 'gerada')::boolean and (r ->> 'total')::int = 0, 'administrador força; quem já está pendente não duplica: ' || r::text;

  -- ── decisões ──
  -- manter: adia e não volta
  select id into sug from sanitizacao_sugestoes where candidato_id = mov and status = 'pendente';
  perform pg_temp.como(beto);
  perform sanitizacao_decidir(sug, 'manter', 'ainda quero acompanhar');
  perform pg_temp.como(null);
  select status || '/' || (decidido_por = beto) || '/' || (adiada_ate > now() + interval '5 months') into s from sanitizacao_sugestoes where id = sug;
  assert s = 'mantido/true/true', 'manter registra quem decidiu e adia: ' || s;
  assert (select sanitizacao_adiada_ate > now() + interval '5 months' from candidatos where id = mov), 'candidato adiado por 6 meses';
  assert pg_temp.motivos(mov) is null, 'mantido não é sugerido de novo';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'inativar')$f$, sug), 'já foi decidida');
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'manter', null, 99)$f$, sug), 'entre 1 e 60');
  perform pg_temp.como(null);

  -- inativar
  select id into sug from sanitizacao_sugestoes where candidato_id = ader and status = 'pendente';
  perform pg_temp.como(beto);
  perform sanitizacao_decidir(sug, 'inativar');
  perform pg_temp.como(null);
  assert (select status_banco from candidatos where id = ader) = 'inativo', 'inativar tira do banco ativo';
  assert (select status from sanitizacao_sugestoes where id = sug) = 'inativado', 'sugestão inativada';

  -- excluir: RH comum não pode; administrador pode; sobra só o esqueleto
  update candidatos set nome = 'Pessoa Real', email = 'real@x.test', telefone = '61999', cidade = 'Gama', uf = 'DF' where id = prazo;
  insert into curriculos (candidato_id, storage_path, nome_arquivo, texto_extraido, origem, email_message_id)
    values (prazo, '2026/09/arquivo-prazo.pdf', 'cv.pdf', 'Texto do currículo com dados pessoais', 'anexo_pdf', 'msg-prazo');
  select id into sug from sanitizacao_sugestoes where candidato_id = prazo and status = 'pendente';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'excluir')$f$, sug), 'Somente o administrador');
  perform pg_temp.como(admin);
  perform sanitizacao_decidir(sug, 'excluir', 'prazo LGPD vencido');
  perform pg_temp.como(null);
  select status_banco::text || '/' || (nome is null) || '/' || (email is null) || '/' || (telefone is null) || '/' || (cidade is null)
         || '/' || (hash_identidade is null) into s from candidatos where id = prazo;
  assert s = 'expurgado/true/true/true/true/true', 'dados pessoais apagados, hash de identidade preservado (dá "true" só se o candidato não tinha hash): ' || s;
  assert (select texto_extraido is null and storage_path is null and email_message_id is null from curriculos where candidato_id = prazo), 'currículo esvaziado';
  assert exists (select 1 from arquivos_para_remover where storage_path = '2026/09/arquivo-prazo.pdf' and removido_em is null), 'arquivo enfileirado para remoção do Storage';
  assert (select count(*) from analises_ia where candidato_id = prazo) = 0, 'análises da IA apagadas';
  assert (select status from sanitizacao_sugestoes where id = sug) = 'excluido', 'sugestão excluída';
  assert exists (select 1 from logs_auditoria where acao = 'sanitizacao_decisao' and entidade_id = prazo and usuario_id = admin), 'decisão auditada com quem decidiu';
  assert exists (select 1 from logs_auditoria where acao = 'exclusao_manual_lgpd' and entidade_id = prazo), 'exclusão auditada';
  assert not exists (select 1 from logs_auditoria where entidade_id = prazo and (dados_depois::text ilike '%Pessoa Real%' or detalhe ilike '%Pessoa Real%')),
    'a auditoria não guarda dados pessoais';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select editar_candidato(%L, '{"nome":"x"}')$f$, prazo), 'já excluído');
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, prazo, v1), 'foram excluídos');
  perform pg_temp.como(null);

  -- candidato que entrou em processo depois da sugestão: inativar/excluir recusam
  select id into sug from sanitizacao_sugestoes where candidato_id = reprov and status = 'pendente';
  insert into candidaturas (candidato_id, vaga_id, status) values (reprov, v1, 'aguardando');
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'inativar')$f$, sug), 'entrou em processo');
  perform pg_temp.como(null);

  -- lote: 3 pendentes + 1 já decidida → 3 ok e 1 falha, sem desfazer os outros
  perform pg_temp.como(beto);
  r := sanitizacao_decidir_lote(
         array(select id from sanitizacao_sugestoes where candidato_id in (dados, dup_velho, multi) and status = 'pendente')
         || (select id from sanitizacao_sugestoes where candidato_id = mov limit 1),
         'manter', 'lote de teste', 3);
  perform pg_temp.como(null);
  assert (r ->> 'processadas')::int = 3 and jsonb_array_length(r -> 'falhas') = 1, 'lote parcial: ' || r::text;
  assert (select count(*) from sanitizacao_sugestoes where candidato_id in (dados, dup_velho, multi) and status = 'mantido') = 3, 'lote aplicou nos válidos';

  -- ── exclusão a pedido do titular (LGPD art. 18): só administrador; fecha candidatura aberta ──
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select excluir_dados_candidato(%L)$f$, proc), 'Somente o administrador');
  perform pg_temp.como(admin);
  perform excluir_dados_candidato(proc, 'pedido do titular');
  perform pg_temp.como(null);
  assert (select status_banco from candidatos where id = proc) = 'expurgado', 'titular: candidato excluído';
  assert (select status from candidaturas where candidato_id = proc) = 'cancelado', 'titular: candidatura aberta cancelada';

  -- o hash de identidade sobrevive ao expurgo: é ele que reconhece um reenvio futuro
  cand_id := pg_temp.novo('Com Hash Para Expurgo', 'hash-que-deve-sobrar');
  perform pg_temp.como(admin);
  perform excluir_dados_candidato(cand_id);
  perform pg_temp.como(null);
  assert (select status_banco::text || '/' || hash_identidade || '/' || (nome is null) from candidatos where id = cand_id)
         = 'expurgado/hash-que-deve-sobrar/true', 'expurgo preserva o hash de identidade';

  -- ── manutenção diária: sem apagar sozinha; devolve a fila de arquivos ──
  r := fn_manutencao_diaria();
  assert r ? 'arquivos_para_remover' and not r ? 'inativadas' and not r ? 'expurgadas', 'manutenção não inativa nem expurga';
  assert r -> 'arquivos_para_remover' @> '["2026/09/arquivo-prazo.pdf"]'::jsonb, 'fila de arquivos vem da manutenção';
  assert fn_marcar_arquivos_removidos(array['2026/09/arquivo-prazo.pdf']) = 1, 'marca como removido';
  assert not (fn_manutencao_diaria() -> 'arquivos_para_remover' @> '["2026/09/arquivo-prazo.pdf"]'::jsonb), 'sai da fila depois de removido';
  assert not exists (select 1 from pg_proc where proname in ('fn_inativar_candidaturas_vencidas', 'fn_expurgar_candidaturas_inativas')),
    'funções da retenção automática removidas';
  assert not exists (select 1 from configuracoes where chave like 'retencao_meses%'), 'parâmetros antigos removidos';

  raise notice 'TESTE DA SANITIZAÇÃO: tudo certo';
end $$;

rollback;
