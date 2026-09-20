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
         where p.proname = 'fn_cria_perfil_usuario' and p.pronamespace = 'public'::regnamespace);
