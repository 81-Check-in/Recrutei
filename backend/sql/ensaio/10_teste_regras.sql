-- Testes de comportamento das regras do Banco de Talentos (roda depois de 020–022; também vale depois de 025).
-- Tudo dentro de uma transação que termina em ROLLBACK: não deixa nada no banco.
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

do $$
declare
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  dani  constant uuid := '00000000-0000-0000-0000-0000000000c9';   -- usuária inativa
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  a uuid; vaga1 uuid; vaga2 uuid; c1 uuid; c2 uuid; e1 uuid; cur1 uuid; cur2 uuid; rem uuid;
  n int; s text; st public.status_banco_talentos;
begin
  select id into vaga1 from vagas where status = 'ativo' order by titulo limit 1;
  select id into vaga2 from vagas where status = 'ativo' order by titulo desc limit 1;
  select id into rem from remetentes order by email limit 1;

  -- ── candidato novo entra no banco (como o pipeline faria) ──
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Teste Regras', 'Brasília', 'DF', 'hash-teste-regras') returning id into a;
  select status_banco into st from candidatos where id = a;
  assert st = 'ativo', 'candidato novo deve entrar como ativo';

  -- ── currículos: o novo vira "atual", o anterior fica como versão; envio conta para o remetente ──
  select total_envios into n from remetentes where id = rem;
  insert into curriculos (candidato_id, origem, texto_extraido, remetente_id, email_message_id)
    values (a, 'anexo_pdf', 'primeira versão', rem, 'msg-teste-1') returning id into cur1;
  insert into curriculos (candidato_id, origem, texto_extraido, remetente_id, email_message_id)
    values (a, 'anexo_pdf', 'segunda versão', rem, 'msg-teste-2') returning id into cur2;
  assert (select count(*) from curriculos where candidato_id = a and atual) = 1, 'só um currículo atual';
  assert (select atual from curriculos where id = cur2), 'o mais novo é o atual';
  assert (select total_envios from remetentes where id = rem) = n + 2, 'cada currículo recebido conta como envio';
  perform pg_temp.deve_falhar(
    format($f$insert into curriculos (candidato_id, origem, email_message_id) values (%L, 'anexo_pdf', 'msg-teste-1')$f$, a),
    'uq_curriculo_message_id');

  -- ── análise: a mais recente vira a sugestão do candidato e limpa o pedido de reanálise ──
  update candidatos set reanalise_solicitada_em = now() where id = a;
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia)
    values (a, 1, 'Logística', 'Auxiliar', 'junior', 80, 'teste');
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, revisao_manual, versao_modelo_ia)
    values (a, 2, 'Logística', 'Conferente', 'pleno', 40, true, 'teste');
  select area_sugerida || '/' || cargo_sugerido || '/' || nivel_sugerido || '/' || ia_confianca || '/' || revisao_manual || '/' || (reanalise_solicitada_em is null)
    into s from candidatos where id = a;
  assert s = 'Logística/Conferente/pleno/40/true/true', 'sugestão atual = análise mais recente, got ' || s;

  -- ── permissões: painel não escreve direto em candidatos ──
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar($f$insert into candidatos (nome) values ('x')$f$, 'permission denied');
  perform pg_temp.deve_falhar($f$update candidatos set status_banco = 'inativo'$f$, 'permission denied');
  perform pg_temp.deve_falhar($f$delete from candidatos$f$, 'permission denied');
  assert (select count(*) from candidatos where id = a) = 1, 'RH ativo lê candidatos';
  perform pg_temp.como(dani);
  assert (select count(*) from candidatos) = 0, 'usuário inativo não vê candidatos (RLS)';
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, a, vaga1), 'Usuário inativo');
  perform pg_temp.como(null);
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, a, vaga1), 'Sessão expirada');

  -- ── atribuição manual ──
  perform pg_temp.como(beto);
  c1 := atribuir_candidato_vaga(a, vaga1, 'perfil forte para expedição');
  perform pg_temp.como(null);
  select status_banco into st from candidatos where id = a;
  assert st = 'em_processo', 'atribuir move o candidato para em_processo';
  select status::text || '/' || (atribuido_por = beto) || '/' || (data_atribuicao is not null) || '/' || (selecionado_em is not null)
         || '/' || avaliacao_pendente || '/' || origem into s from candidaturas where id = c1;
  -- a 5ª parte é avaliacao_pendente: desde a 033 atribuir NÃO pede avaliação da IA (não há IA escolhendo currículo na vaga)
  assert s = 'aguardando/true/true/true/false/atribuicao_manual', 'candidatura criada corretamente, got ' || s;
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, a, vaga2), 'já está em um processo seletivo');
  perform pg_temp.como(null);

  -- ── entrevista: agenda → reprova → candidatura fecha e o candidato VOLTA ao banco ──
  insert into entrevistas (candidatura_id, data_hora, agendado_por) values (c1, now() + interval '1 day', beto) returning id into e1;
  assert (select status from candidaturas where id = c1) = 'entrevista_agendada', 'agendar entrevista move a candidatura';
  update entrevistas set resultado = 'reprovado', observacoes = 'Sem CNH', resultado_registrado_em = now() where id = e1;
  select status::text || '/' || (encerrada_em is not null) || '/' || resultado_final into s from candidaturas where id = c1;
  assert s = 'reprovado/true/Sem CNH', 'reprovação fecha a candidatura com o motivo, got ' || s;
  select status_banco into st from candidatos where id = a;
  assert st = 'ativo', 'candidato reprovado volta ao banco (ativo), got ' || st;
  assert (select count(*) from candidaturas where candidato_id = a) = 1, 'histórico da tentativa anterior preservado';
  assert (select count(*) from logs_auditoria where acao = 'retorno_banco_talentos' and entidade_id = a) = 1, 'retorno ao banco auditado';

  -- ── uma vaga encerrada não recebe candidato ──
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(
    format($f$select atribuir_candidato_vaga(%L, %L)$f$, a, (select id from vagas where status <> 'ativo' limit 1)),
    'não está mais aberta');
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, a, gen_random_uuid()), 'Vaga não encontrada');

  -- ── nova atribuição a OUTRA vaga (N:N) e cancelamento ──
  c2 := atribuir_candidato_vaga(a, vaga2);
  perform pg_temp.como(null);
  assert (select count(*) from candidaturas where candidato_id = a) = 2, 'segunda candidatura convive com a primeira';
  insert into entrevistas (candidatura_id, data_hora, agendado_por) values (c2, now() + interval '2 day', beto);
  perform pg_temp.como(beto);
  perform encerrar_candidatura(c2, 'cancelado', 'vaga preenchida');
  perform pg_temp.como(null);
  assert (select status_banco from candidatos where id = a) = 'ativo', 'cancelar também devolve ao banco';
  assert (select resultado from entrevistas where candidatura_id = c2) = 'cancelada', 'entrevista da candidatura cancelada sai da agenda';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select encerrar_candidatura(%L, 'reprovado')$f$, c2), 'já foi encerrada');
  perform pg_temp.como(null);

  -- ── contratado: sai do banco e não entra na sanitização ──
  -- (vaga2, não vaga1: nela ele foi reprovado e a regra do descarte não deixa voltar; ver 14_teste_etapa1.sql)
  perform pg_temp.como(beto);
  c1 := atribuir_candidato_vaga(a, vaga2);
  perform pg_temp.como(null);
  update candidaturas set status = 'contratado' where id = c1;
  select status_banco::text || '/' || retencao_permanente into s from candidatos where id = a;
  assert s = 'inativo/true', 'contratado vira inativo com retenção permanente, got ' || s;

  -- ── inativar / reativar à mão ──
  update candidatos set retencao_permanente = false, status_banco = 'ativo', inativado_em = null where id = a;
  perform pg_temp.como(beto);
  perform alterar_status_banco(a, 'inativo', 'não atende');
  perform pg_temp.como(null);
  assert (select status_banco from candidatos where id = a) = 'inativo', 'inativar';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, a, vaga2), 'Candidato inativo');
  perform alterar_status_banco(a, 'ativo');
  perform pg_temp.como(null);
  assert (select status_banco from candidatos where id = a) = 'ativo', 'reativar';

  -- ── editar candidato: só campos permitidos; auditoria sem valores ──
  perform pg_temp.como(beto);
  perform editar_candidato(a, '{"nome":"Teste Regras Editado","uf":"go","escolaridade":"superior","hash_identidade":"hack","status_banco":"inativo"}');
  perform pg_temp.deve_falhar(format($f$select editar_candidato(%L, '{"sexo":"outro"}')$f$, a), 'Sexo deve ser');
  perform pg_temp.como(null);
  select nome || '/' || uf || '/' || escolaridade || '/' || hash_identidade || '/' || status_banco into s from candidatos where id = a;
  assert s = 'Teste Regras Editado/GO/superior/hash-teste-regras/ativo', 'edição respeita a lista de campos, got ' || s;
  assert not exists (select 1 from logs_auditoria where entidade_id = a and acao = 'alteracao_candidato' and dados_depois::text like '%Editado%'),
    'auditoria não guarda valores pessoais';

  -- ── reanálise e contato ──
  update candidatos set reanalise_solicitada_em = null where id = a;
  perform pg_temp.como(beto);
  perform solicitar_reanalise(a);
  perform registrar_contato_candidato(a);
  perform registrar_consentimento(a);
  perform pg_temp.como(null);
  assert (select reanalise_solicitada_em is not null and ultimo_contato_em is not null and consentimento_em is not null from candidatos where id = a),
    'reanálise, contato e consentimento gravados';

  raise notice 'TESTE DAS REGRAS: tudo certo';
end $$;

rollback;
