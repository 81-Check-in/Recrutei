-- 016_delete_somente_admin  (aplicada em 2026-09-20, depois de ensaio em transação desfeita: 22 verificações ok)
--
-- Hoje as políticas "<tabela>_rh_all" dão SELECT/INSERT/UPDATE/DELETE a qualquer usuário ativo. O app nunca apaga
-- essas linhas (usa status/exclusão lógica; a exclusão de entrevista passa pela função excluir_entrevista, que
-- é SECURITY DEFINER e não depende desta política). Um DELETE direto pela API contorna as regras dessa função e
-- permite a um gerente_rh apagar candidaturas, currículos e avaliações. Aqui o DELETE passa a ser só do administrador.
--
-- Ficam de fora, de propósito: requisitos e vaga_empresas (o app apaga e recria ao salvar uma vaga).

do $$
declare t text;
begin
  foreach t in array array['avaliacoes','candidaturas','curriculos','entrevistas','excecoes',
                           'remetentes','vagas','setores','empresas'] loop
    execute format('drop policy %I on public.%I', t || '_rh_all', t);
    execute format('create policy %I on public.%I for select to authenticated using (fn_usuario_ativo())',
                   t || '_rh_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (fn_usuario_ativo())',
                   t || '_rh_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (fn_usuario_ativo()) with check (fn_usuario_ativo())',
                   t || '_rh_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (fn_usuario_admin())',
                   t || '_admin_delete', t);
  end loop;
end $$;

-- Arquivos dos currículos: só o administrador apaga (o pipeline usa service_role e ignora o RLS)
drop policy storage_curriculos_delete on storage.objects;
create policy storage_curriculos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'curriculos' and fn_usuario_admin());

-- Para reverter, recriar "<tabela>_rh_all" (for all, using/with check fn_usuario_ativo()) e apagar as quatro novas.
