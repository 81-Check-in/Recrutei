-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · QUALIFICAÇÃO DO CURRÍCULO (setor, função e nível)
--
--  Rodar depois da 030 (só depende de "setores" e de fn_usuario_ativo). Pode rodar de novo sem problema.
--
--  A IA qualifica cada currículo sem olhar vaga nenhuma e grava, NO PRÓPRIO CURRÍCULO, o que ele indica:
--    • setor_adequado  — o setor em que a experiência mais se encaixa   (valor da tabela "setores")
--    • funcao_setor    — a função dentro desse setor                     (valor da tabela "funcoes_setor")
--    • nivel_funcao    — o nível para essa função                        (código da tabela "niveis_funcao")
--  Os três são vocabulário controlado: a IA só pode escolher o que está nessas tabelas.
--
--  O pipeline copia os mesmos valores para a análise e para o candidato (area_sugerida / cargo_sugerido /
--  nivel_sugerido), que é o que o painel do Banco de Talentos lê hoje. Nada do painel muda.
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  1) Níveis
-- ───────────────────────────────────────────────────────────────────────
-- Os cinco códigos são os mesmos de analises_ia.nivel_sugerido e candidatos.nivel_sugerido (a sugestão é copiada
-- para lá). Por isso o código é fixo: dá para renomear, reescrever o critério ou desativar um nível, mas um nível
-- novo exige migração (as duas colunas acima também têm de aceitá-lo).
create table if not exists public.niveis_funcao (
  codigo    text primary key check (codigo in ('estagio', 'junior', 'pleno', 'senior', 'lideranca')),
  nome      text not null check (btrim(nome) <> ''),
  descricao text,                                   -- o critério que a IA recebe junto com o nível
  ordem     smallint not null,
  ativo     boolean not null default true
);
comment on table public.niveis_funcao is
  'Níveis que a IA pode atribuir a um currículo (nivel_funcao). O critério em "descricao" vai junto no pedido à IA.';

-- Só semeia com a tabela vazia: a 035 troca estes cinco níveis pelos do modelo real (Jovem Aprendiz, Trainee, Júnior, Pleno,
-- Sênior), e reaplicar esta migração depois dela não pode trazer "estagio" e "lideranca" de volta.
insert into public.niveis_funcao (codigo, nome, descricao, ordem)
select v.* from (values
  ('estagio',   'Estágio',   'Estudante ou sem experiência profissional.',                       1),
  ('junior',    'Júnior',    'Até cerca de 2 anos de experiência.',                              2),
  ('pleno',     'Pleno',     'De 2 a 5 anos de experiência, com autonomia.',                     3),
  ('senior',    'Sênior',    'Mais de 5 anos de experiência ou referência técnica.',             4),
  ('lideranca', 'Liderança', 'Já liderou equipe.',                                               5)
) as v(codigo, nome, descricao, ordem)
 where not exists (select 1 from public.niveis_funcao);

-- ───────────────────────────────────────────────────────────────────────
--  2) Funções de cada setor
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.funcoes_setor (
  id         uuid primary key default gen_random_uuid(),
  setor_id   uuid not null references public.setores(id) on delete cascade,
  nome       text not null check (btrim(nome) <> ''),
  ativo      boolean not null default true,
  created_at timestamptz not null default now(),
  constraint uq_funcao_setor unique (setor_id, nome)      -- também serve de índice da chave estrangeira
);
comment on table public.funcoes_setor is
  'Funções que a IA pode atribuir a um currículo (funcao_setor), por setor. Edite à vontade: desative uma função em vez de apagá-la se currículos já a usam.';

-- Carga inicial: os cargos que a IA já tinha sugerido nos candidatos (2026-09-24), sem repetição, no masculino e
-- sem os genéricos ("Auxiliar", "Assistente"). Os marcados com (+) não apareceram nos currículos lidos: são funções
-- comuns do setor, incluídas para a IA ter o que escolher onde ainda não havia nenhuma sugestão. Revise a lista.
insert into public.funcoes_setor (setor_id, nome)
select s.id, f.nome
  from (values
    ('Loja',            'Operador de Caixa'),
    ('Loja',            'Atendente'),
    ('Loja',            'Vendedor'),
    ('Loja',            'Operador de Loja'),
    ('Loja',            'Balconista'),
    ('Loja',            'Repositor'),                       -- (+)
    ('Loja',            'Supervisor'),
    ('Vendas',          'Vendedor'),
    ('Vendas',          'Vendedor Externo'),
    ('Vendas',          'Consultor de Vendas'),
    ('Vendas',          'Operador de Telemarketing'),
    ('Vendas',          'Supervisor'),
    ('Financeiro',      'Auxiliar Administrativo'),
    ('Financeiro',      'Assistente Administrativo'),
    ('Financeiro',      'Auxiliar Financeiro'),
    ('Financeiro',      'Assistente Financeiro'),           -- (+)
    ('Contabilidade',   'Auxiliar Contábil'),               -- (+)
    ('Contabilidade',   'Assistente Contábil'),             -- (+)
    ('Contabilidade',   'Analista Contábil'),               -- (+)
    ('Logística',       'Auxiliar de Logística'),           -- (+)
    ('Logística',       'Auxiliar de Estoque'),             -- (+)
    ('Logística',       'Conferente'),                      -- (+)
    ('Logística',       'Operador de Empilhadeira'),
    ('Logística',       'Motorista'),                       -- (+)
    ('Serviços Gerais', 'Auxiliar de Serviços Gerais'),
    ('Serviços Gerais', 'Auxiliar de Limpeza'),
    ('Serviços Gerais', 'Auxiliar de Cozinha'),
    ('Serviços Gerais', 'Auxiliar de Manutenção'),
    ('Serviços Gerais', 'Agente de Portaria'),
    ('Serviços Gerais', 'Vigilante'),
    ('Serviços Gerais', 'Fiscal de Prevenção de Perdas'),
    ('Serviços Gerais', 'Recepcionista'),
    ('Serviços Gerais', 'Auxiliar Administrativo'),
    ('TI',              'Analista de Suporte'),
    ('TI',              'Técnico de Suporte'),              -- (+)
    ('TI',              'Desenvolvedor'),                   -- (+)
    ('Outros',          'Auxiliar Administrativo'),
    ('Outros',          'Assistente Administrativo'),
    ('Outros',          'Assistente de DP'),
    ('Outros',          'Atendente SAC'),
    ('Outros',          'Atendente'),
    ('Outros',          'Recepcionista')
  ) as f(setor, nome)
  join public.setores s on s.nome = f.setor
on conflict (setor_id, nome) do nothing;

-- ───────────────────────────────────────────────────────────────────────
--  3) O resultado da qualificação, no currículo
-- ───────────────────────────────────────────────────────────────────────
-- Texto para setor e função (o nome como está nas tabelas, do mesmo jeito que candidatos.area_sugerida guarda o
-- setor): renomear um setor não trava, e o painel lê como texto. Nível é o código da tabela.
alter table public.curriculos
  add column if not exists setor_adequado text,
  add column if not exists funcao_setor   text,
  add column if not exists nivel_funcao   text references public.niveis_funcao(codigo) on update cascade on delete set null;

comment on column public.curriculos.setor_adequado is 'Setor em que a experiência do currículo mais se encaixa, segundo a IA (nome em "setores").';
comment on column public.curriculos.funcao_setor   is 'Função, dentro desse setor, em que a experiência mais se encaixa, segundo a IA (nome em "funcoes_setor").';
comment on column public.curriculos.nivel_funcao   is 'Nível identificado pela experiência para essa função, segundo a IA (código em "niveis_funcao").';

create index if not exists idx_curriculos_nivel_funcao on public.curriculos (nivel_funcao) where nivel_funcao is not null;

-- O expurgo (fn_expurgar_candidato) apaga a análise da IA e esvazia o texto do currículo. A classificação que a IA
-- gravou no currículo é a mesma análise: sai junto, sem precisar reescrever aquela função.
create or replace function public.fn_curriculo_limpa_qualificacao()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.setor_adequado := null;
  new.funcao_setor   := null;
  new.nivel_funcao   := null;
  return new;
end $$;

drop trigger if exists trg_curriculo_limpa_qualificacao on public.curriculos;
create trigger trg_curriculo_limpa_qualificacao
  before update of texto_extraido on public.curriculos
  for each row
  when (new.texto_extraido is null and old.texto_extraido is not null)
  execute function public.fn_curriculo_limpa_qualificacao();

-- ───────────────────────────────────────────────────────────────────────
--  4) Segurança: leitura para usuário ativo; escrita só pelo backend (service_role) ou pelo SQL Editor
-- ───────────────────────────────────────────────────────────────────────
alter table public.niveis_funcao enable row level security;
alter table public.funcoes_setor enable row level security;

drop policy if exists niveis_funcao_leitura on public.niveis_funcao;
create policy niveis_funcao_leitura on public.niveis_funcao for select to authenticated using (public.fn_usuario_ativo());
drop policy if exists funcoes_setor_leitura on public.funcoes_setor;
create policy funcoes_setor_leitura on public.funcoes_setor for select to authenticated using (public.fn_usuario_ativo());

revoke all on public.niveis_funcao, public.funcoes_setor from anon, authenticated;
grant select on public.niveis_funcao, public.funcoes_setor to authenticated;
grant all on public.niveis_funcao, public.funcoes_setor to service_role;

-- ───────────────────────────────────────────────────────────────────────
--  5) Sanitização: currículo sem confiança registrada não é "dado incompleto"
-- ───────────────────────────────────────────────────────────────────────
-- A qualificação do currículo (prompt atual) não devolve mais um percentual de confiança: candidatos.ia_confianca fica
-- nulo. Antes, nulo valia 0 e todo candidato novo cairia no critério "Currículo sem classificação confiável". Agora
-- a confiança só conta quando existe; o critério continua pegando quem não tem análise, está em revisão manual ou
-- ficou sem setor/função/nível. É a função da 023, idêntica, exceto pela linha da confiança (f_dados).
create or replace function public.fn_sanitizacao_avaliar(p_params jsonb)
returns table (
  candidato_id        uuid,
  motivos             text[],
  motivo_texto        text,
  pontos              integer,
  prioridade          text,
  ultima_movimentacao timestamptz
)
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_mov     int     := (p_params ->> 'meses_sem_movimentacao')::int;
  v_reprov  int     := (p_params ->> 'reprovacoes_max')::int;
  v_ader    int     := (p_params ->> 'aderencia_min')::int;
  v_conf    int     := (p_params ->> 'confianca_min')::int;
  v_dup     boolean := (p_params ->> 'detectar_duplicidade')::boolean;
  v_ret     int     := (p_params ->> 'retencao_maxima_meses')::int;
  w         jsonb   := p_params -> 'pesos';
begin
  return query
  with base as (
    select c.*
      from public.candidatos c
     where c.status_banco in ('ativo', 'inativo')
       and not c.retencao_permanente
       and (c.sanitizacao_adiada_ate is null or c.sanitizacao_adiada_ate <= now())
       and not exists (select 1 from public.sanitizacao_sugestoes s
                        where s.candidato_id = c.id and s.status = 'pendente')
  ),
  hist as (
    select b.id,
           count(distinct ca.vaga_id) filter (where ca.status = 'reprovado')             as vagas_reprovado,
           coalesce(bool_or(ca.status in ('aprovado', 'contratado')), false)              as tem_aprovacao
      from base b left join public.candidaturas ca on ca.candidato_id = b.id
     group by b.id
  ),
  notas as (
    select b.id, max(av.nota) as nota_max
      from base b
      join public.candidaturas ca on ca.candidato_id = b.id
      join public.avaliacoes av on av.candidatura_id = ca.id
     group by b.id
  ),
  sinais as (
    select b.id,
           b.ultima_movimentacao                                                          as ult_mov,
           (b.ultima_movimentacao < now() - make_interval(months => v_mov))               as f_mov,
           (coalesce(h.vagas_reprovado, 0) >= v_reprov and not h.tem_aprovacao)           as f_reprov,
           (n.nota_max is not null and n.nota_max < v_ader)                               as f_ader,
           -- análise ainda pendente não conta como "dado incompleto"
           (b.reanalise_solicitada_em is null and (
                b.analise_atual_id is null or b.revisao_manual
             or b.area_sugerida is null or b.cargo_sugerido is null or b.nivel_sugerido is null
             or (b.ia_confianca is not null and b.ia_confianca < v_conf)))                as f_dados,
           -- só o cadastro MAIS ANTIGO do par é sugerido (o mais recente fica). Um EXISTS por critério, cada
           -- um com o seu índice (hash, telefone, e-mail): um único EXISTS com OR obrigaria a varrer a tabela.
           -- Telefone/e-mail iguais só valem com nome parecido (família ou agência dividem contato).
           (v_dup and (
              (b.hash_identidade is not null and exists (
                 select 1 from public.candidatos d
                  where d.hash_identidade = b.hash_identidade and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)))
              or (b.telefone_e164 is not null and exists (
                 select 1 from public.candidatos d
                  where d.telefone_e164 = b.telefone_e164 and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)
                    and extensions.similarity(d.nome_norm, b.nome_norm) >= 0.5))
              or (b.email is not null and exists (
                 select 1 from public.candidatos d
                  where lower(d.email) = lower(b.email) and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)
                    and extensions.similarity(d.nome_norm, b.nome_norm) >= 0.5))))          as f_dup,
           (coalesce(b.consentimento_em, b.data_entrada) < now() - make_interval(months => v_ret)) as f_prazo,
           coalesce(h.vagas_reprovado, 0)                                                 as vagas_reprovado,
           n.nota_max,
           b.consentimento_em is null                                                     as sem_consentimento,
           b.data_entrada
      from base b
      join hist h on h.id = b.id
      left join notas n on n.id = b.id
  ),
  pont as (
    select s.*,
           ( (s.f_mov    ::int * (w ->> 'sem_movimentacao')::int)
           + (s.f_reprov ::int * (w ->> 'reprovacoes')::int)
           + (s.f_ader   ::int * (w ->> 'baixa_aderencia')::int)
           + (s.f_dados  ::int * (w ->> 'dados_incompletos')::int)
           + (s.f_dup    ::int * (w ->> 'duplicidade')::int)
           + (s.f_prazo  ::int * (w ->> 'prazo_retencao')::int) ) as total
      from sinais s
  )
  select p.id,
         array_remove(array[
           case when p.f_mov    then 'sem_movimentacao'   end,
           case when p.f_reprov then 'reprovacoes'        end,
           case when p.f_ader   then 'baixa_aderencia'    end,
           case when p.f_dados  then 'dados_incompletos'  end,
           case when p.f_dup    then 'duplicidade'        end,
           case when p.f_prazo  then 'prazo_retencao'     end], null),
         array_to_string(array_remove(array[
           case when p.f_mov then format('Sem movimentação há %s meses (limite: %s)',
                  (extract(year from age(now(), p.ult_mov)) * 12 + extract(month from age(now(), p.ult_mov)))::int, v_mov) end,
           case when p.f_reprov then format('Reprovado em %s vagas diferentes sem nenhuma aprovação', p.vagas_reprovado) end,
           case when p.f_ader then format('Melhor aderência da IA às vagas: %s%% (mínimo: %s%%)', p.nota_max, v_ader) end,
           case when p.f_dados then 'Currículo sem classificação confiável da IA (área, cargo ou nível)' end,
           case when p.f_dup then 'Possível cadastro duplicado (há outro mais recente do mesmo candidato)' end,
           case when p.f_prazo then format('No banco há mais de %s meses%s',
                  v_ret, case when p.sem_consentimento then ' sem consentimento registrado' else ' desde o último consentimento' end) end
         ], null), '; '),
         p.total,
         case when p.total >= (w ->> 'limite_alta')::int  then 'alta'
              when p.total >= (w ->> 'limite_media')::int then 'media'
              else 'baixa' end,
         p.ult_mov
    from pont p
   where p.f_mov or p.f_reprov or p.f_ader or p.f_dados or p.f_dup or p.f_prazo;
end $$;
