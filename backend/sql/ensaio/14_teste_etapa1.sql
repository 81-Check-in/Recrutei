-- Testes da ETAPA 1 (028): lista negra, descarte por vaga, coluna da impressão digital do arquivo.
-- Roda depois de 020–028. Tudo dentro de uma transação que termina em ROLLBACK.
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
  beto constant uuid := '00000000-0000-0000-0000-0000000000b1';
  dani constant uuid := '00000000-0000-0000-0000-0000000000c9';   -- usuária inativa
  vaga1 uuid; vaga2 uuid; a uuid; b uuid; d uuid; rem uuid; c1 uuid; c2 uuid; e1 uuid;
  r jsonb; s text; n int;
begin
  select id into vaga1 from vagas where status = 'ativo' order by titulo limit 1;
  select id into vaga2 from vagas where status = 'ativo' order by titulo desc limit 1;

  assert exists (select 1 from information_schema.columns where table_name = 'curriculos' and column_name = 'arquivo_hash'),
    'coluna arquivo_hash';

  -- candidato com dois endereços (o do currículo e o de quem enviou), candidatura aberta e entrevista marcada
  insert into remetentes (email) values ('quem.enviou@mail.test') returning id into rem;
  insert into candidatos (nome, email, cidade, uf, hash_identidade)
    values ('Risco Um', 'Risco.Um@mail.test', 'Ceilândia', 'DF', 'hash-risco-1') returning id into a;
  insert into curriculos (candidato_id, origem, texto_extraido, remetente_id, email_message_id, arquivo_hash)
    values (a, 'anexo_pdf', 'texto', rem, 'msg-risco-1', 'hash-arquivo-1');
  perform pg_temp.como(beto);
  c1 := atribuir_candidato_vaga(a, vaga1);
  perform pg_temp.como(null);
  insert into entrevistas (candidatura_id, data_hora, agendado_por) values (c1, now() + interval '1 day', beto) returning id into e1;

  -- ── permissões e validações ──
  perform pg_temp.como(dani);
  perform pg_temp.deve_falhar($f$select bloquear_email('x@mail.test', 'motivo')$f$, 'Usuário inativo');
  perform pg_temp.como(null);
  perform pg_temp.deve_falhar($f$select bloquear_email('x@mail.test', 'motivo')$f$, 'Sessão expirada');
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar($f$select bloquear_email('x@mail.test', '  ')$f$, 'Informe o motivo');
  perform pg_temp.deve_falhar($f$select bloquear_email('isto-nao-e-email', 'motivo')$f$, 'e-mail válido');
  perform pg_temp.deve_falhar($f$select bloquear_email(null, 'motivo')$f$, 'e-mail válido');
  perform pg_temp.deve_falhar($f$select desbloquear_email('nunca.bloqueado@mail.test')$f$, 'não está na lista negra');

  -- ── bloqueio de um endereço ──
  r := bloquear_email('  Spam@Mail.TEST ', 'Envia propaganda');
  assert (r ->> 'enderecos_bloqueados')::int = 1 and (r ->> 'candidatos_inativados')::int = 0, 'resposta do bloqueio simples';
  perform pg_temp.como(null);
  select bloqueado::text || '/' || motivo_bloqueio || '/' || (bloqueado_por = beto) || '/' || (bloqueado_em is not null)
    into s from remetentes where email = 'spam@mail.test';
  assert s = 'true/Envia propaganda/true/true', 'endereço bloqueado com motivo e autor, got ' || s;
  perform pg_temp.como(beto);
  perform bloquear_email('SPAM@mail.test', 'outro motivo, outra pessoa');
  perform pg_temp.como(null);
  assert (select motivo_bloqueio from remetentes where email = 'spam@mail.test') = 'Envia propaganda',
    'bloquear de novo não apaga o motivo original';

  -- ── bloqueio do candidato inteiro ──
  perform pg_temp.como(beto);
  r := bloquear_email(null, 'Ex-funcionário com ocorrências', a);
  perform pg_temp.como(null);
  assert (r ->> 'enderecos_bloqueados')::int = 2, 'os dois endereços do candidato, got ' || (r ->> 'enderecos_bloqueados');
  assert (select count(*) from remetentes where bloqueado and email in ('risco.um@mail.test', 'quem.enviou@mail.test')) = 2,
    'o e-mail do currículo e o de quem enviou ficam bloqueados';
  select lista_negra::text || '/' || status_banco::text || '/' || retencao_permanente || '/' || motivo_inativacao || '/' || lista_negra_motivo
    into s from candidatos where id = a;
  assert s = 'true/inativo/true/Lista negra/Ex-funcionário com ocorrências', 'candidato na lista negra, got ' || s;
  select status::text || '/' || resultado_final into s from candidaturas where id = c1;
  assert s = 'cancelado/Candidato na lista negra', 'a candidatura aberta foi cancelada, got ' || s;
  assert (select resultado from entrevistas where id = e1) = 'cancelada', 'a entrevista marcada deixou de valer';
  assert (select count(*) from logs_auditoria where acao = 'lista_negra_bloqueio') = 3, 'três bloqueios auditados';
  assert not exists (select 1 from logs_auditoria where acao = 'lista_negra_bloqueio' and dados_depois::text ilike '%@%'),
    'a auditoria não guarda o e-mail';

  -- não volta por nenhum caminho
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, a, vaga2), 'lista negra');
  perform pg_temp.deve_falhar(format($f$select alterar_status_banco(%L, 'ativo')$f$, a), 'lista negra');
  perform pg_temp.como(null);
  assert not exists (select 1 from fn_sanitizacao_avaliar(fn_sanitizacao_parametros()) x where x.candidato_id = a),
    'a sanitização não sugere apagar quem está na lista negra';

  -- telas
  perform pg_temp.como(beto);
  assert (select lista_negra and lista_negra_por_nome is not null from vw_banco_talentos where id = a), 'vw_banco_talentos informa a lista negra';
  select count(*), max(candidato_nome) into n, s from vw_lista_negra where candidato_id = a;
  assert n = 2 and s = 'Risco Um', 'vw_lista_negra liga os endereços ao candidato, got ' || n || '/' || coalesce(s, '?');
  assert (select count(*) from vw_lista_negra) = 3, 'a lista negra tem os 3 endereços';
  assert (select count(*) from filtrar_banco_talentos('{}'::jsonb)) > 0, 'a busca continua funcionando com a view nova';
  perform pg_temp.como(null);

  -- ── tirar da lista negra: libera, mas o candidato continua inativo até o RH reativar ──
  perform pg_temp.como(beto);
  r := desbloquear_email(null, a);
  assert (r ->> 'enderecos_liberados')::int = 2, 'liberou os dois endereços';
  perform pg_temp.como(null);
  select lista_negra::text || '/' || status_banco::text into s from candidatos where id = a;
  assert s = 'false/inativo', 'sai da lista negra mas segue inativo, got ' || s;
  assert (select count(*) from remetentes where bloqueado) = 1, 'só o endereço avulso continua bloqueado';
  perform pg_temp.como(beto);
  perform alterar_status_banco(a, 'ativo');
  perform desbloquear_email('spam@mail.test');
  perform pg_temp.como(null);
  assert (select status_banco from candidatos where id = a) = 'ativo', 'depois de sair da lista, o RH pode reativar';
  assert (select count(*) from remetentes where bloqueado) = 0, 'lista negra vazia';
  assert (select count(*) from logs_auditoria where acao = 'lista_negra_desbloqueio') = 2, 'desbloqueios auditados';

  -- ── descarte por vaga ──
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Descarte Um', 'Taguatinga', 'DF', 'hash-descarte-1') returning id into b;
  perform pg_temp.como(beto);
  c1 := atribuir_candidato_vaga(b, vaga1);
  perform pg_temp.como(null);
  update candidaturas set status = 'reprovado', resultado_final = 'Sem experiência' where id = c1;
  assert (select status_banco from candidatos where id = b) = 'ativo', 'reprovado volta ao banco';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, b, vaga1), 'já foi reprovado nesta vaga');
  c2 := atribuir_candidato_vaga(b, vaga2);                                   -- outra vaga: livre
  perform encerrar_candidatura(c2, 'cancelado', 'devolvido sem reprovar');
  c2 := atribuir_candidato_vaga(b, vaga2);                                   -- cancelado não é descarte: pode voltar à mesma vaga
  perform pg_temp.como(null);
  assert (select count(*) from candidaturas where candidato_id = b and vaga_id = vaga2) = 2, 'cancelar não impede voltar à vaga';

  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Descarte Dois', 'Gama', 'DF', 'hash-descarte-2') returning id into d;
  perform pg_temp.como(beto);
  c1 := atribuir_candidato_vaga(d, vaga1);
  perform pg_temp.como(null);
  update candidaturas set status = 'descartado' where id = c1;                -- status legado "descartado" vale igual
  update candidatos set status_banco = 'ativo', inativado_em = null where id = d;
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select atribuir_candidato_vaga(%L, %L)$f$, d, vaga1), 'já foi reprovado nesta vaga');
  perform pg_temp.como(null);

  -- ── bloquear o ENDEREÇO de quem já está no banco leva a pessoa junto (senão ela seguiria disponível) ──
  insert into candidatos (nome, email, cidade, uf, hash_identidade)
    values ('Dono do Endereço', 'Dono@Mail.Test', 'Gama', 'DF', 'hash-dono-1') returning id into b;
  insert into candidatos (nome, email, cidade, uf, hash_identidade)
    values ('Outra Pessoa', 'outra@mail.test', 'Gama', 'DF', 'hash-outra-1') returning id into d;
  perform pg_temp.como(beto);
  r := bloquear_email('DONO@mail.test', 'Aviso recebido do RH da empresa anterior');
  perform pg_temp.como(null);
  assert (r ->> 'candidatos_inativados')::int = 1, 'o dono do endereço foi junto, got ' || (r ->> 'candidatos_inativados');
  select lista_negra::text || '/' || status_banco::text into s from candidatos where id = b;
  assert s = 'true/inativo', 'o dono do endereço está na lista negra e inativo, got ' || s;
  select lista_negra::text || '/' || status_banco::text into s from candidatos where id = d;
  assert s = 'false/ativo', 'quem não usa o endereço não é afetado, got ' || s;

  raise notice 'TESTE DA ETAPA 1: tudo certo';
end $$;

rollback;
