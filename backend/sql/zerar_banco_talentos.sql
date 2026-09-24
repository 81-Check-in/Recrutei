-- ════════════════════════════════════════════════════════════════════════
--  ZERAR O BANCO DE TALENTOS — recomeço limpo
--
--  NÃO É MIGRAÇÃO. Rode uma vez, de propósito, e só depois de ler isto.
--  Irreversível: só o backup do Supabase recupera o que for apagado aqui.
--
--  APAGA
--    candidatos, currículos e análises da IA · candidaturas (com as avaliações e as entrevistas delas) ·
--    exceções · uploads manuais · remetentes que não estão bloqueados · ciclos e sugestões de sanitização
--
--  MANTÉM
--    vagas (com requisitos e empresas) · usuários · configurações — inclusive o MARCADOR DO E-MAIL
--    (imap_ultimo_uid / imap_uidvalidity): se ele fosse apagado, a execução diária releria a caixa desde o
--    começo · remetentes BLOQUEADOS · auditoria (logs_auditoria, que ganha o registro desta operação) ·
--    histórico de execuções do pipeline
--
--  ARQUIVOS NO STORAGE
--    O banco não apaga arquivo do Storage. Os caminhos entram na fila arquivos_para_remover e o backend
--    remove na próxima execução (python main.py --manutencao, ou a execução diária).
--
--  DEPOIS DE ZERAR (nesta ordem)
--    1. python main.py --manutencao                                        remove os arquivos antigos do Storage
--    2. python main.py --reler-caixa --desde AAAA-MM-DD --ate-uid <marcador>
--       recarrega no modelo novo o que o pipeline já tinha lido. Use como <marcador> o valor de
--       imap_ultimo_uid (Configurações do banco) e como data a do currículo mais antigo. Veja backend/README.md.
--
--  COMO USAR
--    Troque NAO por SIM na linha marcada abaixo e rode o arquivo inteiro. Se qualquer verificação falhar,
--    NADA é apagado (uma transação só).
-- ════════════════════════════════════════════════════════════════════════
begin;

-- ► TRAVA DE SEGURANÇA — troque NAO por SIM para valer
select set_config('recrutei.zerar_confirmado', 'NAO', true);

do $$
begin
  if current_setting('recrutei.zerar_confirmado', true) is distinct from 'SIM' then
    raise exception 'Trava de segurança: troque NAO por SIM na linha marcada no início do script para zerar de verdade.';
  end if;
end $$;

create function pg_temp.exige(ok boolean, msg text) returns void
language plpgsql as $$
begin
  if ok is not true then
    raise exception 'Verificação falhou, nada foi apagado: %', msg;
  end if;
end $$;

-- Retrato de antes: vai para a auditoria e serve para conferir o que deve continuar igual
create temp table _zerar_antes on commit drop as
select
  jsonb_build_object(
    'candidatos',            (select count(*) from public.candidatos),
    'candidaturas',          (select count(*) from public.candidaturas),
    'curriculos',            (select count(*) from public.curriculos),
    'analises_ia',           (select count(*) from public.analises_ia),
    'avaliacoes',            (select count(*) from public.avaliacoes),
    'entrevistas',           (select count(*) from public.entrevistas),
    'excecoes',              (select count(*) from public.excecoes),
    'uploads_manuais',       (select count(*) from public.uploads_manuais),
    'remetentes_apagados',   (select count(*) from public.remetentes where not bloqueado),
    'sanitizacao_sugestoes', (select count(*) from public.sanitizacao_sugestoes),
    'sanitizacao_ciclos',    (select count(*) from public.sanitizacao_ciclos)
  )                                                                             as contagens,
  (select count(*) from public.vagas)                                           as vagas,
  (select count(*) from public.usuarios)                                        as usuarios,
  (select count(*) from public.logs_auditoria)                                  as logs,
  (select count(*) from public.remetentes where bloqueado)                      as bloqueados,
  (select string_agg(chave || '=' || valor::text, ',' order by chave)
     from public.configuracoes where chave in ('imap_ultimo_uid', 'imap_uidvalidity')) as marcador,
  array(select distinct caminho from (
          select storage_path as caminho from public.curriculos
          union all select storage_path from public.uploads_manuais
          union all select storage_path from public.excecoes
        ) x where caminho is not null)                                          as caminhos;

-- 1) Arquivos do Storage → fila de remoção (antes de apagar as linhas que guardam os caminhos)
insert into public.arquivos_para_remover (storage_path)
select unnest(caminhos) from _zerar_antes
on conflict (storage_path) do nothing;

-- 2) Apagar, das pontas para o centro. As candidaturas levam junto avaliações e entrevistas (cascata);
--    os candidatos levam currículos e análises.
delete from public.uploads_manuais;
delete from public.candidaturas;
delete from public.candidatos;
delete from public.excecoes;
delete from public.sanitizacao_sugestoes;
delete from public.sanitizacao_ciclos;
delete from public.remetentes where not bloqueado;

-- 3) Verificações: o que devia sumir sumiu; o que devia ficar, ficou
do $$
declare
  a record;
begin
  select * into a from _zerar_antes;

  perform pg_temp.exige((select count(*) from public.candidatos)             = 0, 'ainda há candidatos');
  perform pg_temp.exige((select count(*) from public.candidaturas)           = 0, 'ainda há candidaturas');
  perform pg_temp.exige((select count(*) from public.curriculos)             = 0, 'ainda há currículos');
  perform pg_temp.exige((select count(*) from public.analises_ia)            = 0, 'ainda há análises');
  perform pg_temp.exige((select count(*) from public.avaliacoes)             = 0, 'ainda há avaliações');
  perform pg_temp.exige((select count(*) from public.entrevistas)            = 0, 'ainda há entrevistas');
  perform pg_temp.exige((select count(*) from public.excecoes)               = 0, 'ainda há exceções');
  perform pg_temp.exige((select count(*) from public.uploads_manuais)        = 0, 'ainda há uploads manuais');
  perform pg_temp.exige((select count(*) from public.sanitizacao_sugestoes)  = 0, 'ainda há sugestões de sanitização');
  perform pg_temp.exige((select count(*) from public.remetentes where not bloqueado) = 0, 'ainda há remetentes livres');

  perform pg_temp.exige((select count(*) from public.vagas)                  = a.vagas,      'o número de vagas mudou');
  perform pg_temp.exige((select count(*) from public.usuarios)               = a.usuarios,   'o número de usuários mudou');
  perform pg_temp.exige((select count(*) from public.remetentes where bloqueado) = a.bloqueados, 'remetentes bloqueados mudaram');
  perform pg_temp.exige((select count(*) from public.logs_auditoria)         >= a.logs,      'a auditoria perdeu registros');
  perform pg_temp.exige(not exists (select 1 from unnest(a.caminhos) p
                                     where not exists (select 1 from public.arquivos_para_remover r where r.storage_path = p)),
                        'algum arquivo do Storage ficou fora da fila de remoção');
  perform pg_temp.exige(coalesce((select string_agg(chave || '=' || valor::text, ',' order by chave)
                                    from public.configuracoes where chave in ('imap_ultimo_uid', 'imap_uidvalidity')), '')
                        = coalesce(a.marcador, ''), 'o marcador do e-mail mudou');
end $$;

-- 4) Auditoria: quem, quando e quanto (auth.uid() é nulo quando roda pelo editor SQL: fica "sistema")
select public.fn_registra_auditoria(
  'exclusao_manual_lgpd', 'sistema', gen_random_uuid(),
  (select contagens from _zerar_antes), null,
  'Banco de Talentos zerado (recomeço limpo). Arquivos do Storage enfileirados para remoção.');

do $$
declare
  a record;
begin
  select * into a from _zerar_antes;
  perform pg_temp.exige((select count(*) from public.logs_auditoria) > a.logs, 'a auditoria não registrou a operação');
  raise notice 'Apagado: %', a.contagens;
  raise notice 'Arquivos do Storage enfileirados para remoção: % (na fila agora: %)',
    coalesce(array_length(a.caminhos, 1), 0), (select count(*) from public.arquivos_para_remover where removido_em is null);
  raise notice 'Mantido: % vagas, % usuários, % remetentes bloqueados, marcador do e-mail %', a.vagas, a.usuarios, a.bloqueados, a.marcador;
end $$;

drop function pg_temp.exige(boolean, text);

commit;
