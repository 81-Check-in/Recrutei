-- Testes do cadastro manual sem currículo (077). Roda depois de 020–077.
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
  beto constant uuid := '00000000-0000-0000-0000-0000000000b1';
  loja uuid; vaga uuid; a uuid; b uuid; s text;
begin
  select id into loja from setores where nome = 'Loja';
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao)
    values (loja, 'V-Manual Vendedor', 1, 'Vendedor', 'junior') returning id into vaga;

  perform pg_temp.como(beto);

  -- nome e telefone são obrigatórios
  perform pg_temp.deve_falhar($f$select cadastrar_candidato_manual('{"telefone":"61999990001"}')$f$, 'Informe o nome');
  perform pg_temp.deve_falhar($f$select cadastrar_candidato_manual('{"nome":"Sem Telefone da Silva"}')$f$, 'telefone válido');
  perform pg_temp.deve_falhar($f$select cadastrar_candidato_manual('{"nome":"Tel Curto","telefone":"9999"}')$f$, 'telefone válido');

  -- só nome e telefone: entra ativo, com o currículo-observação e em revisão manual; o resto fica vazio
  a := cadastrar_candidato_manual('{"nome":"  Manual  Só Nome ","telefone":"(61) 99999-0001","telefone_e164":"5561999990001"}');
  select k.nome || '/' || k.telefone_e164 || '/' || k.status_banco::text || '/' || k.origem_entrada || '/' || k.revisao_manual
         || '/' || coalesce(k.email, '-') || '/' || coalesce(k.cidade, '-') || '/' || (k.reanalise_solicitada_em is null)
    into s from candidatos k where k.id = a;
  assert s = 'Manual Só Nome/5561999990001/ativo/upload_manual/true/-/-/true', 'candidato criado, got ' || s;
  select cu.texto_extraido || '/' || cu.origem::text || '/' || (cu.storage_path is null) || '/' || cu.atual
    into s from curriculos cu where cu.candidato_id = a;
  assert s = 'Currículo enviado manualmente sem anexo/upload_manual/true/true', 'currículo-observação, got ' || s;
  assert (select count(*) from vw_banco_talentos where id = a and storage_path is null and curriculo_origem::text = 'upload_manual') = 1,
    'aparece no Banco de Talentos sem arquivo';

  -- o mesmo nome e telefone não entra duas vezes (mesmo escrito de outro jeito)
  perform pg_temp.deve_falhar($f$select cadastrar_candidato_manual('{"nome":"manual so nome","telefone":"61 99999 0001","telefone_e164":"5561999990001"}')$f$,
    'Já existe um candidato');

  -- com os opcionais e com vaga: grava os dados, atribui e sai da revisão manual
  b := cadastrar_candidato_manual(
    '{"nome":"Manual Completo","telefone":"61999990002","telefone_e164":"5561999990002","email":"Manual@X.test","cidade":"Brasília","uf":"df","sexo":"feminino","escolaridade":"medio","anos_experiencia":"3","cnh":"b","data_nascimento":""}',
    vaga);
  select k.email || '/' || k.cidade || '/' || k.uf || '/' || k.sexo || '/' || k.escolaridade || '/' || k.anos_experiencia || '/' || k.cnh
         || '/' || k.status_banco::text || '/' || k.revisao_manual || '/' || (k.data_nascimento is null)
    into s from candidatos k where k.id = b;
  assert s = 'manual@x.test/Brasília/DF/feminino/medio/3.0/B/em_processo/false/true', 'opcionais e vaga, got ' || s;
  assert (select count(*) from candidaturas where candidato_id = b and vaga_id = vaga and encerrada_em is null) = 1, 'candidatura aberta na vaga';

  -- opcional inválido: nada fica gravado pela metade
  perform pg_temp.deve_falhar($f$select cadastrar_candidato_manual('{"nome":"Manual UF Errada","telefone":"61999990003","telefone_e164":"5561999990003","uf":"Brasil"}')$f$, 'UF');
  assert (select count(*) from candidatos where nome = 'Manual UF Errada') = 0, 'falha não deixa candidato pela metade';

  -- sem sessão não cadastra
  perform pg_temp.como(null);
  set local role anon;
  perform pg_temp.deve_falhar($f$select cadastrar_candidato_manual('{"nome":"Anonimo Teste","telefone":"61999990004"}')$f$, 'permission denied');
  reset role;

  raise notice 'cadastro_manual: ok';
end $$;

rollback;
