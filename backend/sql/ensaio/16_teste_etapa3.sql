-- Testes da ETAPA 3 (030): regiões, distância candidato × lojas e considerações do RH.
-- Roda depois de 020–030. Tudo dentro de uma transação que termina em ROLLBACK.
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
create or replace function pg_temp.regiao(p_bairro text, p_cidade text) returns text language sql as $$
  select r.nome from public.regioes_df r where r.id = public.fn_regiao_por_texto(p_bairro, p_cidade) $$;

do $$
declare
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  carla constant uuid := '00000000-0000-0000-0000-0000000000b2';
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  dani  constant uuid := '00000000-0000-0000-0000-0000000000c9';
  setor uuid; vaga uuid; vaga_sem_loja uuid; outra_vaga uuid;
  cfs uuid; cft uuid; cfx uuid;
  perto uuid; longe uuid; sem uuid; fora uuid; a uuid; b uuid; cd uuid; e1 uuid; con1 uuid; con2 uuid;
  r record; s text; n int; km numeric; ids uuid[];
begin
  select id into setor from setores order by nome limit 1;
  select id into outra_vaga from vagas where status = 'ativo' order by titulo limit 1;

  -- ── regiões e distância ──
  assert (select count(*) from regioes_df) >= 40, 'regiões cadastradas';
  assert distancia_km(-15.833, -48.057, -15.833, -48.057) = 0, 'mesmo ponto = 0 km';
  km := distancia_km((select latitude from regioes_df where nome = 'Taguatinga'), (select longitude from regioes_df where nome = 'Taguatinga'),
                     (select latitude from regioes_df where nome = 'Ceilândia'),  (select longitude from regioes_df where nome = 'Ceilândia'));
  assert km between 4 and 8, 'Taguatinga ↔ Ceilândia ~5 km em linha reta, got ' || km;
  assert distancia_km(-15.833, -48.057, -16.018, -48.065) = distancia_km(-16.018, -48.065, -15.833, -48.057), 'a distância é simétrica';
  assert (select distancia_km(g.latitude, g.longitude, t.latitude, t.longitude) from regioes_df g, regioes_df t where g.nome = 'Gama' and t.nome = 'Taguatinga')
         between 18 and 24, 'Gama ↔ Taguatinga ~21 km';

  -- ── achar a região pelo texto ──
  assert pg_temp.regiao(null, 'Taguatinga - DF') = 'Taguatinga', 'cidade com UF';
  assert pg_temp.regiao(null, 'CEILÂNDIA NORTE') = 'Ceilândia', 'caixa, acento e complemento não atrapalham';
  assert pg_temp.regiao('Guará II', 'Brasília') = 'Guará', 'o bairro decide quando a cidade é genérica';
  assert pg_temp.regiao(null, 'Novo Gama') = 'Novo Gama', 'Novo Gama não vira Gama (vale o nome mais comprido)';
  assert pg_temp.regiao(null, 'Planaltina de Goiás') = 'Planaltina de Goiás', 'Planaltina de Goiás não vira Planaltina';
  assert pg_temp.regiao(null, 'Planaltina') = 'Planaltina', 'Planaltina do DF';
  assert pg_temp.regiao(null, 'Sobradinho II') = 'Sobradinho II', 'Sobradinho II não vira Sobradinho';
  assert pg_temp.regiao('Setor Sol Nascente', null) = 'Sol Nascente / Pôr do Sol', 'apelido de bairro inequívoco';
  assert pg_temp.regiao('Estrutural', null) = 'Estrutural' and pg_temp.regiao('Setor Bernardo Sayão', null) = 'Guará', 'apelidos das lojas';
  assert pg_temp.regiao(null, 'Valparaíso de Goiás') = 'Valparaíso de Goiás', 'entorno';
  assert pg_temp.regiao(null, 'Brasília') is null, '"Brasília" sozinho não aponta região';
  assert pg_temp.regiao(null, 'São Paulo') is null and pg_temp.regiao(null, null) is null and pg_temp.regiao('', '') is null, 'sem correspondência: nulo';
  assert pg_temp.regiao(null, 'Ceilandiaa') is null, 'palavra inteira: não casa parte de outra palavra';

  -- ── lojas ──
  select id into cfs from empresas where sigla = 'CFS';
  select id into cft from empresas where sigla = 'CFT';
  if cft is null then insert into empresas (sigla, nome) values ('CFT', 'Castelo Forte T') returning id into cft; end if;
  select id into cfx from empresas where sigla = 'CFR';
  update empresas set regiao_id = (select id from regioes_df where nome = 'Samambaia') where id = cfs;
  update empresas set regiao_id = (select id from regioes_df where nome = 'Taguatinga') where id = cft;
  update empresas set regiao_id = null where id = cfx;                                   -- loja sem local: fica de fora das distâncias

  insert into vagas (setor_id, titulo, descricao, quantidade)
    values (setor, 'Auxiliar Contábil Distância', 'rotinas contábeis e fiscais, conciliações', 1) returning id into vaga;
  insert into requisitos (vaga_id, descricao, tipo, peso, ordem) values (vaga, 'Domínio de Excel', 'desejavel', 2, 1);
  insert into vaga_empresas (vaga_id, empresa_id) values (vaga, cfs), (vaga, cft), (vaga, cfx);
  insert into vagas (setor_id, titulo, quantidade) values (setor, 'Vaga sem lojas com local', 1) returning id into vaga_sem_loja;
  insert into vaga_empresas (vaga_id, empresa_id) values (vaga_sem_loja, cfx);

  assert (select count(*) from fn_lojas_da_vaga(vaga)) = 2, 'só as lojas com local entram (CFS e CFT; a CFR não tem)';
  update empresas set latitude = -15.900000, longitude = -48.100000 where id = cfx;
  assert (select count(*) from fn_lojas_da_vaga(vaga)) = 3, 'o ponto exato da loja vale mesmo sem região';
  update empresas set latitude = null, longitude = null where id = cfx;

  -- ── região do candidato: gatilho, IA, texto, manual ──
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand Perto', 'Ceilândia', 'DF', 'r-perto') returning id into perto;
  select rg.nome || '/' || c.regiao_origem into s from candidatos c join regioes_df rg on rg.id = c.regiao_id where c.id = perto;
  assert s = 'Ceilândia/cidade', 'a cidade cadastrada dá a região automática, got ' || coalesce(s, '?');
  update candidatos set cidade = 'Gama' where id = perto;
  assert (select rg.nome from candidatos c join regioes_df rg on rg.id = c.regiao_id where c.id = perto) = 'Gama', 'trocou a cidade: a região acompanha';
  update candidatos set cidade = 'Ceilândia' where id = perto;

  update candidatos set regiao_id = (select id from regioes_df where nome = 'Taguatinga'), regiao_origem = 'ia' where id = perto;
  update candidatos set cidade = 'Samambaia' where id = perto;
  assert (select rg.nome from candidatos c join regioes_df rg on rg.id = c.regiao_id where c.id = perto) = 'Taguatinga',
    'o que a IA decidiu não é sobrescrito por uma troca de cidade';
  update candidatos set cidade = 'Ceilândia', regiao_id = null, regiao_origem = null where id = perto;
  assert (select rg.nome from candidatos c join regioes_df rg on rg.id = c.regiao_id where c.id = perto) = 'Ceilândia',
    'sem região decidida, volta ao automático pela cidade';

  perform pg_temp.como(beto);
  perform editar_candidato(perto, jsonb_build_object('regiao_id', (select id from regioes_df where nome = 'Taguatinga')));
  perform pg_temp.como(null);
  select rg.nome || '/' || c.regiao_origem into s from candidatos c join regioes_df rg on rg.id = c.regiao_id where c.id = perto;
  assert s = 'Taguatinga/manual', 'a correção do RH vale sempre, got ' || s;
  update candidatos set cidade = 'Gama' where id = perto;
  assert (select regiao_origem from candidatos where id = perto) = 'manual', 'nem a troca de cidade tira o manual';
  perform pg_temp.como(beto);
  perform editar_candidato(perto, '{"regiao_id": "", "cidade": "Ceilândia"}');
  perform pg_temp.deve_falhar(format($f$select editar_candidato(%L, '{"regiao_id": "%s"}')$f$, perto, gen_random_uuid()), 'Região inválida');
  perform pg_temp.como(null);
  assert (select rg.nome || '/' || c.regiao_origem from candidatos c join regioes_df rg on rg.id = c.regiao_id where c.id = perto) = 'Ceilândia/cidade',
    'em branco = automático de novo';

  -- ── distâncias até as lojas da vaga ──
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand Longe', 'Gama', 'DF', 'r-longe') returning id into longe;
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand Sem Regiao', 'Brasília', 'DF', 'r-sem') returning id into sem;
  perform pg_temp.como(beto);
  select * into r from distancias_para_vaga(vaga, array[perto]);
  assert r.regiao = 'Ceilândia' and r.loja_mais_proxima = 'CFT', 'de Ceilândia a mais perto é a CFT (Taguatinga), got ' || coalesce(r.loja_mais_proxima, '?');
  assert r.km_mais_proxima between 4 and 8, 'km da mais próxima, got ' || r.km_mais_proxima;
  assert jsonb_array_length(r.lojas) = 2 and (r.lojas -> 0 ->> 'sigla') = 'CFT' and (r.lojas -> 1 ->> 'sigla') = 'CFS', 'as duas lojas com local, da mais perta à mais longe';
  assert (r.lojas -> 0 ->> 'regiao') = 'Taguatinga' and ((r.lojas -> 0 ->> 'km')::numeric) < ((r.lojas -> 1 ->> 'km')::numeric), 'região e km de cada loja';
  select * into r from distancias_para_vaga(vaga, array[sem]);
  assert r.regiao is null and r.loja_mais_proxima is null and r.km_mais_proxima is null and r.lojas = '[]'::jsonb, 'sem região: sem distância, sem erro';
  assert (select count(*) from distancias_para_vaga(vaga_sem_loja, array[perto, longe])) = 2
     and (select count(*) from distancias_para_vaga(vaga_sem_loja, array[perto]) where lojas = '[]'::jsonb) = 1, 'vaga sem loja com local: sem distâncias';
  assert (select count(*) from distancias_para_vaga(vaga, array[perto, longe, sem])) = 3, 'uma linha por candidato';
  perform pg_temp.como(null);

  -- ── ranking com distância ──
  perform pg_temp.como(null);
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia, palavras_chave)
    select x, 1, 'Financeiro', 'Auxiliar', 'pleno', 80, 't', array['excel', 'contabilidade'] from unnest(array[perto, longe, sem]) x;
  perform pg_temp.como(beto);
  select array_agg(candidato_id) into ids from ranking_candidatos_vaga(vaga, 10, 0, 'distancia');
  assert ids[1] = perto and ids[2] = longe and ids[3] = sem, 'por distância: perto, longe e, por último, quem não tem região';
  select km_mais_proxima, loja_mais_proxima into km, s from ranking_candidatos_vaga(vaga, 10) where candidato_id = perto;
  assert km between 4 and 8 and s = 'CFT', 'o ranking devolve a loja mais próxima e os km';
  assert (select count(*) from ranking_candidatos_vaga(vaga, 10, 0, 'distancia', 10)) = 1, 'até 10 km: só o de Ceilândia';
  assert (select count(*) from ranking_candidatos_vaga(vaga, 10, 0, 'distancia', 30)) = 2, 'até 30 km: os dois com região (o sem região fica de fora)';
  assert (select count(*) from ranking_candidatos_vaga(vaga, 10, 0, 'aderencia', null)) = 3, 'sem limite de km: os três';
  assert (select min(total) from ranking_candidatos_vaga(vaga, 1, 0, 'distancia', 30)) = 2, 'o total acompanha o filtro de km';
  perform pg_temp.como(null);

  -- ── considerações do RH ──
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Cand Consideracao', 'Gama', 'DF', 'r-cons') returning id into a;
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Outro Candidato', 'Gama', 'DF', 'r-outro') returning id into b;
  perform pg_temp.como(beto);
  cd := atribuir_candidato_vaga(a, outra_vaga);
  perform pg_temp.como(null);
  insert into entrevistas (candidatura_id, data_hora, agendado_por) values (cd, now() + interval '1 day', beto) returning id into e1;

  perform pg_temp.como(dani);
  perform pg_temp.deve_falhar(format($f$select registrar_consideracao(%L, 'texto')$f$, a), 'Usuário inativo');
  perform pg_temp.como(null);
  perform pg_temp.deve_falhar(format($f$select registrar_consideracao(%L, 'texto')$f$, a), 'Sessão expirada');
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select registrar_consideracao(%L, '   ')$f$, a), 'Escreva a consideração');
  perform pg_temp.deve_falhar(format($f$select registrar_consideracao(%L, %L)$f$, a, repeat('x', 4001)), '4.000 caracteres');
  perform pg_temp.deve_falhar(format($f$select registrar_consideracao(%L, 'x', %L)$f$, b, e1), 'não é deste candidato');
  perform pg_temp.deve_falhar(format($f$select registrar_consideracao(%L, 'x')$f$, gen_random_uuid()), 'não encontrado');
  perform pg_temp.deve_falhar(format($f$insert into consideracoes_candidato (candidato_id, texto) values (%L, 'direto')$f$, a), 'permission denied');

  con1 := registrar_consideracao(a, 'Boa comunicação; chegou pontual. Reservas quanto à disponibilidade de horário.', e1);
  con2 := registrar_consideracao(a, 'Voltei a falar com ele: aceita turno da noite.');
  perform pg_temp.como(null);
  select vaga_titulo, (candidatura_id = cd) as cand_ok, (entrevista_id = e1) as ent_ok, (autor_id = beto) as autor_ok into r from consideracoes_candidato where id = con1;
  assert r.vaga_titulo = (select titulo from vagas where id = outra_vaga) and r.cand_ok and r.ent_ok and r.autor_ok, 'com entrevista: guarda o contexto (vaga, candidatura, entrevista, autor)';
  select (candidatura_id = cd) as cand_ok, (entrevista_id is null) as sem_ent into r from consideracoes_candidato where id = con2;
  assert r.cand_ok and r.sem_ent, 'sem entrevista: o contexto é a candidatura aberta';
  assert (select count(*) from logs_auditoria where acao = 'consideracao_registrada' and entidade_id = a) = 2, 'registro auditado';
  assert not exists (select 1 from logs_auditoria where acao = 'consideracao_registrada' and (dados_depois::text ilike '%pontual%' or detalhe ilike '%pontual%')),
    'a auditoria nunca guarda o texto';

  -- a RLS vale: existem 2 considerações, e usuário inativo não vê nenhuma (nem pela tabela, nem pela view)
  perform pg_temp.como(dani);
  assert (select count(*) from vw_consideracoes) = 0, 'usuário inativo não lê considerações (RLS)';
  assert (select count(*) from consideracoes_candidato) = 0, 'nem pela tabela';
  perform pg_temp.como(null);

  -- HERANÇA: a candidatura acaba (reprovado) e o candidato volta ao banco; as considerações continuam com ele
  update entrevistas set resultado = 'reprovado', observacoes = 'Sem disponibilidade', resultado_registrado_em = now() where id = e1;
  assert (select status_banco from candidatos where id = a) = 'ativo', 'voltou ao banco';
  perform pg_temp.como(carla);
  assert (select count(*) from vw_consideracoes where candidato_id = a) = 2, 'outro RH vê as considerações do candidato que voltou ao banco';
  select autor_nome into s from vw_consideracoes where id = con1;
  assert s = 'Beto RH', 'o nome de quem escreveu aparece mesmo para outro RH (a RLS de usuarios só mostra a própria linha), got ' || coalesce(s, '?');
  con2 := registrar_consideracao(a, 'Nova entrevista em outra vaga: melhor impressão.');
  assert (select candidatura_id is null from consideracoes_candidato where id = con2), 'candidato que voltou ao banco: a nota nova fica sem candidatura (não há processo aberto)';

  -- só o autor ou o administrador excluem
  perform pg_temp.deve_falhar(format($f$select excluir_consideracao(%L)$f$, con1), 'Só quem escreveu');
  perform pg_temp.como(beto);
  perform excluir_consideracao(con1);
  perform pg_temp.como(admin);
  perform excluir_consideracao(con2);
  perform pg_temp.como(null);
  assert (select count(*) from consideracoes_candidato where candidato_id = a) = 1, 'sobrou só a segunda do Beto (a primeira foi excluída por ele e a da Carla pelo administrador)';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select excluir_consideracao(%L)$f$, gen_random_uuid()), 'não encontrada');
  perform pg_temp.como(null);

  -- expurgo (exclusão de dados): apaga as considerações e a região junto com o resto
  update candidatos set regiao_id = (select id from regioes_df where nome = 'Gama'), regiao_origem = 'ia', bairro = 'Setor Leste' where id = a;
  perform fn_expurgar_candidato(a, 'teste');
  assert (select count(*) from consideracoes_candidato where candidato_id = a) = 0, 'expurgo apaga as considerações';
  assert (select regiao_id is null and regiao_origem is null and bairro is null and cidade is null from candidatos where id = a), 'expurgo apaga região e bairro';
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar(format($f$select registrar_consideracao(%L, 'depois de excluir')$f$, a), 'já excluído');
  perform pg_temp.como(null);

  -- privilégios: anônimo não chama nada disto
  reset role;
  set local role anon;
  begin
    perform 1 from ranking_candidatos_vaga(vaga, 1, 0, 'distancia', 10);
    raise exception 'anon não deveria executar o ranking';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from regioes_df;
    raise exception 'anon não deveria ler regioes_df';
  exception when insufficient_privilege then null;
  end;
  reset role;

  raise notice 'TESTE DA ETAPA 3: tudo certo';
end $$;

rollback;
