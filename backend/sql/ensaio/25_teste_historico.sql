-- Testes do HISTÓRICO DO CANDIDATO (042): preenchimento automático a partir das entrevistas, correção e registro à mão pelo RH, exclusão só do
-- administrador, permissões, o histórico que sobrevive à exclusão dos dados do candidato, auditoria sem dados pessoais e reaplicação da migração.
-- Roda depois de 020–042. Tudo dentro de uma transação que termina em ROLLBACK.
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

-- as 4 primeiras entrevistas agendadas do ensaio (o nome vem do cadastro do candidato)
create temp table t_e (n int primary key, id uuid, candidatura_id uuid);
insert into t_e (n, id, candidatura_id)
select row_number() over (order by c.nome, e.id), e.id, e.candidatura_id
  from entrevistas e join candidaturas ca on ca.id = e.candidatura_id join candidatos c on c.id = ca.candidato_id
 where e.resultado = 'agendada'
 order by c.nome, e.id limit 4;
grant select on t_e to authenticated;

do $$
declare
  admin constant uuid := '00000000-0000-0000-0000-0000000000a1';
  beto  constant uuid := '00000000-0000-0000-0000-0000000000b1';
  dani  constant uuid := '00000000-0000-0000-0000-0000000000c9';       -- usuária inativa
  e1 uuid := (select id from t_e where n = 1);
  e2 uuid := (select id from t_e where n = 2);
  e3 uuid := (select id from t_e where n = 3);
  e4 uuid := (select id from t_e where n = 4);
  h1 uuid; h3 uuid; hm uuid; hs uuid; cand3 uuid; nome3 text; nome_esperado text;
begin
  assert (select count(*) from t_e) = 4, 'o ensaio tem entrevistas agendadas de candidatos do banco';
  assert (select count(*) from historico_candidatos) = 0, 'entrevista só agendada não entra no histórico';

  -- ── preenchimento automático: aprovado, reprovado e não compareceu entram; remarcada não ──
  update entrevistas set resultado = 'aprovado', observacoes = 'Ótima conversa', resultado_registrado_em = now(), resultado_registrado_por = beto where id = e1;
  update entrevistas set resultado = 'reprovado', observacoes = 'Sem CNH', resultado_registrado_em = now(), resultado_registrado_por = beto where id = e2;
  update entrevistas set resultado = 'nao_compareceu', resultado_registrado_em = now(), resultado_registrado_por = beto where id = e3;
  update entrevistas set resultado = 'remarcada', resultado_registrado_em = now() where id = e4;
  assert (select count(*) from historico_candidatos) = 3, 'três desfechos, e a remarcada não conta';
  assert (select status from historico_candidatos where entrevista_id = e1) = 'aprovado';
  assert (select status from historico_candidatos where entrevista_id = e2) = 'reprovado';
  assert (select status from historico_candidatos where entrevista_id = e3) = 'nao_compareceu';
  assert not exists (select 1 from historico_candidatos where entrevista_id = e4), 'entrevista remarcada não é desfecho';

  -- a linha traz nome, celular, data, setor da vaga, status e observação copiados na hora
  select id into h1 from historico_candidatos where entrevista_id = e1;
  select coalesce(nullif(btrim(c.nome), ''), ca.dados_pessoais ->> 'nome') into nome_esperado
    from entrevistas e join candidaturas ca on ca.id = e.candidatura_id left join candidatos c on c.id = ca.candidato_id where e.id = e1;
  assert (select nome from historico_candidatos where id = h1) = nome_esperado, 'o nome vem do cadastro';
  assert (select data_evento from historico_candidatos where id = h1)
       = (select (data_hora at time zone 'America/Sao_Paulo')::date from entrevistas where id = e1), 'a data é a da entrevista (horário de Brasília)';
  assert (select setor_vaga from historico_candidatos where id = h1) = (select s.nome from entrevistas e join candidaturas ca on ca.id = e.candidatura_id
           join vagas v on v.id = ca.vaga_id join setores s on s.id = v.setor_id where e.id = e1), 'o setor é o da vaga';
  assert (select observacao from historico_candidatos where id = h1) = 'Ótima conversa';
  assert (select origem || '/' || alterado_manual::text from historico_candidatos where id = h1) = 'sistema/false';
  assert (select registrado_por from historico_candidatos where id = h1) = beto, 'guarda quem registrou o resultado';

  -- corrigir a observação ou o resultado na entrevista atualiza a MESMA linha (sem duplicar)
  update entrevistas set observacoes = 'Ótima conversa (corrigida)' where id = e1;
  assert (select count(*) from historico_candidatos where entrevista_id = e1) = 1, 'não duplica';
  assert (select observacao from historico_candidatos where entrevista_id = e1) = 'Ótima conversa (corrigida)';
  update entrevistas set resultado = 'aprovado', observacoes = 'Sem CNH' where id = e2;
  assert (select status from historico_candidatos where entrevista_id = e2) = 'aprovado', 'resultado corrigido acompanha';
  update entrevistas set resultado = 'remarcada' where id = e2;
  assert not exists (select 1 from historico_candidatos where entrevista_id = e2), 'deixou de ser desfecho: a linha automática some';

  -- ── o RH registra a desistência (depois de aprovado) e a linha deixa de acompanhar a entrevista ──
  perform pg_temp.como(beto);
  perform historico_alterar(h1, '{"status": "desistencia", "observacao": "Desistiu na documentação"}');
  perform pg_temp.como(null);
  assert (select status || '/' || observacao || '/' || alterado_manual::text from historico_candidatos where id = h1) = 'desistencia/Desistiu na documentação/true';
  assert (select atualizado_por from historico_candidatos where id = h1) = beto;
  update entrevistas set observacoes = 'mudou de novo na entrevista' where id = e1;
  assert (select status from historico_candidatos where id = h1) = 'desistencia', 'o que o RH corrigiu não é refeito pela entrevista';
  assert (select observacao from historico_candidatos where id = h1) = 'Desistiu na documentação';
  update entrevistas set resultado = 'remarcada' where id = e1;
  assert exists (select 1 from historico_candidatos where id = h1), 'linha alterada à mão não some';
  update entrevistas set resultado = 'aprovado' where id = e1;

  -- ── registro à mão: sem interesse, e a validação dos campos ──
  perform pg_temp.como(beto);
  hm := historico_registrar('{"nome": "  Fulano de Tal  ", "telefone": "(61) 99999-1234", "status": "sem_interesse", "setor_vaga": "Logística",
                              "data_evento": "2026-09-01", "observacao": "Não tem interesse na vaga"}');
  perform pg_temp.como(null);
  assert (select nome || '|' || telefone || '|' || status || '|' || setor_vaga || '|' || data_evento::text || '|' || origem
            from historico_candidatos where id = hm) = 'Fulano de Tal|(61) 99999-1234|sem_interesse|Logística|2026-09-01|manual';
  assert (select telefone_digitos from historico_candidatos where id = hm) = '61999991234', 'busca por telefone só com números';
  assert (select nome_norm from historico_candidatos where id = hm) = 'fulano de tal';
  perform pg_temp.como(beto);
  hs := historico_registrar('{"nome": "Sem Data", "status": "reprovado"}');
  assert (select data_evento from historico_candidatos where id = hs) = current_date, 'sem data vale hoje';
  perform pg_temp.deve_falhar($f$select historico_registrar('{"status": "aprovado"}')$f$, 'Informe o nome');
  perform pg_temp.deve_falhar($f$select historico_registrar('{"nome": "X", "status": "talvez"}')$f$, 'Escolha o status');
  perform pg_temp.deve_falhar($f$select historico_registrar('{"nome": "X"}')$f$, 'Escolha o status');
  perform pg_temp.deve_falhar($f$select historico_registrar('{"nome": "X", "status": "aprovado", "data_evento": "31/02/2026"}')$f$, 'Data inválida');
  perform pg_temp.deve_falhar($f$select historico_registrar('{"nome": "X", "status": "aprovado", "telefone": "123"}')$f$, 'Telefone inválido');
  perform pg_temp.deve_falhar(format($f$select historico_alterar(%L, '{"status": "outro"}')$f$, hm), 'Escolha o status');
  perform pg_temp.deve_falhar(format($f$select historico_alterar(%L, '{"nome": "  "}')$f$, hm), 'Informe o nome');
  perform pg_temp.deve_falhar(format($f$select historico_alterar(%L, '{"data_evento": ""}')$f$, hm), 'Informe a data');
  perform pg_temp.deve_falhar($f$select historico_alterar('00000000-0000-0000-0000-00000000dead', '{"status": "aprovado"}')$f$, 'Registro não encontrado');
  perform pg_temp.como(null);

  -- ── permissões ──
  perform pg_temp.como(beto);
  assert (select count(*) from historico_candidatos) >= 3, 'o RH lê o histórico';
  assert (select count(*) from vw_historico_candidatos) >= 3, 'e a view';
  perform pg_temp.deve_falhar(format($f$update historico_candidatos set status = 'aprovado' where id = %L$f$, hm), 'permission denied');
  perform pg_temp.deve_falhar($f$insert into historico_candidatos (nome, data_evento, status) values ('X', current_date, 'aprovado')$f$, 'permission denied');
  perform pg_temp.deve_falhar(format($f$delete from historico_candidatos where id = %L$f$, hm), 'permission denied');
  perform pg_temp.deve_falhar(format($f$select historico_excluir(%L)$f$, hm), 'Somente o administrador');
  perform pg_temp.como(dani);
  assert (select count(*) from historico_candidatos) = 0, 'usuário inativo não vê nada';
  perform pg_temp.deve_falhar($f$select historico_registrar('{"nome": "X", "status": "aprovado"}')$f$, 'inativo');
  perform pg_temp.como(null);

  -- ── o histórico SOBREVIVE à exclusão dos dados do candidato (é de propósito) ──
  select id, candidato_id, nome into h3, cand3, nome3 from historico_candidatos where entrevista_id = e3;
  assert cand3 is not null, 'a linha está ligada ao candidato do banco';
  perform fn_expurgar_candidato(cand3, 'teste do histórico');
  assert (select nome is null from candidatos where id = cand3), 'os dados do candidato foram excluídos';
  assert (select nome from historico_candidatos where id = h3) = nome3, 'mas o nome continua no histórico, o mesmo de antes';
  assert (select status from historico_candidatos where id = h3) = 'nao_compareceu';
  assert (select email is null and cidade is null and area_sugerida is null from vw_historico_candidatos where id = h3), 'da view some o que era do cadastro';
  perform pg_temp.como(admin);
  assert (select count(*) from vw_historico_candidatos where id = h3) = 1, 'a linha continua aparecendo na tela';
  perform pg_temp.como(null);

  -- ── exclusão: só o administrador, e fica na auditoria sem dados pessoais ──
  perform pg_temp.como(admin);
  perform historico_excluir(hm);
  perform pg_temp.como(null);
  assert not exists (select 1 from historico_candidatos where id = hm), 'o administrador exclui';
  assert (select count(*) from logs_auditoria where entidade = 'historico_candidatos' and acao = 'criacao') >= 2;
  assert (select count(*) from logs_auditoria where entidade = 'historico_candidatos' and acao = 'atualizacao') >= 1;
  assert (select count(*) from logs_auditoria where entidade = 'historico_candidatos' and acao = 'exclusao_manual_lgpd') = 1;
  assert not exists (select 1 from logs_auditoria where entidade = 'historico_candidatos'
                       and (coalesce(dados_depois::text, '') || coalesce(detalhe, '')) ilike any (array['%Fulano%', '%99999%', '%documenta%', '%Logística%'])),
    'a auditoria guarda só o status e o nome dos campos, nunca nome, telefone nem observação';
end $$;

-- reaplicar a migração (o deploy repete tudo): não duplica nem desfaz o que o RH corrigiu
create temp table t_antes as select id, status, alterado_manual, nome from historico_candidatos;
\i /repo/backend/sql/042_historico_candidato.sql

do $$
begin
  assert (select count(*) from historico_candidatos) = (select count(*) from t_antes), 'reaplicar não duplica';
  assert (select count(*) from historico_candidatos h join t_antes a using (id) where h.status = a.status and h.nome = a.nome) = (select count(*) from t_antes),
    'reaplicar não muda o que já estava';
  assert (select count(*) from historico_candidatos where alterado_manual) = (select count(*) from t_antes where alterado_manual), 'a correção do RH continua';

  -- entrevista com desfecho que ainda não estava no histórico (de antes da tabela existir) entra pelo preenchimento da migração
  delete from historico_candidatos where entrevista_id = (select id from t_e where n = 3);
  assert (select count(*) from historico_candidatos) = (select count(*) from t_antes) - 1;
end $$;
\i /repo/backend/sql/042_historico_candidato.sql
do $$
begin
  assert (select count(*) from historico_candidatos where entrevista_id = (select id from t_e where n = 3)) = 1, 'a migração preenche o que faltava';
  assert (select count(*) from historico_candidatos) = (select count(*) from t_antes), 'e só isso';
  raise notice 'TESTE DO HISTÓRICO DO CANDIDATO: tudo certo';
end $$;

rollback;
