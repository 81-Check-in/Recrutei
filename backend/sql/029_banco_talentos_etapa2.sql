-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · ETAPA 2: palavras-chave da IA e ranking de candidatos por vaga
--
--  Rodar depois da 028 (e da 027, que cria o valor 'diferencial'). Pode rodar de novo sem problema.
--
--  Vagas → "Ver candidatos": mostra os candidatos do banco que mais combinam com a vaga. A combinação é feita por
--  PALAVRAS-CHAVE, sem chamar a IA de novo:
--    • a IA, ao analisar cada currículo, já devolve palavras-chave descritivas (cargos, ferramentas, habilidades,
--      segmentos, formação) — ficam em analises_ia.palavras_chave;
--    • da vaga saem os termos do título, da descrição e dos requisitos (Obrigatório pesa mais que Desejável, que pesa
--      mais que Diferencial; o "peso" de cada requisito multiplica);
--    • o candidato ganha os pontos dos termos da vaga que aparecem nas palavras-chave dele.
--  Portugues stemmed (contábeis ≈ contábil): a comparação é por radical, sem acento nem caixa.
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  1) Palavras-chave e texto de busca
-- ───────────────────────────────────────────────────────────────────────
alter table public.analises_ia
  add column if not exists palavras_chave text[] not null default '{}',
  add column if not exists busca_tsv      tsvector;
alter table public.candidatos
  add column if not exists palavras_chave text[] not null default '{}';

create index if not exists idx_analises_busca_tsv on public.analises_ia using gin (busca_tsv);

-- Texto sem acento e sem as palavras "de RH" que aparecem em toda vaga e não descrevem ninguém
-- ("experiência", "conhecimento", "desejável"…): elas casariam com todo mundo e não diferenciam.
create or replace function public.norm_termos(t text)
returns text
language sql immutable parallel safe
set search_path = ''
as $$
  select regexp_replace(
           public.norm_busca(t),
           '\m(experiencia|conhecimento|conhecimentos|desejavel|obrigatorio|diferencial|nivel|minimo|minima|anos|ano|meses|mes|'
           'superior|medio|fundamental|completo|incompleto|completa|incompleta|cursando|concluido|concluida|formacao|area|atuacao|'
           'vivencia|capacidade|habilidade|habilidades|boa|bom|otima|otimo|preferencia|preferencialmente|funcao|cargo|vaga|empresa|'
           'trabalho|profissional|profissionais|noções|nocoes|basico|basica|avancado|avancada|intermediario|intermediaria)\M',
           ' ', 'g')
$$;

-- O texto de busca da análise = palavras-chave + cargo + área + pontos positivos, em radicais (português)
create or replace function public.fn_analise_busca_tsv()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.busca_tsv := to_tsvector('portuguese'::regconfig,
    public.norm_termos(concat_ws(' ', array_to_string(new.palavras_chave, ' '), new.cargo_sugerido, new.area_sugerida,
                                 array_to_string(new.pontos_positivos, ' '))));
  return new;
end $$;

drop trigger if exists trg_analise_busca_tsv on public.analises_ia;
create trigger trg_analise_busca_tsv
  before insert or update of palavras_chave, cargo_sugerido, area_sugerida, pontos_positivos on public.analises_ia
  for each row execute function public.fn_analise_busca_tsv();

-- A sugestão atual (agora com as palavras-chave) continua sendo copiada para o candidato
create or replace function public.fn_analise_sincroniza_candidato()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
begin
  update public.candidatos c
     set analise_atual_id        = new.id,
         area_sugerida           = new.area_sugerida,
         cargo_sugerido          = new.cargo_sugerido,
         nivel_sugerido          = new.nivel_sugerido,
         ia_confianca            = new.confianca,
         revisao_manual          = new.revisao_manual,
         palavras_chave          = new.palavras_chave,
         reanalise_solicitada_em = null,
         ultima_atualizacao      = now()
   where c.id = new.candidato_id
     and not exists (select 1 from public.analises_ia a
                      where a.candidato_id = new.candidato_id and a.sequencia > new.sequencia);
  return new;
end $$;

-- Análises que já existem (feitas antes desta etapa) ganham o texto de busca com o que têm; as palavras-chave
-- só chegam quando a IA reanalisar o currículo (python main.py --reanalisar)
update public.analises_ia set palavras_chave = palavras_chave where busca_tsv is null;

-- ───────────────────────────────────────────────────────────────────────
--  2) Termos da vaga (radicais com peso)
-- ───────────────────────────────────────────────────────────────────────
-- Título pesa 3; descrição, 1; cada requisito: (Obrigatório 3 · Desejável 2 · Diferencial 1) × o peso dele.
-- O perfil comportamental fica de fora: traços como "organizado" quase nunca aparecem em palavras-chave técnicas.
create or replace function public.fn_termos_vaga(p_vaga_id uuid)
returns table (termo text, peso numeric)
language sql stable
set search_path = public
as $$
  with fontes as (
    select v.titulo as texto, 3::numeric as p from public.vagas v where v.id = p_vaga_id
    union all
    select v.descricao, 1::numeric from public.vagas v where v.id = p_vaga_id
    union all
    select r.descricao,
           (case r.tipo when 'obrigatorio' then 3 when 'desejavel' then 2 else 1 end)::numeric * greatest(coalesce(r.peso, 1), 1)
      from public.requisitos r where r.vaga_id = p_vaga_id
  )
  select x.t, max(x.p)
    from (select unnest(tsvector_to_array(to_tsvector('portuguese'::regconfig, public.norm_termos(f.texto)))) as t, f.p
            from fontes f where f.texto is not null) x
   where length(x.t) >= 3
   group by x.t
$$;

-- ───────────────────────────────────────────────────────────────────────
--  3) Ranking: os candidatos disponíveis que mais combinam com a vaga
--     aderencia = % do peso dos termos da vaga que aparecem no perfil do candidato (0–100)
--     termos_casados = as palavras-chave do candidato que casaram (para o RH ver por quê)
--     total = quantos candidatos combinam ao todo (igual em todas as linhas), para a paginação da tela
--  Fora do ranking: quem não está disponível, quem está na lista negra e quem já tem candidatura ABERTA nesta vaga ou
--  foi reprovado/descartado NELA (só volta em vaga nova). É SECURITY INVOKER: vale a RLS de quem chama.
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.ranking_candidatos_vaga(
  p_vaga_id uuid, p_limite integer default 50, p_deslocamento integer default 0)
returns table (candidato_id uuid, aderencia integer, termos_casados text[], total integer)
language sql stable
set search_path = public
as $$
  with t as (select termo, peso from public.fn_termos_vaga(p_vaga_id)),
  total as (select coalesce(sum(peso), 0) as soma from t),
  q as (select to_tsquery('simple', string_agg(quote_literal(termo), ' | ')) as consulta from t),
  pre as (
    select c.id, a.busca_tsv, a.palavras_chave, c.ultima_movimentacao
      from public.candidatos c
      join public.analises_ia a on a.id = c.analise_atual_id
     cross join q
     where q.consulta is not null
       and a.busca_tsv @@ q.consulta
       and c.status_banco = 'ativo'
       and not c.lista_negra
       and not exists (select 1 from public.candidaturas ca
                        where ca.candidato_id = c.id and ca.vaga_id = p_vaga_id
                          and (ca.encerrada_em is null or ca.status in ('reprovado', 'descartado')))
  ),
  pontos as (
    select p.*, m.soma_casada, m.radicais
      from pre p
      cross join lateral (
        select coalesce(sum(t.peso), 0) as soma_casada, coalesce(array_agg(t.termo), '{}'::text[]) as radicais
          from t where p.busca_tsv @@ quote_literal(t.termo)::tsquery
      ) m
  )
  select p.id,
         least(100, round(100 * p.soma_casada / nullif((select soma from total), 0)))::integer,
         array(select k from unnest(p.palavras_chave) k
                where tsvector_to_array(to_tsvector('portuguese'::regconfig, public.norm_termos(k))) && p.radicais
                limit 8),
         (count(*) over ())::integer          -- quantos combinam no total (a janela é calculada antes do limit)
    from pontos p
   order by 2 desc, p.ultima_movimentacao asc, p.id
   limit greatest(p_limite, 1) offset greatest(p_deslocamento, 0)
$$;

-- ───────────────────────────────────────────────────────────────────────
--  4) A view do banco informa as palavras-chave (coluna nova, sempre no fim)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.vw_banco_talentos with (security_invoker = true) as
select
  c.id,
  c.nome, c.nome_norm, c.sexo, c.data_nascimento, c.nascimento_ref,
  case when c.nascimento_ref is not null
       then extract(year from age(current_date, c.nascimento_ref))::int end            as idade,
  (c.data_nascimento is null and c.nascimento_ref is not null)                         as idade_estimada,
  c.cidade, c.cidade_norm, c.uf, c.telefone, c.telefone_e164, c.email,
  c.escolaridade, c.escolaridade_ord, c.anos_experiencia, c.cnh,
  c.status_banco, c.origem_entrada, c.data_entrada, c.ultima_atualizacao, c.ultima_movimentacao,
  c.ultimo_contato_em, c.retencao_permanente, c.consentimento_em, c.consentimento_origem,
  c.sanitizacao_adiada_ate,
  -- sugestão atual da IA
  c.area_sugerida, c.cargo_sugerido, c.nivel_sugerido, c.ia_confianca, c.revisao_manual,
  c.reanalise_solicitada_em,
  a.texto_resumo_ia                                                                    as resumo_ia,
  a.pontos_positivos, a.pontos_negativos, a.data_analise, a.versao_modelo_ia, a.motivo_revisao,
  -- currículo atual
  cur.id                                                                               as curriculo_id,
  cur.storage_path, cur.nome_arquivo, cur.origem                                       as curriculo_origem,
  cur.recebido_em                                                                      as curriculo_recebido_em,
  -- histórico de vagas
  coalesce(h.total_candidaturas, 0)                                                    as total_candidaturas,
  coalesce(h.total_reprovacoes, 0)                                                     as total_reprovacoes,
  ab.id                                                                                as candidatura_atual_id,
  ab.status                                                                            as candidatura_atual_status,
  ab.vaga_id                                                                           as vaga_atual_id,
  ab.vaga_titulo                                                                       as vaga_atual_titulo,
  exists (select 1 from public.sanitizacao_sugestoes s
           where s.candidato_id = c.id and s.status = 'pendente')                      as sanitizacao_pendente,
  -- lista negra (028)
  c.lista_negra, c.lista_negra_em, c.lista_negra_motivo,
  public.fn_nome_usuario(c.lista_negra_por)                                            as lista_negra_por_nome,
  -- palavras-chave da IA (029)
  c.palavras_chave
from public.candidatos c
left join public.analises_ia a on a.id = c.analise_atual_id
left join lateral (
  select cu.id, cu.storage_path, cu.nome_arquivo, cu.origem, cu.recebido_em
    from public.curriculos cu where cu.candidato_id = c.id and cu.atual limit 1
) cur on true
left join lateral (
  select count(*)                                    as total_candidaturas,
         count(*) filter (where ca.status = 'reprovado') as total_reprovacoes
    from public.candidaturas ca
   where ca.candidato_id = c.id and ca.origem <> 'triagem_legada'
) h on true
left join lateral (
  select ca.id, ca.status, ca.vaga_id, v.titulo as vaga_titulo
    from public.candidaturas ca left join public.vagas v on v.id = ca.vaga_id
   where ca.candidato_id = c.id and ca.encerrada_em is null limit 1
) ab on true
where c.status_banco <> 'expurgado';

-- ───────────────────────────────────────────────────────────────────────
--  Privilégios
-- ───────────────────────────────────────────────────────────────────────
revoke execute on function
  public.norm_termos(text),
  public.fn_analise_busca_tsv(),
  public.fn_termos_vaga(uuid),
  public.ranking_candidatos_vaga(uuid, integer, integer)
from public, anon, authenticated;
grant execute on function public.ranking_candidatos_vaga(uuid, integer, integer) to authenticated;
grant execute on function
  public.norm_termos(text), public.fn_termos_vaga(uuid), public.ranking_candidatos_vaga(uuid, integer, integer)
to service_role;
-- o ranking (invoker) chama fn_termos_vaga e norm_termos com a sessão do painel
grant execute on function public.fn_termos_vaga(uuid), public.norm_termos(text) to authenticated;
