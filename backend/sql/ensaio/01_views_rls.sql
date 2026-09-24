-- Views, políticas e privilégios de produção (réplica para ensaio; ver 00_base.sql).
\set ON_ERROR_STOP on

create view public.vw_agenda_entrevistas as
 select e.id, e.candidatura_id, e.data_hora, e.duracao_minutos, e.local, e.entrevistador, e.resultado, e.observacoes,
    (e.data_hora + ((e.duracao_minutos || ' minutes'))::interval) as data_hora_fim,
    (e.data_hora)::date as data,
    (c.dados_pessoais ->> 'nome') as candidato_nome,
    (c.dados_pessoais ->> 'telefone') as candidato_telefone,
    (c.dados_pessoais ->> 'telefone_e164') as candidato_telefone_e164,
    v.titulo as vaga_titulo, s.nome as setor_nome, s.cor as setor_cor, cur.storage_path as curriculo_path
   from entrevistas e
     join candidaturas c on c.id = e.candidatura_id
     left join vagas v on v.id = c.vaga_id
     left join setores s on s.id = v.setor_id
     left join curriculos cur on cur.candidatura_id = c.id
  where c.status_registro = 'ativo';

create view public.vw_candidatos as
 select c.id, (c.dados_pessoais ->> 'nome') as nome, (c.dados_pessoais ->> 'telefone') as telefone,
    (c.dados_pessoais ->> 'telefone_e164') as telefone_e164, (c.dados_pessoais ->> 'email') as email,
    c.status, c.selecionado_em, u.nome as selecionado_por_nome, v.titulo as vaga_titulo,
    s.nome as setor_nome, s.cor as setor_cor, a.nota,
    e.id as entrevista_id, e.data_hora as entrevista_data_hora, e.resultado as entrevista_resultado, e.local as entrevista_local
   from candidaturas c
     left join vagas v on v.id = c.vaga_id
     left join setores s on s.id = v.setor_id
     left join usuarios u on u.id = c.selecionado_por
     left join lateral (select av.nota from avaliacoes av where av.candidatura_id = c.id order by av.sequencia desc limit 1) a on true
     left join lateral (select en.id, en.candidatura_id, en.data_hora, en.duracao_minutos, en.local, en.entrevistador, en.resultado,
            en.observacoes, en.resultado_registrado_em, en.resultado_registrado_por, en.mensagem_enviada, en.whatsapp_aberto_em,
            en.entrevista_anterior_id, en.agendado_por, en.created_at, en.updated_at
           from entrevistas en where en.candidatura_id = c.id order by en.data_hora desc limit 1) e on true
  where c.status_registro = 'ativo' and c.status = any (array['selecionado','entrevista_agendada','entrevista_realizada',
        'aprovado','reprovado','nao_compareceu','contratado']::status_candidatura[]);

create view public.vw_dashboard_metricas as
 select (select count(*) from candidaturas where status_registro = 'ativo' and recebido_em >= (current_date - 7)) as curriculos_7d,
    (select count(*) from candidaturas where status_registro = 'ativo' and recebido_em >= date_trunc('month', current_date::timestamptz)) as curriculos_mes,
    (select count(*) from candidaturas where status_registro = 'ativo' and selecionado_em >= (current_date - 7)) as selecionados_7d,
    (select count(*) from candidaturas where status_registro = 'ativo' and selecionado_em >= date_trunc('month', current_date::timestamptz)) as selecionados_mes,
    (select count(*) from entrevistas e join candidaturas c on c.id = e.candidatura_id where c.status_registro = 'ativo' and e.data_hora >= (current_date - 7)) as entrevistas_7d,
    (select count(*) from entrevistas e join candidaturas c on c.id = e.candidatura_id where c.status_registro = 'ativo' and e.data_hora >= date_trunc('month', current_date::timestamptz)) as entrevistas_mes,
    (select count(*) from vagas where status = 'ativo') as vagas_abertas,
    (select count(*) from excecoes where status = 'pendente') as excecoes_pendentes,
    (select count(*) from candidaturas where status_registro = 'ativo' and status = 'avaliado') as aguardando_triagem;

create view public.vw_reincidentes as
 select r.id, r.email, r.total_envios, r.primeiro_envio_em, r.ultimo_envio_em, r.bloqueado, r.bloqueado_em, r.motivo_bloqueio,
    u.nome as bloqueado_por_nome,
    (select count(*) from candidaturas c where c.remetente_id = r.id and c.status = 'descartado') as vezes_descartado,
    (select max(c.recebido_em) from candidaturas c where c.remetente_id = r.id) as ultima_candidatura_em
   from remetentes r left join usuarios u on u.id = r.bloqueado_por
  where r.total_envios > 1;

create view public.vw_vagas_resumo as
 select v.id, v.titulo, v.descricao, v.quantidade, v.versao_criterios, v.data_abertura, v.status,
    (current_date - v.data_abertura) as dias_aberta,
    s.id as setor_id, s.nome as setor_nome, s.cor as setor_cor, s.icone as setor_icone,
    coalesce(m.total_curriculos, 0::bigint) as total_curriculos,
    coalesce(m.total_selecionados, 0::bigint) as total_selecionados,
    coalesce(m.total_entrevistas, 0::bigint) as total_entrevistas,
    coalesce(m.total_contratados, 0::bigint) as total_contratados,
    (select string_agg(emp.sigla, ' · ' order by emp.sigla) from vaga_empresas ve join empresas emp on emp.id = ve.empresa_id where ve.vaga_id = v.id) as empresas
   from vagas v join setores s on s.id = v.setor_id
     left join lateral (select count(*) as total_curriculos,
            count(*) filter (where c.status = 'selecionado' or c.selecionado_em is not null) as total_selecionados,
            count(*) filter (where c.status = any (array['entrevista_agendada','entrevista_realizada']::status_candidatura[])) as total_entrevistas,
            count(*) filter (where c.status = 'contratado') as total_contratados
           from candidaturas c where c.vaga_id = v.id and c.status_registro = 'ativo') m on true
  where v.status = 'ativo';

-- vw_triagem = 017_view_sexo_candidato.sql do repositório; filtrar_triagem/norm_busca = filtros_avancados.sql
\i /repo/backend/sql/017_view_sexo_candidato.sql
\i /repo/backend/sql/filtros_avancados.sql

-- RLS como em 016 (padrão _rh_select/_rh_insert/_rh_update/_admin_delete)
do $$
declare t text;
begin
  foreach t in array array['avaliacoes','candidaturas','curriculos','entrevistas','excecoes','remetentes','vagas','setores','empresas','uploads_manuais'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (fn_usuario_ativo())', t || '_rh_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (fn_usuario_ativo())', t || '_rh_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (fn_usuario_ativo()) with check (fn_usuario_ativo())', t || '_rh_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (fn_usuario_admin())', t || '_admin_delete', t);
  end loop;
end $$;
alter table public.configuracoes enable row level security;
create policy config_leitura on public.configuracoes for select to authenticated using (fn_usuario_ativo());
create policy config_escrita_admin on public.configuracoes for update to authenticated using (fn_usuario_admin()) with check (fn_usuario_admin());
alter table public.logs_auditoria enable row level security;
create policy logs_somente_leitura on public.logs_auditoria for select to authenticated using (fn_usuario_ativo());
alter table public.usuarios enable row level security;
create policy usuarios_select on public.usuarios for select to authenticated using (true);
alter table public.requisitos enable row level security;
create policy requisitos_all on public.requisitos for all to authenticated using (fn_usuario_ativo()) with check (fn_usuario_ativo());
alter table public.vaga_empresas enable row level security;
create policy vaga_empresas_all on public.vaga_empresas for all to authenticated using (fn_usuario_ativo()) with check (fn_usuario_ativo());

-- privilégios como após a 015: anon sem nada; authenticated sem truncate/references/trigger
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on function public.fn_excluir_dados_candidato(uuid, text) from public, anon, authenticated;
revoke update on public.usuarios from authenticated;
grant update (ultimo_acesso) on public.usuarios to authenticated;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke truncate, references, trigger on tables from authenticated;

-- Configurações de produção relevantes
insert into public.configuracoes (chave, valor, descricao) values
 ('retencao_meses_ate_inativar', '2', 'Meses sem evento relevante até inativação automática (exclusão lógica).'),
 ('retencao_meses_ate_expurgar', '4', 'Meses inativo até expurgo dos dados pessoais (LGPD).'),
 ('reincidencia_dias_carencia', '30', 'Envios para a mesma vaga dentro deste prazo contam como reincidência.'),
 ('modelo_ia_avaliacao', '"claude-sonnet-5"', 'Modelo usado para avaliação qualitativa e geração de nota.'),
 ('modelo_ia_classificacao', '"claude-haiku-4-5-20251001"', 'Modelo usado para classificar se é currículo e identificar a vaga.'),
 ('faixa_ambigua_min', '""', 'Nota mínima da faixa que dispara segunda avaliação independente.'),
 ('faixa_ambigua_max', '""', 'Nota máxima da faixa que dispara segunda avaliação independente.');
