-- Confere o banco DEPOIS de zerar_banco_talentos.sql (rodado com a trava em SIM sobre o que 12_zerar_preparar.sql deixou):
--   • o que devia sumir sumiu;  • o que devia ficar, ficou;  • os arquivos foram para a fila de remoção;
--   • a auditoria registrou;    • as telas (views) e o fluxo principal funcionam a partir do zero.
-- O teste do fluxo termina em ROLLBACK: o banco continua zerado.
\set ON_ERROR_STOP on
begin;

do $$
declare
  a record; v_vaga uuid; v_usuario uuid; c uuid; cand uuid; st public.status_banco_talentos; n int;
begin
  select * into a from public.ensaio_zerar_antes;
  assert a.candidatos > 0 and a.candidaturas > 0 and a.arquivos >= 3 and a.bloqueados = 1,
    'o ensaio precisa de dados antes de zerar';

  -- ── some ──
  assert (select count(*) from candidatos) = 0,              'candidatos';
  assert (select count(*) from candidaturas) = 0,            'candidaturas';
  assert (select count(*) from curriculos) = 0,              'currículos';
  assert (select count(*) from analises_ia) = 0,             'análises';
  assert (select count(*) from avaliacoes) = 0,              'avaliações';
  assert (select count(*) from entrevistas) = 0,             'entrevistas';
  assert (select count(*) from excecoes) = 0,                'exceções';
  assert (select count(*) from uploads_manuais) = 0,         'uploads manuais';
  assert (select count(*) from sanitizacao_sugestoes) = 0,   'sugestões';
  assert (select count(*) from sanitizacao_ciclos) = 0,      'ciclos';
  assert (select count(*) from remetentes where not bloqueado) = 0, 'remetentes livres';

  -- ── fica ──
  assert (select count(*) from vagas) = a.vagas,             'vagas';
  assert (select count(*) from requisitos) > 0,              'requisitos das vagas';
  assert (select count(*) from usuarios) = a.usuarios,       'usuários';
  assert (select count(*) from remetentes where bloqueado) = a.bloqueados, 'remetente bloqueado';
  assert (select string_agg(chave || '=' || valor::text, ',' order by chave)
            from configuracoes where chave in ('imap_ultimo_uid', 'imap_uidvalidity')) = a.marcador,
    'marcador do e-mail';
  assert (select count(*) from logs_auditoria) > a.logs,     'a auditoria deve ter ganhado o registro da operação';

  -- ── arquivos do Storage: todos na fila, nenhum já marcado como removido ──
  assert (select count(*) from arquivos_para_remover where removido_em is null) >= a.arquivos, 'fila de arquivos';
  assert (select count(*) from arquivos_para_remover
           where storage_path in ('2026/09/upload-teste.pdf', '2026/09/excecao-teste.pdf')) = 2,
    'caminhos do upload manual e da exceção na fila';

  -- ── auditoria: quem/o quê/quanto ──
  select count(*) into n from logs_auditoria
   where entidade = 'sistema' and detalhe like 'Banco de Talentos zerado%'
     and (dados_antes ->> 'candidatos')::int = a.candidatos
     and (dados_antes ->> 'candidaturas')::int = a.candidaturas;
  assert n = 1, 'registro de auditoria da operação (achou ' || n || ')';

  -- ── as telas do painel respondem, vazias ──
  assert (select count(*) from vw_banco_talentos) = 0,      'vw_banco_talentos';
  assert (select count(*) from vw_banco_opcoes) = 0,        'vw_banco_opcoes';
  assert (select count(*) from vw_candidaturas) = 0,        'vw_candidaturas';
  assert (select count(*) from vw_candidatos) = 0,          'vw_candidatos';
  assert (select count(*) from vw_agenda_entrevistas) = 0,  'vw_agenda_entrevistas';
  assert (select count(*) from vw_sanitizacao_sugestoes) = 0, 'vw_sanitizacao_sugestoes';
  assert (select count(*) from vw_vagas_resumo) > 0, 'as vagas abertas continuam aparecendo';
  assert (select coalesce(sum(total_candidatos + total_em_aberto + total_entrevistas + total_contratados
                               + compativeis_no_banco), 0) from vw_vagas_resumo) = 0, 'vagas sem candidatos, entrevistas nem compatíveis';
  assert (select count(*) from vw_dashboard_metricas) = 1,  'vw_dashboard_metricas devolve uma linha de zeros';
  assert (select count(*) from filtrar_banco_talentos('{}'::jsonb)) = 0, 'filtrar_banco_talentos';
  assert (select count(*) from fn_sanitizacao_avaliar(fn_sanitizacao_parametros())) = 0, 'sanitização sem candidatos';

  -- ── o fluxo principal funciona a partir do zero (tudo abaixo é desfeito no ROLLBACK) ──
  select id into v_vaga from vagas where status = 'ativo' order by titulo limit 1;
  select id into v_usuario from usuarios where perfil = 'administrador' limit 1;

  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Depois de zerar', 'Brasília', 'DF', 'hash-depois-de-zerar')
    returning id into c;
  insert into curriculos (candidato_id, origem, texto_extraido, email_message_id)
    values (c, 'anexo_pdf', 'texto do currículo', 'msg-depois-de-zerar');
  insert into analises_ia (candidato_id, sequencia, area_sugerida, cargo_sugerido, nivel_sugerido, confianca, versao_modelo_ia)
    values (c, 1, 'Logística', 'Conferente', 'pleno', 85, 'teste');
  assert (select count(*) from vw_banco_talentos) = 1, 'o candidato novo aparece no banco';
  assert (select area_sugerida from candidatos where id = c) = 'Logística', 'a análise chegou ao candidato';

  cand := public.fn_atribuir_candidato_vaga(c, v_vaga, v_usuario, 'teste depois de zerar');
  select status_banco into st from candidatos where id = c;
  assert st = 'em_processo', 'atribuir leva o candidato a "em processo"';

  update candidaturas set status = 'reprovado', resultado_final = 'teste' where id = cand;
  select status_banco into st from candidatos where id = c;
  assert st = 'ativo', 'reprovado volta ao banco';

  raise notice 'ZERAR: tudo certo (some o que devia, fica o que devia, telas e fluxo funcionam do zero)';
end $$;

rollback;
