-- Testes do E-MAIL DE ENVIO e da DATA DO ENVIO no currículo (032).
-- Roda depois de 020–032. Tudo dentro de uma transação que termina em ROLLBACK.
\set ON_ERROR_STOP on
begin;

do $$
declare
  cand uuid; sem_email uuid; curr uuid; rem uuid; rem_email text;
  envio constant timestamptz := timestamptz '2026-09-20 10:30:00+00';
begin
  -- ── currículos que já existiam: o endereço que estava em remetentes foi copiado ──
  assert (select count(*) from curriculos where email_envio is not null) > 0, 'a 032 preencheu o e-mail de envio dos currículos existentes';
  assert not exists (
    select 1 from curriculos c
      join candidatos k on k.id = c.candidato_id
      join remetentes r on r.id = c.remetente_id
     where k.status_banco <> 'expurgado' and c.email_envio is distinct from lower(r.email::text)),
    'todo currículo com remetente tem o e-mail de envio igual ao dele (em minúsculas)';

  -- ── currículo novo: e-mail e data do envio aparecem na view do banco ──
  select id, lower(email::text) into rem, rem_email from remetentes order by email limit 1;
  insert into candidatos (nome, hash_identidade) values ('Teste Envio', 'hash-teste-envio') returning id into cand;
  insert into curriculos (candidato_id, origem, texto_extraido, remetente_id, email_envio, recebido_em, setor_adequado)
    values (cand, 'anexo_pdf', 'Texto do currículo.', rem, rem_email, envio, 'Logística')
    returning id into curr;
  assert (select curriculo_email_envio = rem_email and curriculo_recebido_em = envio from vw_banco_talentos where id = cand),
    'a view informa o e-mail de envio e a data do envio do currículo atual';
  assert (select curriculo_email_envio from filtrar_banco_talentos('{}'::jsonb) where id = cand) = rem_email,
    'a busca com filtros devolve a mesma coluna';

  -- upload manual: sem e-mail de envio (não veio por e-mail), mas com a data em que foi enviado ao sistema
  insert into candidatos (nome, hash_identidade, origem_entrada) values ('Teste Upload', 'hash-teste-upload', 'upload_manual') returning id into sem_email;
  insert into curriculos (candidato_id, origem, texto_extraido) values (sem_email, 'anexo_pdf', 'Outro currículo.');
  assert (select curriculo_email_envio is null and curriculo_recebido_em is not null from vw_banco_talentos where id = sem_email),
    'upload manual: sem e-mail de envio, com data';

  -- ── expurgo: o e-mail de envio (dado pessoal) e a classificação saem com o texto ──
  assert not exists (select 1 from pg_trigger where tgname = 'trg_curriculo_limpa_qualificacao'), 'o gatilho antigo da 031 foi substituído';
  perform fn_expurgar_candidato(cand, 'teste 032');
  assert (select email_envio is null and setor_adequado is null and texto_extraido is null from curriculos where id = curr),
    'expurgo: o e-mail de envio e a classificação saem junto com o texto';
  assert not exists (select 1 from vw_banco_talentos where id = cand), 'expurgado sai da view';

  raise notice 'TESTE DO E-MAIL DE ENVIO: tudo certo';
end $$;

rollback;
