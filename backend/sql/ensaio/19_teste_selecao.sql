-- Testes da SELEÇÃO DE CURRÍCULOS POR QUALIFICAÇÃO (033): nota do currículo, função e nível da vaga, filtro exato por
-- setor + função + nível, ordem pela nota. Roda depois de 020–033. Tudo dentro de uma transação que termina em ROLLBACK.
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
-- candidato com um currículo atual já qualificado
create or replace function pg_temp.cand(p_nome text, p_setor text, p_funcao text, p_nivel text, p_nota int, p_cidade text default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into candidatos (nome, hash_identidade, cidade) values (p_nome, 'h-' || p_nome, p_cidade) returning id into v;
  insert into curriculos (candidato_id, origem, texto_extraido, setor_adequado, funcao_setor, nivel_funcao, nota_classificacao)
    values (v, 'anexo_pdf', 'Currículo de ' || p_nome, p_setor, p_funcao, p_nivel, p_nota);
  return v;
end $$;
create or replace function pg_temp.ordem(p_vaga uuid, p_ordem text default 'nota', p_km numeric default null)
returns text[] language sql as $$
  select coalesce(array_agg(c.nome order by t.ord), '{}')
    from selecionar_curriculos_vaga(p_vaga, 50, 0, p_ordem, p_km) with ordinality t(candidato_id, nota, total, km, loja, ord)
    join candidatos c on c.id = t.candidato_id $$;

do $$
declare
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  dani  constant uuid := '00000000-0000-0000-0000-0000000000c9';
  logistica uuid; vendas uuid; vaga uuid; vaga_legada uuid; cfs uuid;
  a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; g uuid; h uuid; i uuid; j uuid; cid uuid; vaga3 uuid;
begin
  select id into logistica from setores where nome = 'Logística';
  select id into vendas from setores where nome = 'Loja';
  select id into cfs from empresas where sigla = 'CFS';

  -- ── nota do currículo ──
  a := pg_temp.cand('Sel A', 'Logística', 'Supervisor', 'pleno', 90);
  assert (select nota_classificacao from curriculos where candidato_id = a) = 90, 'a nota grava';
  perform pg_temp.deve_falhar(format($f$update curriculos set nota_classificacao = 101 where candidato_id = %L$f$, a), 'nota_classificacao_check');
  perform pg_temp.deve_falhar(format($f$update curriculos set nota_classificacao = -1 where candidato_id = %L$f$, a), 'nota_classificacao_check');
  update curriculos set nota_classificacao = null where candidato_id = a;                       -- sem nota (ainda não qualificado) é válido
  update curriculos set nota_classificacao = 90 where candidato_id = a;

  -- ── vaga: função e nível ──
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao)
    values (logistica, 'Supervisor do CD', 1, 'Supervisor', 'pleno') returning id into vaga;
  perform pg_temp.deve_falhar(format($f$insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (%L, 'x', 1, 'Vendedor', 'pleno')$f$, logistica),
                              'não existe no setor escolhido');                                 -- Vendedor é de Loja e de CR, não de Logística
  perform pg_temp.deve_falhar(format($f$insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (%L, 'x', 1, 'Supervisor', 'master')$f$, logistica),
                              'vagas_nivel_funcao_fkey');
  perform pg_temp.deve_falhar(format($f$update vagas set setor_id = %L where id = %L$f$, vendas, vaga), 'não existe no setor escolhido');   -- trocar o setor sem trocar a função
  -- Jovem Aprendiz e Trainee só nos cargos que os aceitam (Logística/Auxiliar sim; Logística/Supervisor não)
  perform pg_temp.deve_falhar(format($f$insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (%L, 'x', 1, 'Supervisor', 'trainee')$f$, logistica),
                              'Jovem Aprendiz e Trainee só existem para');
  perform pg_temp.deve_falhar(format($f$insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (%L, 'x', 1, 'Supervisor', 'jovem_aprendiz')$f$, logistica),
                              'Jovem Aprendiz e Trainee só existem para');
  perform pg_temp.deve_falhar(format($f$update vagas set nivel_funcao = 'trainee' where id = %L$f$, vaga), 'Jovem Aprendiz e Trainee só existem para');   -- trocar só o nível também vale
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'Auxiliar de Logística iniciante', 1, 'Auxiliar', 'trainee');
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'Auxiliar de Logística aprendiz', 1, 'Auxiliar', 'jovem_aprendiz');
  insert into vagas (setor_id, titulo, quantidade) values (logistica, 'Vaga legada (sem função nem nível)', 1) returning id into vaga_legada;
  assert (select funcao_setor is null and nivel_funcao is null from vagas where id = vaga_legada), 'vaga antiga continua válida, sem função e nível';

  -- ── seleção: só setor + função + nível exatamente iguais, maior nota primeiro ──
  b := pg_temp.cand('Sel B', 'Logística', 'Supervisor', 'pleno', 70);
  c := pg_temp.cand('Sel C', 'Logística', 'Supervisor', 'junior', 95);                          -- nível diferente
  d := pg_temp.cand('Sel D', 'Logística', 'Encarregado', 'pleno', 99);                  -- função diferente
  e := pg_temp.cand('Sel E', 'Loja', 'Supervisor', 'pleno', 99);                              -- setor diferente
  f := pg_temp.cand('Sel F', 'Logística', 'Supervisor', 'pleno', 85);
  g := pg_temp.cand('Sel G', 'Logística', 'Supervisor', 'pleno', null);                         -- sem nota: vai por último
  h := pg_temp.cand('Sel H', 'Logística', 'Supervisor', 'pleno', 88);
  update candidatos set status_banco = 'inativo' where id = h;                                  -- não está disponível
  assert pg_temp.ordem(vaga) = array['Sel A', 'Sel F', 'Sel B', 'Sel G'], 'só o que combina nos três campos, da maior nota para a menor, sem nota por último; got ' || pg_temp.ordem(vaga)::text;
  assert (select total from selecionar_curriculos_vaga(vaga, 2, 0) limit 1) = 4, 'total = todos que combinam, mesmo com a página menor';
  assert (select count(*) from selecionar_curriculos_vaga(vaga, 2, 0)) = 2 and (select count(*) from selecionar_curriculos_vaga(vaga, 2, 3)) = 1, 'paginação';
  assert pg_temp.ordem(vaga_legada) = '{}', 'vaga sem função e nível não seleciona ninguém';

  -- currículo antigo (não atual) não conta; o atual sim
  update curriculos set atual = false where candidato_id = f;
  assert pg_temp.ordem(vaga) = array['Sel A', 'Sel B', 'Sel G'], 'só o currículo atual do candidato conta';
  update curriculos set atual = true where candidato_id = f;

  -- lista negra e candidatura aberta, reprovada ou descartada nesta vaga tiram o candidato
  update candidatos set lista_negra = true where id = g;
  assert pg_temp.ordem(vaga) = array['Sel A', 'Sel F', 'Sel B'], 'lista negra fica de fora';
  cid := fn_atribuir_candidato_vaga(b, vaga, beto);
  assert (select avaliacao_pendente from candidaturas where id = cid) = false, 'atribuir não pede mais avaliação da IA';
  assert pg_temp.ordem(vaga) = array['Sel A', 'Sel F'], 'quem está em processo nesta vaga sai da seleção';
  update candidaturas set status = 'reprovado', encerrada_em = now() where id = cid;
  assert pg_temp.ordem(vaga) = array['Sel A', 'Sel F'], 'reprovado nesta vaga não volta a ela (só em vaga nova)';

  -- o card da vaga conta os mesmos currículos
  assert (select compativeis_no_banco from vw_vagas_resumo where id = vaga) = 2, 'a contagem "No banco" do card é a da seleção';
  assert (select compativeis_no_banco from vw_vagas_resumo where id = vaga_legada) = 0, 'vaga sem função e nível: zero';
  assert (select funcao_setor = 'Supervisor' and nivel_funcao = 'pleno' from vw_vagas_resumo where id = vaga), 'a view traz a função e o nível da vaga';

  -- ── distância: a ordem pode ser pela loja mais próxima e o limite de km corta quem mora longe ──
  update candidatos set cidade = 'Samambaia' where id = a;
  update candidatos set cidade = 'Gama' where id = f;
  update curriculos set nota_classificacao = 60 where candidato_id = a;                          -- a tem a MENOR nota, mas mora na loja
  insert into vaga_empresas (vaga_id, empresa_id) values (vaga, cfs);
  assert pg_temp.ordem(vaga, 'nota') = array['Sel F', 'Sel A'], 'ordem padrão: nota';
  assert pg_temp.ordem(vaga, 'distancia') = array['Sel A', 'Sel F'], 'ordem por distância: quem mora mais perto da loja primeiro';
  assert pg_temp.ordem(vaga, 'nota', 5) = array['Sel A'], 'limite de km: só quem mora até 5 km da loja';

  -- ── o expurgo apaga a nota junto com o resto da qualificação ──
  update curriculos set texto_extraido = null where candidato_id = a;
  assert (select nota_classificacao is null and setor_adequado is null from curriculos where candidato_id = a), 'expurgo: a nota sai com a qualificação';

  -- ── atribuir grava a qualificação da VAGA no currículo (034), sem IA; cancelar a seleção não a perde ──
  i := pg_temp.cand('Sel I', 'Loja', 'Vendedor', 'junior', 50);                               -- a IA classificou em OUTRO setor
  update candidatos set revisao_manual = true where id = i;
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao)
    values (logistica, 'Vaga completa para a atribuição', 1, 'Supervisor', 'senior') returning id into vaga3;
  cid := fn_atribuir_candidato_vaga(i, vaga3, beto);
  assert (select setor_adequado = 'Logística' and funcao_setor = 'Supervisor' and nivel_funcao = 'senior' from curriculos where candidato_id = i and atual),
    'atribuir: o currículo passa a ter o setor, a função e o nível da vaga';
  assert (select nota_classificacao from curriculos where candidato_id = i) = 50, 'a nota (da IA) não muda';
  assert (select area_sugerida = 'Logística' and cargo_sugerido = 'Supervisor' and nivel_sugerido = 'senior' and not revisao_manual from candidatos where id = i),
    'o candidato (o que o painel lê) acompanha e a pendência de revisão manual sai';
  assert exists (select 1 from logs_auditoria where acao = 'atribuicao_candidato' and entidade_id = cid
                    and dados_depois -> 'qualificacao_gravada' ->> 'funcao' = 'Supervisor'
                    and dados_depois -> 'qualificacao_gravada' -> 'anterior' ->> 'setor' = 'Loja'),
    'a auditoria guarda a qualificação de ANTES';

  -- cancelar a seleção: o candidato volta ao banco e o currículo NÃO perde a qualificação
  perform pg_temp.como(beto);
  perform encerrar_candidatura(cid, 'cancelado', 'Seleção cancelada pelo RH');
  perform pg_temp.como(null);
  assert (select status_banco from candidatos where id = i) = 'ativo', 'cancelar a seleção devolve o candidato ao banco';
  assert (select setor_adequado = 'Logística' and funcao_setor = 'Supervisor' and nivel_funcao = 'senior' and nota_classificacao = 50
            from curriculos where candidato_id = i and atual), 'o currículo continua qualificado depois de cancelar';
  assert 'Sel I' = any (pg_temp.ordem(vaga3)), 'e volta a aparecer na seleção da vaga (candidatura cancelada não barra)';

  -- a tela "Candidatos em processo" por vaga (037): a view traz vaga_id, a qualificação e a nota do currículo
  cid := fn_atribuir_candidato_vaga(i, vaga3, beto);                                             -- de novo (a anterior foi cancelada)
  assert (select vaga_id = vaga3 and area_sugerida = 'Logística' and cargo_sugerido = 'Supervisor' and nivel_sugerido = 'senior' and nota_curriculo = 50
            from vw_candidatos where id = cid), 'vw_candidatos: vaga, qualificação e nota do currículo';
  assert (select nota_curriculo = 50 from vw_candidaturas where id = cid), 'vw_candidaturas: nota do currículo';
  assert (select count(*) from vw_candidatos where vaga_id = vaga3) = 1, 'filtrar por vaga_id: só a candidatura aberta (a cancelada sai da tela)';
  perform pg_temp.como(beto);
  perform encerrar_candidatura(cid, 'cancelado', 'Seleção cancelada pelo RH');
  perform pg_temp.como(null);

  -- vaga antiga (sem função e nível): atribuir não mexe na qualificação
  j := pg_temp.cand('Sel J', 'Loja', 'Vendedor', 'pleno', 60);
  perform fn_atribuir_candidato_vaga(j, vaga_legada, beto);
  assert (select setor_adequado = 'Loja' and funcao_setor = 'Vendedor' and nivel_funcao = 'pleno' from curriculos where candidato_id = j),
    'vaga sem função e nível: a qualificação do currículo fica como estava';
  assert (select status_banco from candidatos where id = j) = 'em_processo', 'mas o candidato foi atribuído';

  -- ── acesso: RH ativo seleciona; inativo não vê ninguém; anônimo nem executa ──
  perform pg_temp.como(beto);
  assert pg_temp.ordem(vaga) = array['Sel F'], 'RH ativo executa a seleção (Sel A já foi expurgado)';
  perform pg_temp.como(dani);
  assert pg_temp.ordem(vaga) = '{}', 'usuário inativo não vê nenhum candidato (RLS)';
  perform pg_temp.como(null);
  set local role anon;
  begin
    perform 1 from selecionar_curriculos_vaga(vaga);
    raise exception 'anon não deveria executar a seleção';
  exception when insufficient_privilege then null;
  end;
  reset role;

  raise notice 'TESTE DA SELEÇÃO POR QUALIFICAÇÃO: tudo certo';
end $$;

rollback;
