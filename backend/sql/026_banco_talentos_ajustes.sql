-- ════════════════════════════════════════════════════════════════════════
--  026 — Ajustes apontados pelos advisors do Supabase (segurança e desempenho)
--
--  Rodar depois da 025. Pode rodar de novo sem problema. Não muda dados nem comportamento:
--    1) norm_busca com search_path fixo   (advisor: function_search_path_mutable)
--    2) índices nas chaves estrangeiras   (advisor: unindexed_foreign_keys)
--    3) políticas duplicadas de "usuarios" fundidas em uma por ação
--                                          (advisor: multiple_permissive_policies)
--    4) arquivos_para_remover com política explícita de negação
--                                          (advisor: rls_enabled_no_policy)
--
--  O que NÃO foi mexido, de propósito:
--    • citext no schema public — 3 colunas (usuarios.email, remetentes.email, excecoes.email_remetente)
--      e 6 funções com search_path=public (inclusive fn_cria_perfil_usuario, o gatilho de cadastro) dependem
--      dele. Mover a extensão pode quebrar o login por causa de um aviso sem risco prático.
--    • Proteção contra senhas vazadas — é configuração do Auth (Painel → Authentication), não do banco.
-- ════════════════════════════════════════════════════════════════════════

-- 1) A função só usa funções nativas (lower, translate, coalesce, sempre visíveis pelo pg_catalog);
--    fixar o search_path fecha o aviso sem mudar o resultado. As colunas geradas que a usam não são recalculadas.
alter function public.norm_busca(text) set search_path = '';

-- 2) Índices nas colunas que apontam para outras tabelas. Sem eles, apagar ou atualizar a linha "pai"
--    varre a tabela "filha" inteira. Parciais onde a coluna quase sempre é nula.
create index if not exists idx_analises_curriculo          on public.analises_ia (curriculo_id)            where curriculo_id is not null;
create index if not exists idx_candidatos_analise_atual    on public.candidatos (analise_atual_id)         where analise_atual_id is not null;
create index if not exists idx_candidaturas_atribuido_por  on public.candidaturas (atribuido_por)          where atribuido_por is not null;
create index if not exists idx_curriculos_candidatura      on public.curriculos (candidatura_id)           where candidatura_id is not null;
create index if not exists idx_curriculos_remetente        on public.curriculos (remetente_id)             where remetente_id is not null;
create index if not exists idx_excecoes_reprocessar_por    on public.excecoes (reprocessar_solicitado_por) where reprocessar_solicitado_por is not null;
create index if not exists idx_sanit_ciclos_gerada_por     on public.sanitizacao_ciclos (gerada_por)       where gerada_por is not null;
create index if not exists idx_sugestoes_decidido_por      on public.sanitizacao_sugestoes (decidido_por)  where decidido_por is not null;
create index if not exists idx_uploads_vaga                on public.uploads_manuais (vaga_id)             where vaga_id is not null;
create index if not exists idx_uploads_candidatura         on public.uploads_manuais (candidatura_gerada_id) where candidatura_gerada_id is not null;
create index if not exists idx_uploads_candidato           on public.uploads_manuais (candidato_gerado_id) where candidato_gerado_id is not null;
create index if not exists idx_uploads_enviado_por         on public.uploads_manuais (enviado_por)         where enviado_por is not null;

-- 3) "usuarios" tinha duas políticas permissivas para SELECT e duas para UPDATE (a própria linha e "sou
--    administrador"). O Postgres avalia todas para cada linha; uma só com OR devolve exatamente o mesmo
--    resultado. O auth.uid() e a função entram em subselect para serem avaliados uma vez por consulta.
--    Só roda onde as políticas antigas existem (no ensaio local a tabela tem uma política simplificada).
do $$
begin
  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'usuarios' and policyname = 'usuarios_self_select')
     and exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'usuarios' and policyname = 'usuarios_admin_select') then

    drop policy usuarios_self_select  on public.usuarios;
    drop policy usuarios_admin_select on public.usuarios;
    drop policy if exists usuarios_select on public.usuarios;
    create policy usuarios_select on public.usuarios for select to authenticated
      using (id = (select auth.uid()) or (select public.fn_usuario_admin()));

    drop policy if exists usuarios_self_update  on public.usuarios;
    drop policy if exists usuarios_admin_update on public.usuarios;
    drop policy if exists usuarios_update on public.usuarios;
    create policy usuarios_update on public.usuarios for update to authenticated
      using      (id = (select auth.uid()) or (select public.fn_usuario_admin()))
      with check (id = (select auth.uid()) or (select public.fn_usuario_admin()));
  end if;
end $$;

-- 4) arquivos_para_remover só é usada pelo backend (service_role, que ignora a RLS). O acesso já estava revogado
--    de anon e authenticated; a política de negação só deixa a intenção escrita (e a RLS sem política é o que o
--    advisor aponta). Não muda nada na prática.
drop policy if exists arquivos_para_remover_so_backend on public.arquivos_para_remover;
create policy arquivos_para_remover_so_backend on public.arquivos_para_remover
  for all to anon, authenticated using (false) with check (false);
