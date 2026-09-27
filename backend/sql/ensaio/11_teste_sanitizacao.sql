-- Testes da sanitização (roda depois de 020–023, 043 e 047; também vale depois de 025). Termina em ROLLBACK.
-- Regra da 043: só é sugerido quem ficou 1 mês sem NENHUMA alteração, contado da entrada no sistema.
-- Regra da 047: a fila só mantém ou inativa; o expurgo é automático, N meses depois de inativar (ver 27_teste_expurgo_automatico.sql).
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
-- deixa o candidato parado há N dias (passa o portão de 1 mês quando N > 31)
create or replace function pg_temp.parado(p_cand uuid, p_dias int default 40) returns void language sql as $$
  update public.candidatos set ultima_movimentacao = now() - make_interval(days => p_dias) where id = p_cand
$$;
create or replace function pg_temp.tem(p_cand uuid, p_motivo text) returns boolean language sql as $$
  select coalesce((select p_motivo = any (motivos) from public.fn_sanitizacao_avaliar(public.fn_sanitizacao_parametros())
                    where candidato_id = p_cand), false)
$$;
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
  dados_novo uuid; email_velho uuid; manual uuid; manual2 uuid; sug_manual uuid;
begin
  select id into v1 from vagas where status = 'ativo' order by titulo limit 1 offset 0;
  select id into v2 from vagas where status = 'ativo' order by titulo limit 1 offset 1;
  select id into v3 from vagas where status = 'ativo' order by titulo limit 1 offset 2;

  -- ── parâmetros: padrão e tolerância a valor ruim ──
  assert (fn_sanitizacao_parametros() ->> 'meses_sem_movimentacao') = '1', 'padrão 1 mês sem alteração';
  assert (fn_sanitizacao_parametros() ->> 'intervalo_dias') = '7', 'a lista é conferida toda semana';
  assert not exists (select 1 from configuracoes where chave = 'sanitizacao_intervalo_meses'), 'intervalo em meses foi trocado por dias';
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

  -- o PORTÃO: um candidato que entrou hoje, mesmo com o e-mail de meses atrás, não é sugerido
  email_velho := pg_temp.novo('Email Antigo Entrou Hoje');
  insert into curriculos (candidato_id, texto_extraido, origem, recebido_em)
    values (email_velho, 'CV', 'anexo_pdf', now() - interval '60 days');       -- e-mail de 2 meses atrás, gravado agora
  assert pg_temp.motivos(email_velho) is null, 'e-mail antigo que entrou hoje não é sugerido: ' || coalesce(pg_temp.motivos(email_velho), 'null');
  perform pg_temp.parado(email_velho, 20);
  assert pg_temp.motivos(email_velho) is null, '20 dias no sistema ainda não vence: ' || coalesce(pg_temp.motivos(email_velho), 'null');
  perform pg_temp.parado(email_velho, 32);
  assert pg_temp.motivos(email_velho) = 'sem_movimentacao|2|media', '1 mês depois de entrar é sugerido: ' || coalesce(pg_temp.motivos(email_velho), 'null');
  assert (select motivo_texto from fn_sanitizacao_avaliar(fn_sanitizacao_parametros()) where candidato_id = email_velho) like 'Sem movimentação há 32 dias (limite: 1 mês)',
    'texto do motivo em dias';
  update candidatos set ultima_movimentacao = now() where id = email_velho;    -- qualquer alteração reinicia a contagem
  assert pg_temp.motivos(email_velho) is null, 'alteração reinicia a contagem';

  reprov := pg_temp.novo('Reprovado Tres');
  insert into candidaturas (candidato_id, vaga_id, status) values (reprov, v1, 'reprovado'), (reprov, v2, 'reprovado'), (reprov, v3, 'reprovado');
  assert pg_temp.motivos(reprov) is null, 'reprovado em 3 vagas mas ainda dentro do 1º mês: ' || coalesce(pg_temp.motivos(reprov), 'null');
  perform pg_temp.parado(reprov);
  assert pg_temp.motivos(reprov) = 'sem_movimentacao,reprovacoes|4|alta', 'reprovado em 3 vagas: ' || coalesce(pg_temp.motivos(reprov), 'null');

  reprov_aprov := pg_temp.novo('Reprovado Mas Aprovado');
  insert into candidaturas (candidato_id, vaga_id, status) values
    (reprov_aprov, v1, 'reprovado'), (reprov_aprov, v2, 'reprovado'), (reprov_aprov, v3, 'reprovado');
  update candidaturas set status = 'aprovado', encerrada_em = null where candidato_id = reprov_aprov and vaga_id = v3;
  perform pg_temp.parado(reprov_aprov);
  assert not pg_temp.tem(reprov_aprov, 'reprovacoes'), 'com uma aprovação, reprovações não contam';

  -- duas reprovações na MESMA vaga contam como uma só vaga
  cand_id := pg_temp.novo('Reprovado Mesma Vaga');
  insert into candidaturas (candidato_id, vaga_id, status) values (cand_id, v1, 'reprovado'), (cand_id, v1, 'reprovado'), (cand_id, v2, 'reprovado');
  perform pg_temp.parado(cand_id);
  assert not pg_temp.tem(cand_id, 'reprovacoes'), 'vagas diferentes é que contam';

  ader := pg_temp.novo('Baixa Aderencia');
  insert into candidaturas (candidato_id, vaga_id, status) values (ader, v1, 'cancelado') returning id into cand_id;
  insert into avaliacoes (candidatura_id, vaga_id, nota, versao_criterios, modelo_ia) values (cand_id, v1, 20, 1, 'teste');
  perform pg_temp.parado(ader);
  assert pg_temp.motivos(ader) = 'sem_movimentacao,baixa_aderencia|3|media', 'baixa aderência: ' || coalesce(pg_temp.motivos(ader), 'null');

  -- "dados incompletos" NÃO sugere no dia da entrada (antes sugeria): também espera o 1º mês
  dados_novo := pg_temp.novo('Sem Analise Recente', null, false);
  assert pg_temp.motivos(dados_novo) is null, 'sem análise mas entrou hoje: ' || coalesce(pg_temp.motivos(dados_novo), 'null');
  dados := pg_temp.novo('Sem Analise', null, false);
  perform pg_temp.parado(dados);
  assert pg_temp.motivos(dados) = 'sem_movimentacao,dados_incompletos|4|alta', 'sem análise: ' || coalesce(pg_temp.motivos(dados), 'null');
  dados_pend := pg_temp.novo('Analise Pendente', null, false);
  update candidatos set reanalise_solicitada_em = now() where id = dados_pend;
  perform pg_temp.parado(dados_pend);
  assert not pg_temp.tem(dados_pend, 'dados_incompletos'), 'análise pendente não conta como dado incompleto';
  cand_id := pg_temp.novo('Confianca Baixa');
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia)
    values (cand_id, 2, 'Logística', 'Auxiliar', 'pleno', 30, 'teste');
  perform pg_temp.parado(cand_id);
  assert pg_temp.motivos(cand_id) = 'sem_movimentacao,dados_incompletos|4|alta', 'confiança abaixo do mínimo';

  dup_velho := pg_temp.novo('Duplicado Mesmo Hash', 'hash-dup');
  update candidatos set ultima_atualizacao = now() - interval '5 days' where id = dup_velho;
  dup_novo  := pg_temp.novo('Duplicado Mesmo Hash', 'hash-dup');
  perform pg_temp.parado(dup_velho);
  assert pg_temp.motivos(dup_velho) = 'sem_movimentacao,duplicidade|5|alta', 'o mais antigo do par é sugerido: ' || coalesce(pg_temp.motivos(dup_velho), 'null');
  perform pg_temp.parado(dup_novo);
  assert not pg_temp.tem(dup_novo, 'duplicidade'), 'o mais recente fica';
  update candidatos set ultima_movimentacao = now() where id = dup_novo;       -- volta a ser "recente" para o teste da lista
  -- mesmo telefone mas nomes diferentes (família) NÃO é duplicidade
  cand_id := pg_temp.novo('Maria Aparecida Souza');
  update candidatos set telefone_e164 = '5561999990000' where id = cand_id;
  update candidatos set ultima_atualizacao = now() - interval '9 days' where id = cand_id;   -- (o gatilho carimba "agora" ao mudar dados)
  perform pg_temp.novo('Jose Roberto Lima');
  update candidatos set telefone_e164 = '5561999990000' where nome = 'Jose Roberto Lima';
  perform pg_temp.parado(cand_id);
  assert not pg_temp.tem(cand_id, 'duplicidade'), 'mesmo telefone com nomes diferentes não é duplicidade';
  -- mesmo telefone e nome parecido é
  perform pg_temp.novo('Maria A Souza');
  update candidatos set telefone_e164 = '5561999990000' where nome = 'Maria A Souza';
  assert pg_temp.motivos(cand_id) = 'sem_movimentacao,duplicidade|5|alta', 'telefone igual + nome parecido: ' || coalesce(pg_temp.motivos(cand_id), 'null');

  prazo := pg_temp.novo('Prazo Vencido');
  update candidatos set data_entrada = now() - interval '30 months' where id = prazo;
  assert pg_temp.motivos(prazo) = 'prazo_retencao|4|alta', 'prazo LGPD vale mesmo com movimentação recente: ' || coalesce(pg_temp.motivos(prazo), 'null');
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
  update configuracoes set valor = to_jsonb(1) where chave = 'sanitizacao_meses_sem_movimentacao';
  assert pg_temp.motivos(mov) is not null, 'com o limite de volta a 1 mês, o parado de 8 meses entra';

  -- ── geração: job (service_role) x painel ──
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar($f$select fn_gerar_sugestoes_sanitizacao('manual', true)$f$, 'Somente o administrador');
  perform pg_temp.deve_falhar($f$select sanitizacao_decidir_lote(array[gen_random_uuid()], 'excluir')$f$, 'só mantém ou inativa');
  perform pg_temp.como(null);
  r := fn_gerar_sugestoes_sanitizacao('job');
  assert (r ->> 'gerada')::boolean, 'job gera a lista';
  ciclo := (r ->> 'ciclo_id')::uuid;
  assert (r ->> 'total')::int >= 7, 'sugeridos: ' || (r ->> 'total');   -- os 7 casos abaixo (mais outros, se o banco já tiver candidatos)
  assert (select count(*) from sanitizacao_sugestoes where ciclo_id = ciclo and candidato_id in (ok, proc, perm, adiada, dados_novo, email_velho, dup_novo)) = 0,
    'quem não deve entrar não entrou';
  assert (select count(*) from sanitizacao_sugestoes where ciclo_id = ciclo and candidato_id in (mov, reprov, ader, dados, dup_velho, prazo, multi)) = 7,
    'quem deve entrar entrou';
  assert (select prioridade from sanitizacao_sugestoes where ciclo_id = ciclo and candidato_id = multi) = 'alta', 'prioridade alta';
  r := fn_gerar_sugestoes_sanitizacao('job');
  assert not (r ->> 'gerada')::boolean, 'segunda chamada dentro do intervalo não gera de novo';
  -- a lista é conferida toda semana: 3 dias depois ainda não gera; 8 dias depois gera e quem completou 1 mês entra
  update sanitizacao_ciclos set gerada_em = now() - interval '3 days';
  r := fn_gerar_sugestoes_sanitizacao('job');
  assert not (r ->> 'gerada')::boolean and r ? 'proxima_em', 'com intervalo de 7 dias, 3 dias não bastam: ' || r::text;
  update sanitizacao_ciclos set gerada_em = now() - interval '8 days';
  perform pg_temp.parado(dados_novo, 33);                                      -- completou 1 mês esta semana
  r := fn_gerar_sugestoes_sanitizacao('job');
  assert (r ->> 'gerada')::boolean and (r ->> 'total')::int >= 1, 'passada a semana, gera: ' || r::text;
  assert exists (select 1 from sanitizacao_sugestoes where candidato_id = dados_novo and status = 'pendente'
                    and motivos = array['sem_movimentacao', 'dados_incompletos']), 'quem completou 1 mês entrou, com o motivo extra';
  update candidatos set ultima_movimentacao = now() where id = dados_novo;
  update sanitizacao_sugestoes set status = 'expirada', decidido_em = now() where candidato_id = dados_novo and status = 'pendente';
  -- o intervalo é configurável (1 = todo dia)
  update configuracoes set valor = to_jsonb(1) where chave = 'sanitizacao_intervalo_dias';
  update sanitizacao_ciclos set gerada_em = now() - interval '25 hours';
  assert (fn_gerar_sugestoes_sanitizacao('job') ->> 'gerada')::boolean, 'com intervalo de 1 dia, 25 horas bastam';
  update configuracoes set valor = to_jsonb(7) where chave = 'sanitizacao_intervalo_dias';
  update sanitizacao_ciclos set gerada_em = now();
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

  -- excluir NÃO é mais decisão da fila (nem do administrador): a sanitização só mantém ou inativa
  update candidatos set nome = 'Pessoa Real', email = 'real@x.test', telefone = '61999', cidade = 'Gama', uf = 'DF' where id = prazo;
  insert into curriculos (candidato_id, storage_path, nome_arquivo, texto_extraido, origem, email_message_id)
    values (prazo, '2026/09/arquivo-prazo.pdf', 'cv.pdf', 'Texto do currículo com dados pessoais', 'anexo_pdf', 'msg-prazo');
  select id into sug from sanitizacao_sugestoes where candidato_id = prazo and status = 'pendente';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'excluir')$f$, sug), 'só mantém ou inativa');
  perform pg_temp.como(admin);
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'excluir')$f$, sug), 'só mantém ou inativa');
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir_lote(array[%L]::uuid[], 'excluir')$f$, sug), 'só mantém ou inativa');
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'apagar')$f$, sug), 'Decisão inválida');
  perform pg_temp.como(null);
  assert (select status from sanitizacao_sugestoes where id = sug) = 'pendente' and (select nome from candidatos where id = prazo) = 'Pessoa Real',
    'excluir recusado não apaga nada e não decide a sugestão';
  -- o administrador inativa; a contagem do expurgo parte dessa data. Passados os meses, o expurgo automático apaga
  -- (a manutenção diária o chama) e sobra só o esqueleto
  perform pg_temp.como(admin);
  perform sanitizacao_decidir(sug, 'inativar', 'prazo LGPD vencido');
  perform pg_temp.como(null);
  assert (select status_banco = 'inativo' and inativado_em > now() - interval '1 minute' from candidatos where id = prazo), 'inativar carimba a data';
  update candidatos set inativado_em = now() - interval '7 months' where id = prazo;
  r := fn_expurgar_inativos_vencidos();
  assert (r ->> 'expurgados')::int >= 1, 'o expurgo automático apagou o vencido: ' || r::text;
  select status_banco::text || '/' || (nome is null) || '/' || (email is null) || '/' || (telefone is null) || '/' || (cidade is null)
         || '/' || (hash_identidade is null) into s from candidatos where id = prazo;
  assert s = 'expurgado/true/true/true/true/true', 'dados pessoais apagados, hash de identidade preservado (dá "true" só se o candidato não tinha hash): ' || s;
  assert (select texto_extraido is null and storage_path is null and email_message_id is null from curriculos where candidato_id = prazo), 'currículo esvaziado';
  assert exists (select 1 from arquivos_para_remover where storage_path = '2026/09/arquivo-prazo.pdf' and removido_em is null), 'arquivo enfileirado para remoção do Storage';
  assert (select count(*) from analises_ia where candidato_id = prazo) = 0, 'análises da IA apagadas';
  assert (select status from sanitizacao_sugestoes where id = sug) = 'inativado', 'sugestão inativada';
  assert exists (select 1 from logs_auditoria where acao = 'sanitizacao_decisao' and entidade_id = prazo and usuario_id = admin), 'decisão auditada com quem decidiu';
  assert exists (select 1 from logs_auditoria where acao = 'exclusao_manual_lgpd' and entidade_id = prazo
                    and detalhe like 'Expurgo automático%'), 'expurgo auditado, com o motivo automático';
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

  -- ── botão "Sanitizar" no cadastro: o RH manda o candidato direto para a fila ──
  manual := pg_temp.novo('Enviado Pelo RH');                 -- entrou hoje: nenhum motivo automático
  assert pg_temp.motivos(manual) is null, 'ponto de partida: fora da lista automática';
  assert not has_function_privilege('anon', 'public.sanitizacao_enviar_candidato(uuid)', 'execute'), 'anônimo não executa';
  perform pg_temp.como(beto);
  r := sanitizacao_enviar_candidato(manual);
  assert (r ->> 'enviada')::boolean and not (r ->> 'ja_na_lista')::boolean, 'RH comum envia: ' || r::text;
  sug_manual := (r ->> 'sugestao_id')::uuid;
  select origem || '/' || prioridade || '/' || (ciclo_id is null) || '/' || (enviada_por = beto) || '/' || motivos[1] || '/' || status
    into s from sanitizacao_sugestoes where id = sug_manual;
  assert s = 'manual/alta/true/true/envio_manual/pendente', 'sugestão manual: ' || s;
  assert exists (select 1 from vw_sanitizacao_sugestoes
                  where id = sug_manual and sugestao_origem = 'manual' and ciclo_origem = 'manual'
                    and nome = 'Enviado Pelo RH' and enviada_por_nome is not null and gerada_em is not null),
    'a fila mostra a sugestão manual (sem ciclo) com quem enviou';
  r := sanitizacao_enviar_candidato(manual);
  assert not (r ->> 'enviada')::boolean and (r ->> 'ja_na_lista')::boolean, 'enviar de novo não duplica: ' || r::text;
  assert (select count(*) from sanitizacao_sugestoes where candidato_id = manual and status = 'pendente') = 1, 'uma pendente só';
  perform pg_temp.deve_falhar(format($f$select sanitizacao_enviar_candidato(%L)$f$, proc), 'já foram excluídos');
  perform pg_temp.deve_falhar(format($f$select sanitizacao_enviar_candidato(%L)$f$, ader), 'já está inativo');
  perform pg_temp.deve_falhar(format($f$select sanitizacao_enviar_candidato(%L)$f$, perm), 'retenção permanente');
  perform pg_temp.deve_falhar(format($f$select sanitizacao_enviar_candidato(%L)$f$, reprov), 'processo seletivo');
  perform pg_temp.deve_falhar($f$select sanitizacao_enviar_candidato(gen_random_uuid())$f$, 'não encontrado');
  perform pg_temp.como(null);
  assert exists (select 1 from logs_auditoria where acao = 'sanitizacao_decisao' and entidade_id = manual and usuario_id = beto
                    and detalhe = 'Sanitização: enviado pelo RH'), 'envio auditado';
  -- a rotina automática não duplica quem já está na fila por envio manual
  update candidatos set ultima_movimentacao = now() - interval '40 days' where id = manual;
  update sanitizacao_ciclos set gerada_em = now() - interval '8 days';
  r := fn_gerar_sugestoes_sanitizacao('job');
  assert (r ->> 'gerada')::boolean, 'passada a semana, a rotina confere de novo';
  assert (select count(*) from sanitizacao_sugestoes where candidato_id = manual and status = 'pendente') = 1, 'rotina não duplica o manual';
  -- decisão: o RH (qualquer usuário) inativa o que enviou
  perform pg_temp.como(beto);
  perform sanitizacao_decidir(sug_manual, 'inativar', 'não tem perfil');
  perform pg_temp.como(null);
  assert (select status_banco from candidatos where id = manual) = 'inativo', 'o RH inativou o que enviou';
  -- nem o administrador exclui o que o RH mandou: a fila só mantém ou inativa
  manual2 := pg_temp.novo('Enviado Para Excluir');
  perform pg_temp.como(beto);
  sug_manual := (sanitizacao_enviar_candidato(manual2) ->> 'sugestao_id')::uuid;
  perform pg_temp.como(admin);
  perform pg_temp.deve_falhar(format($f$select sanitizacao_decidir(%L, 'excluir', 'pedido do RH')$f$, sug_manual), 'só mantém ou inativa');
  perform pg_temp.como(null);
  assert (select status_banco::text || '/' || (nome is null) from candidatos where id = manual2) = 'ativo/false', 'excluir não apaga o que o RH mandou';

  -- ── manutenção diária: só expurga quem está inativo há mais de N meses; devolve a fila de arquivos ──
  r := fn_manutencao_diaria();
  assert r ? 'arquivos_para_remover' and r ? 'expurgo' and not r ? 'inativadas', 'manutenção devolve o expurgo e a fila de arquivos: ' || r::text;
  assert (select status_banco from candidatos where id = manual) = 'inativo' and (select nome from candidatos where id = manual) = 'Enviado Pelo RH',
    'inativado há instantes não é expurgado';
  assert r -> 'arquivos_para_remover' @> '["2026/09/arquivo-prazo.pdf"]'::jsonb, 'fila de arquivos vem da manutenção';
  assert fn_marcar_arquivos_removidos(array['2026/09/arquivo-prazo.pdf']) = 1, 'marca como removido';
  assert not (fn_manutencao_diaria() -> 'arquivos_para_remover' @> '["2026/09/arquivo-prazo.pdf"]'::jsonb), 'sai da fila depois de removido';
  assert not exists (select 1 from pg_proc where proname in ('fn_inativar_candidaturas_vencidas', 'fn_expurgar_candidaturas_inativas')),
    'funções da retenção automática removidas';
  assert not exists (select 1 from configuracoes where chave like 'retencao_meses%'), 'parâmetros antigos removidos';

  raise notice 'TESTE DA SANITIZAÇÃO: tudo certo';
end $$;

rollback;
