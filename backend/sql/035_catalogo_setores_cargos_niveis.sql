-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · CATÁLOGO REAL DE SETORES, CARGOS E NÍVEIS
--
--  Rodar depois da 034. Pode rodar de novo sem problema.
--
--  A 031 semeou setores, funções e níveis com o que a IA tinha sugerido e alguns palpites: não era o catálogo da empresa
--  (a IA chegou a qualificar alguém em "Serviços Gerais / Recepcionista / Sênior"). Este arquivo troca pelo modelo real
--  ("BRMODELO - SETORES E CARGOS", 2026-09-24):
--
--    • Setor  → Cargo (função): cada cargo pertence ao setor em que aparece no modelo (o mesmo nome pode existir em vários)
--    • Nível  → Jovem Aprendiz, Trainee, Júnior, Pleno, Sênior. "Estágio" virou Trainee e "Liderança" deixou de ser nível:
--               Gerente, Encarregado e Supervisor são CARGOS
--    • Jovem Aprendiz e Trainee só existem para: Logística/Auxiliar, DP/Auxiliar, RH/Auxiliar e Loja/Repositor
--      (coluna funcoes_setor.aceita_iniciante). Nos demais cargos os níveis são Júnior, Pleno e Sênior.
--
--  Este arquivo NÃO desativa setores antigos nem reordena: setores que não estão no modelo (Vendas, Serviços Gerais,
--  Contabilidade, Outros) e as vagas que apontam para eles são ajuste de DADOS de produção, feito à parte
--  (catalogo_producao_2026-09.sql), porque depende de decisão do RH.
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  1) Níveis: novo vocabulário
-- ───────────────────────────────────────────────────────────────────────
-- candidatos.nivel_sugerido e analises_ia.nivel_sugerido também aceitam só os códigos novos (a sugestão é copiada para lá).
do $$
declare r record;
begin
  for r in select c.conrelid::regclass as tabela, c.conname
             from pg_constraint c
            where c.contype = 'c'
              and c.conrelid in ('public.candidatos'::regclass, 'public.analises_ia'::regclass)
              and pg_get_constraintdef(c.oid) like '%nivel_sugerido%' loop
    execute format('alter table %s drop constraint %I', r.tabela, r.conname);
  end loop;
end $$;

-- Dados que usavam os códigos antigos: "estagio" vira "trainee"; "lideranca" deixa de ser nível (fica sem nível)
update public.candidatos set nivel_sugerido = case nivel_sugerido when 'estagio' then 'trainee' end
 where nivel_sugerido in ('estagio', 'lideranca');
update public.analises_ia set nivel_sugerido = case nivel_sugerido when 'estagio' then 'trainee' end
 where nivel_sugerido in ('estagio', 'lideranca');

alter table public.niveis_funcao drop constraint if exists niveis_funcao_codigo_check;
delete from public.niveis_funcao where codigo = 'lideranca';               -- currículos e vagas que o usavam ficam sem nível (FK set null)
update public.niveis_funcao set codigo = 'trainee' where codigo = 'estagio';   -- o código muda em cascata nos currículos e nas vagas

insert into public.niveis_funcao (codigo, nome, descricao, ordem) values
  ('jovem_aprendiz', 'Jovem Aprendiz', 'Primeiro emprego: sem experiência profissional registrada. Só para os cargos marcados como "aceita jovem_aprendiz e trainee".', 1),
  ('trainee',        'Trainee',        'Início de carreira: estudante, estagiário ou até cerca de 1 ano de experiência. Só para os cargos marcados como "aceita jovem_aprendiz e trainee".', 2),
  ('junior',         'Júnior',         'Até cerca de 2 anos de experiência no cargo. Nos cargos que não aceitam jovem_aprendiz nem trainee, inclui quem está começando.', 3),
  ('pleno',          'Pleno',          'De 2 a 5 anos de experiência no cargo, com autonomia.', 4),
  ('senior',         'Sênior',         'Mais de 5 anos de experiência no cargo ou referência técnica.', 5)
on conflict (codigo) do update
  set nome = excluded.nome, descricao = excluded.descricao, ordem = excluded.ordem;

alter table public.niveis_funcao
  add constraint niveis_funcao_codigo_check check (codigo in ('jovem_aprendiz', 'trainee', 'junior', 'pleno', 'senior'));
alter table public.candidatos
  add constraint candidatos_nivel_sugerido_check
  check (nivel_sugerido is null or nivel_sugerido in ('jovem_aprendiz', 'trainee', 'junior', 'pleno', 'senior'));
alter table public.analises_ia
  add constraint analises_ia_nivel_sugerido_check
  check (nivel_sugerido is null or nivel_sugerido in ('jovem_aprendiz', 'trainee', 'junior', 'pleno', 'senior'));

-- ───────────────────────────────────────────────────────────────────────
--  2) Cargos que aceitam Jovem Aprendiz e Trainee
-- ───────────────────────────────────────────────────────────────────────
alter table public.funcoes_setor add column if not exists aceita_iniciante boolean not null default false;
comment on column public.funcoes_setor.aceita_iniciante is
  'true = o cargo aceita os níveis jovem_aprendiz e trainee. false = só júnior, pleno e sênior. A IA e o formulário da vaga respeitam.';

-- ───────────────────────────────────────────────────────────────────────
--  3) Setores do modelo que ainda não existem (os que já existem ficam como estão)
-- ───────────────────────────────────────────────────────────────────────
insert into public.setores (nome, slug, icone, cor, ordem)
select v.nome, v.slug, v.icone, v.cor, v.ordem
  from (values
    ('Loja',          'loja',          'ti-building-store',   '#059669', 101),
    ('Logística',     'logistica',     'ti-truck',            '#3B82F6', 102),
    ('Auditoria',     'auditoria',     'ti-clipboard-check',  '#B45309', 103),
    ('DP',            'dp',            'ti-users',            '#7C3AED', 104),
    ('RH',            'rh',            'ti-heart-handshake',  '#DB2777', 105),
    ('TI',            'ti',            'ti-device-desktop',   '#0EA5E9', 106),
    ('Financeiro',    'financeiro',    'ti-coin',             '#16A34A', 107),
    ('Cadastro',      'cadastro',      'ti-file-text',        '#0D9488', 108),
    ('Recepção',      'recepcao',      'ti-bell',             '#F59E0B', 109),
    ('Controladoria', 'controladoria', 'ti-chart-bar',        '#4F46E5', 110),
    ('CR',            'cr',            'ti-cash',             '#EA580C', 111),
    ('Marketing',     'marketing',     'ti-speakerphone',     '#C026D3', 112),
    ('Compras',       'compras',       'ti-shopping-cart',    '#0891B2', 113)
  ) as v(nome, slug, icone, cor, ordem)
 where not exists (select 1 from public.setores s where s.nome = v.nome);

-- ───────────────────────────────────────────────────────────────────────
--  4) Cargos de cada setor (substituem os da 031)
-- ───────────────────────────────────────────────────────────────────────
-- Nenhuma tabela aponta para funcoes_setor (currículos e vagas guardam o nome): apagar tudo e recarregar é seguro.
delete from public.funcoes_setor;

insert into public.funcoes_setor (setor_id, nome, aceita_iniciante)
select s.id, f.cargo, f.iniciante
  from (values
    ('Loja',          'Repositor',                   true),
    ('Loja',          'Vendedor',                    false),
    ('Loja',          'Cadastro',                    false),
    ('Loja',          'Fiscal de Loja',              false),
    ('Loja',          'Operador de Caixa',           false),
    ('Loja',          'Consultor de Vendas',         false),
    ('Loja',          'Auxiliar de Serviços Gerais', false),
    ('Loja',          'Gerente de Vendas',           false),
    ('Loja',          'Encarregado de Vendas',       false),
    ('Loja',          'Encarregado de Loja',         false),
    ('Loja',          'Gerente de Loja',             false),
    ('Logística',     'Auxiliar',                    true),
    ('Logística',     'Auxiliar de Serviços Gerais', false),
    ('Logística',     'Encarregado',                 false),
    ('Logística',     'Supervisor',                  false),
    ('Logística',     'Gerente',                     false),
    ('Auditoria',     'Auxiliar',                    false),
    ('Auditoria',     'Auditor',                     false),
    ('Auditoria',     'Gerente',                     false),
    ('DP',            'Auxiliar',                    true),
    ('DP',            'Assistente',                  false),
    ('DP',            'Analista',                    false),
    ('DP',            'Gerente',                     false),
    ('RH',            'Auxiliar',                    true),
    ('RH',            'Assistente',                  false),
    ('RH',            'Analista',                    false),
    ('RH',            'Gerente',                     false),
    ('TI',            'Suporte',                     false),
    ('TI',            'Gerente',                     false),
    ('Financeiro',    'Auxiliar',                    false),
    ('Financeiro',    'Assistente',                  false),
    ('Financeiro',    'Tesoureira',                  false),
    ('Cadastro',      'Auxiliar',                    false),
    ('Cadastro',      'Assistente',                  false),
    ('Cadastro',      'Fiscal',                      false),
    ('Cadastro',      'Price',                       false),
    ('Recepção',      'Recepcionista',               false),
    ('Controladoria', 'Cobrança',                    false),
    ('Controladoria', 'Controller',                  false),
    ('CR',            'Vendedor',                    false),
    ('CR',            'Encarregado',                 false),
    ('CR',            'Gerente',                     false),
    ('Marketing',     'Auxiliar',                    false),
    ('Marketing',     'Assistente',                  false),
    ('Marketing',     'Analista',                    false),
    ('Marketing',     'Gerente',                     false),
    ('Compras',       'Comprador',                   false),
    ('Compras',       'Auxiliar',                    false),
    ('Compras',       'Assistente',                  false),
    ('Compras',       'Encarregado',                 false),
    ('Compras',       'Gerente',                     false)
  ) as f(setor, cargo, iniciante)
  join public.setores s on s.nome = f.setor;

-- ───────────────────────────────────────────────────────────────────────
--  5) Vaga: além de a função ser do setor, Jovem Aprendiz e Trainee só nos cargos que os aceitam
--     (é a função da 033, com a regra do nível; passa a valer também ao trocar o nível)
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_vaga_valida_funcao()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  v_aceita boolean;
  v_onde   text;
begin
  if new.funcao_setor is not null then
    select f.aceita_iniciante into v_aceita
      from public.funcoes_setor f
     where f.setor_id = new.setor_id and f.nome = new.funcao_setor and f.ativo;
    if not found then
      raise exception 'A função "%" não existe no setor escolhido. Escolha uma função da lista.', new.funcao_setor;
    end if;
    if new.nivel_funcao in ('jovem_aprendiz', 'trainee') and not v_aceita then
      select string_agg(s.nome || ' / ' || f.nome, ', ' order by s.nome, f.nome) into v_onde
        from public.funcoes_setor f join public.setores s on s.id = f.setor_id
       where f.aceita_iniciante and f.ativo;
      raise exception 'Jovem Aprendiz e Trainee só existem para: %. Para "%" escolha Júnior, Pleno ou Sênior.', v_onde, new.funcao_setor;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_vaga_valida_funcao on public.vagas;
create trigger trg_vaga_valida_funcao
  before insert or update of setor_id, funcao_setor, nivel_funcao on public.vagas
  for each row execute function public.fn_vaga_valida_funcao();
