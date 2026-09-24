-- Dados SINTÉTICOS (nenhum dado real) com o mesmo perfil de produção em 2026-09-23:
-- 109 candidaturas (100 avaliado + 1 avaliado sem hash + 3 recebido + 5 entrevista_agendada),
-- 6 hashes repetidos, 127 avaliações, 108 currículos, 5 entrevistas — mais linhas de borda que a migração
-- precisa tratar mesmo não existindo hoje (reprovado, contratado, descartado, não compareceu, inativo,
-- expurgado, sem vaga).
\set ON_ERROR_STOP on
select setseed(0.42);

insert into usuarios (id, nome, email, perfil) values
 ('00000000-0000-0000-0000-0000000000a1', 'Ana Admin',  'admin@x.test',  'administrador'),
 ('00000000-0000-0000-0000-0000000000b1', 'Beto RH',    'beto@x.test',   'gerente_rh'),
 ('00000000-0000-0000-0000-0000000000b2', 'Carla RH',   'carla@x.test',  'gerente_rh');
insert into usuarios (id, nome, email, perfil, ativo) values
 ('00000000-0000-0000-0000-0000000000c9', 'Dani Inativa', 'dani@x.test', 'gerente_rh', false);

insert into setores (nome, slug, ordem) values
 ('Logística','logistica',1),('Vendas','vendas',2),('Financeiro','financeiro',3),('Administrativo','administrativo',4),
 ('Recursos Humanos','rh',5),('Tecnologia','ti',6),('Produção','producao',7),('Atendimento','atendimento',8);
insert into empresas (sigla, nome) values ('CFS','Castelo Forte S'),('CFR','Castelo Forte R');

insert into vagas (setor_id, titulo, descricao, perfil_comportamental, quantidade)
select s.id, 'Vaga ' || s.nome || ' ' || g, 'Descrição da vaga ' || s.nome, 'Proativo', 1 + g % 2
  from setores s cross join generate_series(1, 2) g
 where s.ordem <= 5 and not (s.ordem = 5 and g = 2);   -- 9 vagas abertas
insert into vagas (setor_id, titulo, status, deleted_at, data_encerramento)
select id, 'Vaga encerrada', 'inativo', now(), current_date from setores where ordem = 1;
insert into requisitos (vaga_id, descricao, tipo, peso, ordem)
select id, 'Requisito obrigatório', 'obrigatorio', 1, 0 from vagas where status = 'ativo';

insert into remetentes (email) select 'remetente' || g || '@mail.test' from generate_series(1, 114) g;

-- ── 104 candidaturas de triagem: 1..98 únicas + 99..104 repetem 1..6 (6 hashes repetidos; a 104ª sem hash) ──
create temp table _semente as
select g,
       'Candidato ' || lpad((case when g > 98 then g - 98 else g end)::text, 3, '0') || ' Silva' as nome,
       '5561' || (900000000 + (case when g > 98 then g - 98 else g end) * 137)::text as tel
  from generate_series(1, 104) g;

insert into candidaturas (remetente_id, vaga_id, dados_pessoais, hash_identidade, status, aderencia_vaga,
                          email_message_id, email_assunto, recebido_em)
select (select id from remetentes order by email offset (s.g % 114) limit 1),
       (select id from vagas where status = 'ativo' order by titulo offset (s.g % 9) limit 1),
       jsonb_strip_nulls(jsonb_build_object(
         'nome', s.nome, 'telefone', s.tel, 'telefone_e164', s.tel,
         'email', lower(replace(s.nome, ' ', '.')) || '@mail.test',
         'cidade', (array['Brasília/DF','Taguatinga - DF','Goiânia/GO','Ceilândia, DF','Valparaíso de Goiás', null, 'Planaltina/DF'])[1 + s.g % 7],
         'idade', case when s.g % 3 = 0 then 20 + s.g % 30 end,
         'escolaridade', (array['medio','tecnico','superior','fundamental', null])[1 + s.g % 5],
         'anos_experiencia', case when s.g % 4 <> 0 then (s.g % 12) + 0.5 end,
         'cnh', case when s.g % 6 = 0 then 'B' end,
         'sexo', case when s.g % 12 = 0 then 'feminino' when s.g % 12 = 6 then 'masculino' end,
         'perfil_v', 1)),
       case when s.g = 104 then null else encode(extensions.digest(s.nome || '|' || s.tel, 'sha256'), 'hex') end,
       case when s.g <= 3 then 'recebido'::status_candidatura else 'avaliado'::status_candidatura end,
       40 + s.g % 55,
       'msg-' || s.g || '@mail.test',
       'Currículo ' || s.g,
       now() - ((104 - s.g) || ' hours')::interval * 1.2
  from _semente s;
-- a 104ª (sem hash) simula currículo sem telefone
update candidaturas set dados_pessoais = dados_pessoais - 'telefone' - 'telefone_e164' where hash_identidade is null;

-- 103 currículos entre as 104 (a 104ª fica sem currículo, como em produção há 1 candidatura sem arquivo)
insert into curriculos (candidatura_id, storage_path, nome_arquivo, tipo_mime, tamanho_bytes, origem, texto_extraido)
select c.id, '2026/09/' || replace(gen_random_uuid()::text, '-', '') || '.pdf', 'cv_' || row_number() over () || '.pdf',
       'application/pdf', 20000, 'anexo_pdf',
       'Nome: ' || (c.dados_pessoais ->> 'nome') || E'\nExperiência: auxiliar de logística\nCidade: ' || coalesce(c.dados_pessoais ->> 'cidade', 'n/d')
  from candidaturas c where c.hash_identidade is not null
 order by c.recebido_em;

-- avaliações: 1 por candidatura + segunda opinião nas 23 mais antigas
insert into avaliacoes (candidatura_id, vaga_id, nota, resumo_nota, resumo_ia, pontos_fortes, lacunas, versao_criterios, modelo_ia, sequencia)
select c.id, c.vaga_id, 30 + (row_number() over (order by c.recebido_em)) % 65, 'Nota', 'Resumo IA da candidatura',
       array['Experiência em logística', 'Baixa rotatividade: ficou 5 anos'],
       array['Sem curso técnico', 'Alta rotatividade: 4 empregos em 2 anos'], 1, 'claude-sonnet-5', 1
  from candidaturas c;
insert into avaliacoes (candidatura_id, vaga_id, nota, resumo_ia, pontos_fortes, lacunas, versao_criterios, modelo_ia, sequencia, divergencia_detectada)
select id, vaga_id, 55, 'Segunda opinião', array['Experiência em logística', 'Baixa rotatividade: ficou 5 anos'],
       array['Sem curso técnico'], 1, 'claude-sonnet-5', 2, true
  from (select id, vaga_id from candidaturas order by recebido_em limit 23) x;

-- ── 5 candidaturas com entrevista agendada (o trigger move de 'selecionado' para 'entrevista_agendada') ──
insert into candidaturas (remetente_id, vaga_id, dados_pessoais, hash_identidade, status, recebido_em, selecionado_em, selecionado_por)
select (select id from remetentes order by email offset 100 + g limit 1),
       (select id from vagas where status = 'ativo' order by titulo offset g limit 1),
       jsonb_build_object('nome', 'Entrevistado ' || g || ' Souza', 'telefone', '556198800000' || g, 'telefone_e164', '556198800000' || g,
                          'email', 'entrev' || g || '@mail.test', 'cidade', 'Brasília/DF', 'idade', 30 + g),
       encode(extensions.digest('Entrevistado ' || g, 'sha256'), 'hex'),
       'selecionado', now() - interval '3 days', now() - interval '2 days', '00000000-0000-0000-0000-0000000000b1'
  from generate_series(1, 5) g;
insert into curriculos (candidatura_id, storage_path, nome_arquivo, tipo_mime, origem, texto_extraido)
select id, '2026/09/ent' || row_number() over () || '.pdf', 'ent.pdf', 'application/pdf', 'anexo_pdf', 'Currículo de ' || (dados_pessoais ->> 'nome')
  from candidaturas where dados_pessoais ->> 'nome' like 'Entrevistado%';
insert into avaliacoes (candidatura_id, vaga_id, nota, resumo_ia, versao_criterios, modelo_ia, sequencia)
select id, vaga_id, 80, 'Forte', 1, 'claude-sonnet-5', 1 from candidaturas where dados_pessoais ->> 'nome' like 'Entrevistado%';
insert into entrevistas (candidatura_id, data_hora, agendado_por)
select id, now() + interval '2 days', '00000000-0000-0000-0000-0000000000b1' from candidaturas where dados_pessoais ->> 'nome' like 'Entrevistado%';

-- ── Linhas de borda ──
do $$
declare r uuid; v uuid; i int;
  nomes text[] := array['Edge Reprovado','Edge Contratado','Edge Descartado','Edge NaoCompareceu','Edge Inativo','Edge Expurgado','Edge SemVaga'];
begin
  select id into r from remetentes order by email limit 1;
  select id into v from vagas where status = 'ativo' order by titulo limit 1;
  for i in 1..7 loop
    insert into candidaturas (remetente_id, vaga_id, dados_pessoais, hash_identidade, status, recebido_em, selecionado_em)
    values (r, case when i = 7 then null else v end,
            jsonb_build_object('nome', nomes[i], 'telefone', '55619770000' || i, 'telefone_e164', '55619770000' || i,
                               'email', 'edge' || i || '@mail.test', 'cidade', 'Gama/DF'),
            encode(extensions.digest(nomes[i], 'sha256'), 'hex'), 'recebido', now() - interval '20 days',
            case when i in (1,2,4) then now() - interval '10 days' end);
  end loop;
  update candidaturas set status = 'reprovado' where dados_pessoais ->> 'nome' = 'Edge Reprovado';
  update candidaturas set status = 'contratado' where dados_pessoais ->> 'nome' = 'Edge Contratado';
  update candidaturas set status = 'descartado', motivo_descarte = 'Perfil incompatível' where dados_pessoais ->> 'nome' = 'Edge Descartado';
  update candidaturas set status = 'nao_compareceu' where dados_pessoais ->> 'nome' = 'Edge NaoCompareceu';
  update candidaturas set status_registro = 'inativo', inativado_em = now() - interval '30 days' where dados_pessoais ->> 'nome' = 'Edge Inativo';
  update candidaturas set status_registro = 'inativo', inativado_em = now() - interval '200 days' where dados_pessoais ->> 'nome' = 'Edge Expurgado';
end $$;
insert into curriculos (candidatura_id, storage_path, nome_arquivo, tipo_mime, origem, texto_extraido)
select id, '2026/09/edge' || row_number() over () || '.pdf', 'edge.pdf', 'application/pdf', 'anexo_pdf', 'Currículo edge'
  from candidaturas where dados_pessoais ->> 'nome' in ('Edge Reprovado','Edge Contratado','Edge Descartado','Edge NaoCompareceu','Edge Inativo','Edge Expurgado','Edge SemVaga');
-- expurgado: usa a função de produção (zera dados pessoais e apaga texto/arquivo do currículo)
select public.fn_excluir_dados_candidato(id, 'ensaio') from candidaturas where dados_pessoais ->> 'nome' = 'Edge Expurgado';

select 'candidaturas' as tabela, count(*) from candidaturas union all
select 'curriculos', count(*) from curriculos union all
select 'avaliacoes', count(*) from avaliacoes union all
select 'entrevistas', count(*) from entrevistas union all
select 'hashes repetidos', count(*) from (select hash_identidade from candidaturas where hash_identidade is not null group by 1 having count(*) > 1) x;
