-- Verificação de segurança (só leitura). Rode no SQL Editor do Supabase.
-- Antes da migração 015 todas as linhas dão "true"; depois dela, todas devem dar "false".
select 'usuário logado consegue editar o PRÓPRIO perfil' as brecha,
       has_column_privilege('authenticated','public.usuarios','perfil','UPDATE') as aberta
union all select 'usuário logado consegue editar o PRÓPRIO ativo',
       has_column_privilege('authenticated','public.usuarios','ativo','UPDATE')
union all select 'usuário logado executa fn_excluir_dados_candidato (expurgo LGPD)',
       has_function_privilege('authenticated','public.fn_excluir_dados_candidato(uuid,text)','EXECUTE')
union all select 'anônimo executa trg_entrevista_unica_ativa',
       has_function_privilege('anon','public.trg_entrevista_unica_ativa()','EXECUTE')
union all select 'anônimo tem SELECT em candidaturas (RLS é a única barreira)',
       has_table_privilege('anon','public.candidaturas','SELECT')
union all select 'anônimo tem TRUNCATE em candidaturas',
       has_table_privilege('anon','public.candidaturas','TRUNCATE')
union all select 'novo usuário nasce ativo (default)',
       (select pg_get_functiondef(p.oid) not like '%false%' from pg_proc p
         where p.proname = 'fn_cria_perfil_usuario' and p.pronamespace = 'public'::regnamespace)
union all select 'gatilho de cadastro confia em user_metadata->perfil',
       (select pg_get_functiondef(p.oid) like '%raw_user_meta_data ->> ''perfil''%' from pg_proc p
         where p.proname = 'fn_cria_perfil_usuario' and p.pronamespace = 'public'::regnamespace)
-- ── Banco de Talentos (020 a 025) — todas as linhas abaixo devem dar "false" ──
union all select 'usuário logado escreve DIRETO em candidatos (deve passar só pelas funções)',
       has_table_privilege('authenticated','public.candidatos','INSERT')
    or has_table_privilege('authenticated','public.candidatos','UPDATE')
    or has_table_privilege('authenticated','public.candidatos','DELETE')
union all select 'usuário logado escreve DIRETO em analises_ia',
       has_table_privilege('authenticated','public.analises_ia','INSERT')
    or has_table_privilege('authenticated','public.analises_ia','UPDATE')
    or has_table_privilege('authenticated','public.analises_ia','DELETE')
union all select 'usuário logado escreve DIRETO nas sugestões/ciclos de sanitização',
       has_table_privilege('authenticated','public.sanitizacao_sugestoes','INSERT')
    or has_table_privilege('authenticated','public.sanitizacao_sugestoes','UPDATE')
    or has_table_privilege('authenticated','public.sanitizacao_sugestoes','DELETE')
    or has_table_privilege('authenticated','public.sanitizacao_ciclos','INSERT')
    or has_table_privilege('authenticated','public.sanitizacao_ciclos','UPDATE')
union all select 'usuário logado lê a fila de arquivos a apagar (arquivos_para_remover)',
       has_table_privilege('authenticated','public.arquivos_para_remover','SELECT')
union all select 'anônimo tem SELECT em candidatos',
       has_table_privilege('anon','public.candidatos','SELECT')
union all select 'anônimo executa a seleção de currículos da vaga (selecionar_curriculos_vaga)',
       has_function_privilege('anon','public.selecionar_curriculos_vaga(uuid,integer,integer,text,numeric)','EXECUTE')
union all select 'anônimo executa o filtro de currículos da vaga (fn_curriculos_da_vaga)',
       has_function_privilege('anon','public.fn_curriculos_da_vaga(uuid)','EXECUTE')
union all select 'anônimo executa atribuir_candidato_vaga',
       has_function_privilege('anon','public.atribuir_candidato_vaga(uuid,uuid,text)','EXECUTE')
union all select 'usuário logado executa a atribuição INTERNA (que aceita qualquer usuário como autor)',
       has_function_privilege('authenticated','public.fn_atribuir_candidato_vaga(uuid,uuid,uuid,text)','EXECUTE')
union all select 'usuário logado executa o expurgo direto (fn_expurgar_candidato)',
       has_function_privilege('authenticated','public.fn_expurgar_candidato(uuid,text)','EXECUTE')
union all select 'usuário logado executa fn_sanitizacao_aplicar (contorna a checagem de administrador)',
       has_function_privilege('authenticated','public.fn_sanitizacao_aplicar(uuid,text,text,integer,uuid,boolean)','EXECUTE')
union all select 'anônimo executa gerar sugestões de sanitização',
       has_function_privilege('anon','public.fn_gerar_sugestoes_sanitizacao(text,boolean)','EXECUTE')
union all select 'alguma view do Banco de Talentos SEM security_invoker (ignoraria a RLS)',
       exists (select 1 from pg_class c
                where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
                  and c.relname in ('vw_banco_talentos','vw_banco_opcoes','vw_candidaturas','vw_candidatos','vw_agenda_entrevistas',
                                    'vw_vagas_resumo','vw_dashboard_metricas','vw_reincidentes','vw_sanitizacao_sugestoes')
                  and not coalesce('security_invoker=true' = any (c.reloptions), false))
union all select 'vw_triagem ainda existe (removida na 024: não usava security_invoker)',
       to_regclass('public.vw_triagem') is not null;
