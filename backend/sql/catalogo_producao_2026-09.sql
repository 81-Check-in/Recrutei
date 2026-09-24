-- ════════════════════════════════════════════════════════════════════════
--  AJUSTE DE DADOS DE PRODUÇÃO — catálogo real de setores, cargos e níveis (2026-09-24)
--
--  NÃO É MIGRAÇÃO (a estrutura e o catálogo estão na 035). Isto acerta os DADOS de produção que dependiam do catálogo antigo.
--  Foi executado uma vez em produção; fica aqui como registro. Pode rodar de novo sem efeito.
--
--   1) Setores: ordem do modelo (Loja, Logística, Auditoria, DP, RH, TI, Financeiro, Cadastro, Recepção, Controladoria, CR,
--      Marketing, Compras) e DESATIVA os que não existem no modelo (Vendas, Serviços Gerais, Contabilidade, Outros). Desativado
--      não some: as vagas que apontam para eles continuam, marcadas "setor desativado" no formulário, para o RH escolher outro.
--   2) As vagas que o RH já tinha preenchido com função/nível do catálogo antigo passam para o equivalente do modelo, ou ficam sem
--      o campo que não tem equivalente (o RH escolhe de novo).
--   3) Currículo cuja qualificação não existe no modelo (ex.: "Serviços Gerais / Recepcionista") é zerado e o candidato volta para a
--      fila de reanálise (python main.py --reanalisar) com "revisão manual" até lá.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Setores
update public.setores s set ordem = x.ordem, ativo = true
  from (values ('Loja', 1), ('Logística', 2), ('Auditoria', 3), ('DP', 4), ('RH', 5), ('TI', 6), ('Financeiro', 7), ('Cadastro', 8),
               ('Recepção', 9), ('Controladoria', 10), ('CR', 11), ('Marketing', 12), ('Compras', 13)) x(nome, ordem)
 where s.nome = x.nome;
update public.setores s set ativo = false, ordem = x.ordem
  from (values ('Vendas', 91), ('Serviços Gerais', 92), ('Contabilidade', 93), ('Outros', 94)) x(nome, ordem)
 where s.nome = x.nome;

-- 2) Vagas com função/nível do catálogo antigo
update public.vagas set funcao_setor = 'Auxiliar'
 where titulo = 'Logística' and funcao_setor = 'Auxiliar de Logística';                                -- só mudou o nome do cargo; o nível segue
update public.vagas set funcao_setor = 'Assistente', nivel_funcao = null
 where titulo = 'Financeiro' and funcao_setor = 'Assistente Administrativo';                            -- "estágio" não existe em Financeiro/Assistente
update public.vagas set funcao_setor = 'Fiscal de Loja'
 where titulo = 'Fiscal de loja' and funcao_setor = 'Atendente';                                        -- o cargo agora existe e é o do título da vaga
update public.vagas set funcao_setor = null
 where titulo = 'Contabilidade' and funcao_setor = 'Auxiliar Contábil';                                 -- o setor Contabilidade saiu do modelo

-- 3) Currículos com setor/função fora do modelo
with invalidos as (
  select cu.id as curriculo_id, cu.candidato_id
    from public.curriculos cu
   where cu.setor_adequado is not null
     and not exists (select 1 from public.funcoes_setor f join public.setores s on s.id = f.setor_id
                      where s.nome = cu.setor_adequado and f.nome = cu.funcao_setor)
), limpa as (
  update public.curriculos set setor_adequado = null, funcao_setor = null, nivel_funcao = null
   where id in (select curriculo_id from invalidos)
  returning candidato_id
)
update public.candidatos
   set area_sugerida = null, cargo_sugerido = null, nivel_sugerido = null,
       revisao_manual = true, reanalise_solicitada_em = now()
 where id in (select candidato_id from invalidos);
