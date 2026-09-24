-- Prepara o banco do ensaio para o teste de zerar_banco_talentos.sql: acrescenta o que a produção tem e a
-- massa sintética não tem (marcador do e-mail, remetente bloqueado, upload manual e exceção ligados a uma
-- candidatura — as chaves estrangeiras "NO ACTION" que travariam um DELETE simples —, ciclo de sanitização)
-- e tira um retrato do que precisa continuar igual depois. Roda antes de zerar; 13_zerar_conferir.sql depois.
\set ON_ERROR_STOP on
begin;

insert into public.configuracoes (chave, valor, descricao) values
  ('imap_ultimo_uid',  '195303',     'Controle interno: último UID da caixa já analisado pelo pipeline. Não editar.'),
  ('imap_uidvalidity', '1663763787', 'Controle interno: UIDVALIDITY da caixa de e-mail. Não editar.')
on conflict (chave) do update set valor = excluded.valor;

update public.remetentes set bloqueado = true, bloqueado_em = now(), motivo_bloqueio = 'teste do ensaio'
 where email = 'remetente1@mail.test';

do $$
declare
  v_vaga uuid; v_usuario uuid; v_candidatura uuid; v_candidato uuid;
begin
  select id into v_vaga from public.vagas where status = 'ativo' limit 1;
  select id into v_usuario from public.usuarios where perfil = 'administrador' limit 1;
  select id, candidato_id into v_candidatura, v_candidato from public.candidaturas where candidato_id is not null limit 1;

  insert into public.uploads_manuais (vaga_id, nome_arquivo, tipo_mime, storage_path, status,
                                      candidatura_gerada_id, candidato_gerado_id, enviado_por)
  values (v_vaga, 'cv.pdf', 'application/pdf', '2026/09/upload-teste.pdf', 'processado',
          v_candidatura, v_candidato, v_usuario);

  insert into public.excecoes (email_remetente, tipo, storage_path, status, candidatura_gerada_id, email_corpo, texto_extraido)
  values ('x@mail.test', 'nao_e_curriculo', '2026/09/excecao-teste.pdf', 'revisado', v_candidatura, 'corpo', 'texto');
end $$;

select public.fn_gerar_sugestoes_sanitizacao('manual', true) is not null as ciclo_de_sanitizacao_criado;

create table public.ensaio_zerar_antes as
select
  (select count(*) from public.candidatos)                                   as candidatos,
  (select count(*) from public.candidaturas)                                 as candidaturas,
  (select count(*) from public.sanitizacao_sugestoes)                        as sugestoes,
  (select count(*) from public.vagas)                                        as vagas,
  (select count(*) from public.usuarios)                                     as usuarios,
  (select count(*) from public.remetentes where bloqueado)                   as bloqueados,
  (select count(*) from public.logs_auditoria)                               as logs,
  (select string_agg(chave || '=' || valor::text, ',' order by chave)
     from public.configuracoes where chave in ('imap_ultimo_uid', 'imap_uidvalidity')) as marcador,
  (select count(distinct p) from (
     select storage_path p from public.curriculos
     union all select storage_path from public.uploads_manuais
     union all select storage_path from public.excecoes) x where p is not null)     as arquivos;

commit;
