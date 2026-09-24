-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · ETAPA 3: distância candidato × lojas e considerações da entrevista
--
--  Rodar depois da 029. Pode rodar de novo sem problema.
--
--  DISTÂNCIA — cada loja fica numa região do DF/entorno (CFS → Samambaia, CFC → Ceilândia…) e cada candidato tem a
--  região onde mora, identificada por (nesta ordem de confiança): correção manual do RH › IA › texto do currículo ›
--  cidade cadastrada. A distância é a de LINHA RETA entre os centros das duas regiões (tabela regioes_df), uma
--  ESTIMATIVA: serve para comparar candidatos e ordenar, não para traçar rota. As coordenadas são aproximadas
--  (±3 km) e editáveis: ajuste em regioes_df, ou dê latitude/longitude exatas a uma loja em empresas.
--
--  CONSIDERAÇÕES — anotações do RH sobre o candidato (ex.: depois da entrevista), presas ao CANDIDATO e não à
--  candidatura: se ele volta ao Banco de Talentos, as considerações continuam com ele. Só o expurgo as apaga.
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  1) Regiões
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.regioes_df (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null unique,
  uf         text not null default 'DF',
  latitude   numeric(9, 6) not null check (latitude  between -90  and 90),
  longitude  numeric(9, 6) not null check (longitude between -180 and 180),
  apelidos   text[] not null default '{}',                    -- outras grafias e bairros inequívocos ("sol nascente")
  aproximada boolean not null default true,
  nome_norm  text generated always as (public.norm_busca(nome)) stored
);
comment on table public.regioes_df is
  'Regiões do DF e do entorno com o centro aproximado (latitude/longitude): base da distância candidato × loja.';

alter table public.regioes_df enable row level security;
drop policy if exists regioes_df_leitura on public.regioes_df;
create policy regioes_df_leitura on public.regioes_df for select to authenticated using (public.fn_usuario_ativo());
revoke all on public.regioes_df from anon, authenticated;
grant select on public.regioes_df to authenticated;
grant all on public.regioes_df to service_role;

-- Centros aproximados (de memória, ±3 km): o suficiente para dizer "perto", "médio" ou "longe". Corrija à vontade.
insert into public.regioes_df (nome, uf, latitude, longitude, apelidos) values
  ('Plano Piloto',            'DF', -15.793900, -47.882800, array['plano piloto', 'eixo monumental']),
  ('Asa Norte',               'DF', -15.762000, -47.885000, array['sqn', 'w3 norte', 'l2 norte']),
  ('Asa Sul',                 'DF', -15.821000, -47.908000, array['sqs', 'w3 sul', 'l2 sul']),
  ('Sudoeste',                'DF', -15.799000, -47.924000, array['octogonal', 'sudoeste e octogonal']),
  ('Cruzeiro',                'DF', -15.790000, -47.938000, array[]::text[]),
  ('Lago Norte',              'DF', -15.735000, -47.862000, array[]::text[]),
  ('Lago Sul',                'DF', -15.842000, -47.863000, array[]::text[]),
  ('Varjão',                  'DF', -15.704000, -47.882000, array[]::text[]),
  ('Park Way',                'DF', -15.900000, -47.950000, array[]::text[]),
  ('SIA',                     'DF', -15.802000, -47.953000, array['setor de industria e abastecimento']),
  ('Estrutural',              'DF', -15.783000, -47.995000, array['scia', 'cidade estrutural', 'via estrutural']),
  ('Guará',                   'DF', -15.825000, -47.980000, array['guara i', 'guara ii', 'bernardo sayao']),
  ('Candangolândia',          'DF', -15.850000, -47.949000, array[]::text[]),
  ('Núcleo Bandeirante',      'DF', -15.872000, -47.968000, array['nucleo bandeirante']),
  ('Riacho Fundo',            'DF', -15.885000, -48.018000, array['riacho fundo i']),
  ('Riacho Fundo II',         'DF', -15.905000, -48.040000, array[]::text[]),
  ('Águas Claras',            'DF', -15.840000, -48.027000, array['aguas claras']),
  ('Vicente Pires',           'DF', -15.804000, -48.030000, array[]::text[]),
  ('Taguatinga',              'DF', -15.833000, -48.057000, array['taguatinga norte', 'taguatinga sul', 'pistao sul', 'pistao norte']),
  ('Ceilândia',               'DF', -15.819000, -48.108000, array['ceilandia norte', 'ceilandia sul', 'ceilandia centro', 'setor p sul', 'setor p norte']),
  ('Sol Nascente / Pôr do Sol','DF', -15.810000, -48.140000, array['sol nascente', 'por do sol']),
  ('Samambaia',               'DF', -15.876000, -48.082000, array['samambaia norte', 'samambaia sul']),
  ('Recanto das Emas',        'DF', -15.913000, -48.065000, array[]::text[]),
  ('Gama',                    'DF', -16.018000, -48.065000, array['gama norte', 'gama sul']),
  ('Ponte Alta',              'DF', -15.995000, -48.020000, array['ponte alta norte', 'ponte alta sul', 'ponte alta do gama']),
  ('Santa Maria',             'DF', -16.018000, -47.986000, array[]::text[]),
  ('São Sebastião',           'DF', -15.902000, -47.773000, array['sao sebastiao']),
  ('Jardim Botânico',         'DF', -15.868000, -47.796000, array['jardim botanico']),
  ('Paranoá',                 'DF', -15.773000, -47.777000, array['paranoa']),
  ('Itapoã',                  'DF', -15.747000, -47.772000, array['itapoa']),
  ('Planaltina',              'DF', -15.620000, -47.653000, array[]::text[]),
  ('Sobradinho',              'DF', -15.653000, -47.790000, array['sobradinho i']),
  ('Sobradinho II',           'DF', -15.635000, -47.829000, array[]::text[]),
  ('Fercal',                  'DF', -15.590000, -47.870000, array[]::text[]),
  ('Brazlândia',              'DF', -15.670000, -48.203000, array['brazlandia']),
  ('Valparaíso de Goiás',     'GO', -16.065000, -47.975000, array['valparaiso de goias', 'valparaiso']),
  ('Cidade Ocidental',        'GO', -16.079000, -47.926000, array[]::text[]),
  ('Novo Gama',               'GO', -16.058000, -48.040000, array[]::text[]),
  ('Luziânia',                'GO', -16.253000, -47.950000, array['luziania']),
  ('Santo Antônio do Descoberto','GO', -15.940000, -48.258000, array['santo antonio do descoberto']),
  ('Águas Lindas de Goiás',   'GO', -15.760000, -48.281000, array['aguas lindas de goias', 'aguas lindas']),
  ('Planaltina de Goiás',     'GO', -15.453000, -47.611000, array['planaltina de goias']),
  ('Formosa',                 'GO', -15.540000, -47.334000, array[]::text[]),
  ('Padre Bernardo',          'GO', -15.160000, -48.284000, array[]::text[]),
  ('Cristalina',              'GO', -16.769000, -47.614000, array[]::text[])
on conflict (nome) do nothing;

-- Só o que está no texto: "Brasília" sozinho NÃO aponta região (muita gente escreve Brasília para qualquer cidade do DF)

-- ───────────────────────────────────────────────────────────────────────
--  2) Lojas e candidatos ganham região
-- ───────────────────────────────────────────────────────────────────────
alter table public.empresas
  add column if not exists regiao_id uuid references public.regioes_df(id) on delete set null,
  add column if not exists latitude  numeric(9, 6),            -- opcional: ponto exato da loja (senão vale o centro da região)
  add column if not exists longitude numeric(9, 6);
create index if not exists idx_empresas_regiao on public.empresas (regiao_id) where regiao_id is not null;

alter table public.candidatos
  add column if not exists regiao_id     uuid references public.regioes_df(id) on delete set null,
  add column if not exists regiao_origem text check (regiao_origem in ('manual', 'ia', 'texto', 'cidade')),
  add column if not exists bairro        text;
create index if not exists idx_candidatos_regiao on public.candidatos (regiao_id) where regiao_id is not null;

-- Onde fica cada loja (lista informada pelo RH). Só grava onde a loja existe e ainda não tem região.
update public.empresas e set regiao_id = r.id
  from (values ('CFS', 'Samambaia'), ('CFR', 'Recanto das Emas'), ('CFVP', 'Vicente Pires'), ('CFC', 'Ceilândia'),
               ('CFW3', 'Asa Norte'), ('CFT', 'Taguatinga'), ('CFG', 'Gama'), ('CFJB', 'Jardim Botânico'),
               ('CFPA', 'Ponte Alta'), ('CFBS', 'Guará')) m(sigla, regiao)
  join public.regioes_df r on r.nome = m.regiao
 where upper(e.sigla) = m.sigla and e.regiao_id is null;

-- ───────────────────────────────────────────────────────────────────────
--  3) Achar a região a partir de texto (bairro, cidade)
-- ───────────────────────────────────────────────────────────────────────
-- Casa palavra inteira, sem acento nem caixa; entre várias, vale o nome mais comprido ("Novo Gama" antes de "Gama",
-- "Planaltina de Goiás" antes de "Planaltina"). Sem correspondência, devolve nulo.
create or replace function public.fn_regiao_por_texto(p_bairro text, p_cidade text)
returns uuid
language sql stable
set search_path = public
as $$
  with alvo as (select ' ' || public.norm_busca(concat_ws(' ', p_bairro, p_cidade)) || ' ' as t)
  select r.id
    from public.regioes_df r, alvo,
         lateral (select n from unnest(array[r.nome_norm] || array(select public.norm_busca(a) from unnest(r.apelidos) a)) n) x
   where btrim(alvo.t) <> ''
     and alvo.t ~ ('[^a-z0-9]' || regexp_replace(x.n, '[^a-z0-9 ]', '', 'g') || '[^a-z0-9]')
   order by length(x.n) desc, r.nome
   limit 1
$$;

-- Região automática por bairro/cidade. Não mexe no que foi decidido por RH ('manual'), IA ou texto do currículo.
create or replace function public.fn_candidato_regiao()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_id uuid;
begin
  if new.regiao_id is not null and new.regiao_origem in ('manual', 'ia', 'texto') then
    return new;
  end if;
  v_id := public.fn_regiao_por_texto(new.bairro, new.cidade);
  new.regiao_id     := v_id;
  new.regiao_origem := case when v_id is null then null else 'cidade' end;
  return new;
end $$;

drop trigger if exists trg_candidato_regiao on public.candidatos;
create trigger trg_candidato_regiao
  before insert or update of cidade, bairro, regiao_id, regiao_origem on public.candidatos
  for each row execute function public.fn_candidato_regiao();

-- Candidatos que já estão no banco: acha a região pela cidade (só onde ainda não há)
update public.candidatos set cidade = cidade where regiao_id is null and cidade is not null;

-- ───────────────────────────────────────────────────────────────────────
--  4) Distância
-- ───────────────────────────────────────────────────────────────────────
-- Linha reta entre dois pontos (fórmula de haversine), em km com uma casa decimal
create or replace function public.distancia_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
returns numeric
language sql immutable parallel safe
set search_path = ''
as $$
  select round((2 * 6371 * asin(sqrt(
           sin(radians(lat2 - lat1) / 2) ^ 2
           + cos(radians(lat1)) * cos(radians(lat2)) * sin(radians(lon2 - lon1) / 2) ^ 2)))::numeric, 1)
$$;

-- Onde ficam as lojas de uma vaga (ponto exato da loja, ou o centro da região dela). Loja sem local fica de fora.
create or replace function public.fn_lojas_da_vaga(p_vaga_id uuid)
returns table (sigla text, nome text, regiao text, lat numeric, lon numeric)
language sql stable
set search_path = public
as $$
  select e.sigla, e.nome, r.nome, coalesce(e.latitude, r.latitude), coalesce(e.longitude, r.longitude)
    from public.vaga_empresas ve
    join public.empresas e on e.id = ve.empresa_id
    left join public.regioes_df r on r.id = e.regiao_id
   where ve.vaga_id = p_vaga_id and coalesce(e.latitude, r.latitude) is not null
$$;

-- Para cada candidato: a região dele e a distância até cada loja da vaga (ordenadas), com a mais próxima em destaque
create or replace function public.distancias_para_vaga(p_vaga_id uuid, p_candidatos uuid[])
returns table (candidato_id uuid, regiao text, loja_mais_proxima text, km_mais_proxima numeric, lojas jsonb)
language sql stable
set search_path = public
as $$
  with lojas as (select * from public.fn_lojas_da_vaga(p_vaga_id)),
  cand as (
    select c.id, rc.nome as regiao, rc.latitude as lat, rc.longitude as lon
      from public.candidatos c left join public.regioes_df rc on rc.id = c.regiao_id
     where c.id = any (p_candidatos)
  ),
  d as (
    select c.id, l.sigla, l.regiao as regiao_loja, public.distancia_km(c.lat, c.lon, l.lat, l.lon) as km
      from cand c join lojas l on c.lat is not null
  )
  select c.id, c.regiao,
         (array_agg(d.sigla order by d.km, d.sigla))[1],
         min(d.km),
         coalesce(jsonb_agg(jsonb_build_object('sigla', d.sigla, 'regiao', d.regiao_loja, 'km', d.km) order by d.km, d.sigla)
                  filter (where d.sigla is not null), '[]'::jsonb)
    from cand c left join d on d.id = c.id
   group by c.id, c.regiao
$$;

-- ───────────────────────────────────────────────────────────────────────
--  5) Ranking por vaga, agora com a distância (substitui a função da 029)
--     p_ordem: 'aderencia' (padrão) ou 'distancia' (mais perto primeiro; empate pela aderência)
--     p_km_max: só quem mora até tantos km da loja mais próxima (candidato sem região fica de fora quando há limite)
-- ───────────────────────────────────────────────────────────────────────
drop function if exists public.ranking_candidatos_vaga(uuid, integer, integer);
create or replace function public.ranking_candidatos_vaga(
  p_vaga_id uuid, p_limite integer default 50, p_deslocamento integer default 0,
  p_ordem text default 'aderencia', p_km_max numeric default null)
returns table (candidato_id uuid, aderencia integer, termos_casados text[], total integer,
               km_mais_proxima numeric, loja_mais_proxima text)
language sql stable
set search_path = public
as $$
  with t as (select termo, peso from public.fn_termos_vaga(p_vaga_id)),
  total as (select coalesce(sum(peso), 0) as soma from t),
  q as (select to_tsquery('simple', string_agg(quote_literal(termo), ' | ')) as consulta from t),
  lojas as (select * from public.fn_lojas_da_vaga(p_vaga_id)),
  pre as (
    select c.id, a.busca_tsv, a.palavras_chave, c.ultima_movimentacao, rc.latitude as lat, rc.longitude as lon
      from public.candidatos c
      join public.analises_ia a on a.id = c.analise_atual_id
      left join public.regioes_df rc on rc.id = c.regiao_id
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
    select p.*, m.soma_casada, m.radicais, dist.km, dist.sigla
      from pre p
      cross join lateral (
        select coalesce(sum(t.peso), 0) as soma_casada, coalesce(array_agg(t.termo), '{}'::text[]) as radicais
          from t where p.busca_tsv @@ quote_literal(t.termo)::tsquery
      ) m
      left join lateral (
        select min(public.distancia_km(p.lat, p.lon, l.lat, l.lon)) as km,
               (array_agg(l.sigla order by public.distancia_km(p.lat, p.lon, l.lat, l.lon), l.sigla))[1] as sigla
          from lojas l where p.lat is not null
      ) dist on true
     where p_km_max is null or dist.km <= p_km_max
  )
  select p.id,
         least(100, round(100 * p.soma_casada / nullif((select soma from total), 0)))::integer,
         array(select k from unnest(p.palavras_chave) k
                where tsvector_to_array(to_tsvector('portuguese'::regconfig, public.norm_termos(k))) && p.radicais
                limit 8),
         (count(*) over ())::integer,
         p.km, p.sigla
    from pontos p
   order by case when p_ordem = 'distancia' then p.km end asc nulls last,
            (least(100, round(100 * p.soma_casada / nullif((select soma from total), 0)))) desc,
            p.ultima_movimentacao asc, p.id
   limit greatest(p_limite, 1) offset greatest(p_deslocamento, 0)
$$;

-- ───────────────────────────────────────────────────────────────────────
--  6) Considerações do RH sobre o candidato
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.consideracoes_candidato (
  id             uuid primary key default gen_random_uuid(),
  candidato_id   uuid not null references public.candidatos(id) on delete cascade,
  candidatura_id uuid references public.candidaturas(id) on delete set null,
  entrevista_id  uuid references public.entrevistas(id) on delete set null,
  vaga_titulo    text,                                      -- o contexto da época: sobrevive se a vaga for renomeada ou apagada
  texto          text not null check (length(btrim(texto)) between 1 and 4000),
  autor_id       uuid references public.usuarios(id) on delete set null,
  criado_em      timestamptz not null default now()
);
comment on table public.consideracoes_candidato is
  'Anotações do RH sobre o candidato (ex.: após a entrevista). Presas ao candidato: continuam se ele voltar ao banco. Só o expurgo as apaga.';
create index if not exists idx_consideracoes_candidato on public.consideracoes_candidato (candidato_id, criado_em desc);
create index if not exists idx_consideracoes_candidatura on public.consideracoes_candidato (candidatura_id) where candidatura_id is not null;
create index if not exists idx_consideracoes_entrevista on public.consideracoes_candidato (entrevista_id) where entrevista_id is not null;
create index if not exists idx_consideracoes_autor on public.consideracoes_candidato (autor_id) where autor_id is not null;

alter table public.consideracoes_candidato enable row level security;
drop policy if exists consideracoes_leitura on public.consideracoes_candidato;
create policy consideracoes_leitura on public.consideracoes_candidato for select to authenticated using (public.fn_usuario_ativo());
revoke all on public.consideracoes_candidato from anon, authenticated;
grant select on public.consideracoes_candidato to authenticated;
grant all on public.consideracoes_candidato to service_role;

create or replace function public.registrar_consideracao(p_candidato_id uuid, p_texto text, p_entrevista_id uuid default null)
returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_texto        text := btrim(p_texto);
  v_status       public.status_banco_talentos;
  v_candidatura  uuid;
  v_vaga_titulo  text;
  v_id           uuid;
begin
  perform public.fn_exige_usuario_ativo();
  if v_texto is null or v_texto = '' then
    raise exception 'Escreva a consideração.';
  end if;
  if length(v_texto) > 4000 then
    raise exception 'A consideração pode ter até 4.000 caracteres.';
  end if;

  select status_banco into v_status from public.candidatos where id = p_candidato_id;
  if not found or v_status = 'expurgado' then
    raise exception 'Candidato não encontrado (ou já excluído).';
  end if;

  if p_entrevista_id is not null then
    -- o contexto vem da entrevista, e ela precisa ser deste candidato
    select ca.id, v.titulo into v_candidatura, v_vaga_titulo
      from public.entrevistas e
      join public.candidaturas ca on ca.id = e.candidatura_id
      left join public.vagas v on v.id = ca.vaga_id
     where e.id = p_entrevista_id and ca.candidato_id = p_candidato_id;
    if not found then
      raise exception 'Esta entrevista não é deste candidato.';
    end if;
  else
    -- sem entrevista: se ele está em processo, o contexto é a candidatura aberta
    select ca.id, v.titulo into v_candidatura, v_vaga_titulo
      from public.candidaturas ca left join public.vagas v on v.id = ca.vaga_id
     where ca.candidato_id = p_candidato_id and ca.encerrada_em is null limit 1;
  end if;

  insert into public.consideracoes_candidato (candidato_id, candidatura_id, entrevista_id, vaga_titulo, texto, autor_id)
  values (p_candidato_id, v_candidatura, p_entrevista_id, v_vaga_titulo, v_texto, auth.uid())
  returning id into v_id;

  update public.candidatos set ultima_movimentacao = now() where id = p_candidato_id;

  -- a auditoria guarda que houve e o tamanho, nunca o texto (pode ter dado sensível)
  perform public.fn_registra_auditoria('consideracao_registrada', 'candidatos', p_candidato_id, null,
    jsonb_build_object('caracteres', length(v_texto), 'entrevista', p_entrevista_id is not null),
    'Consideração do RH registrada');
  return v_id;
end $$;

-- Autor ou administrador podem excluir (uma anotação errada ou indevida)
create or replace function public.excluir_consideracao(p_id uuid)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_autor uuid;
  v_cand  uuid;
begin
  perform public.fn_exige_usuario_ativo();
  select autor_id, candidato_id into v_autor, v_cand from public.consideracoes_candidato where id = p_id;
  if not found then
    raise exception 'Consideração não encontrada.';
  end if;
  if v_autor is distinct from auth.uid() and not public.fn_usuario_admin() then
    raise exception 'Só quem escreveu a consideração, ou o administrador, pode excluí-la.';
  end if;
  delete from public.consideracoes_candidato where id = p_id;
  perform public.fn_registra_auditoria('consideracao_registrada', 'candidatos', v_cand, null,
    jsonb_build_object('excluida', true), 'Consideração do RH excluída');
end $$;

create or replace view public.vw_consideracoes with (security_invoker = true) as
select cc.id, cc.candidato_id, cc.candidatura_id, cc.entrevista_id, cc.vaga_titulo, cc.texto, cc.criado_em,
       cc.autor_id, public.fn_nome_usuario(cc.autor_id) as autor_nome
  from public.consideracoes_candidato cc;

-- ───────────────────────────────────────────────────────────────────────
--  7) O expurgo também apaga as considerações e a região; a edição ganha região e bairro
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_expurgar_candidato(p_candidato_id uuid, p_motivo text)
returns integer
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_arquivos integer;
begin
  perform 1 from public.candidatos where id = p_candidato_id and status_banco <> 'expurgado' for update;
  if not found then
    return 0;                                   -- já expurgado (ou inexistente): nada a fazer
  end if;

  insert into public.arquivos_para_remover (storage_path)
  select distinct storage_path from public.curriculos
   where candidato_id = p_candidato_id and storage_path is not null
  on conflict (storage_path) do nothing;
  get diagnostics v_arquivos = row_count;

  update public.curriculos
     set texto_extraido = null, storage_path = null, nome_arquivo = null,
         email_message_id = null, email_assunto = null
   where candidato_id = p_candidato_id;

  delete from public.analises_ia where candidato_id = p_candidato_id;
  delete from public.consideracoes_candidato where candidato_id = p_candidato_id;

  update public.avaliacoes
     set resumo_nota = null, resumo_ia = null,
         pontos_fortes = '{}', lacunas = '{}', requisitos_faltantes = '{}'
   where candidatura_id in (select id from public.candidaturas where candidato_id = p_candidato_id);

  update public.entrevistas
     set observacoes = null, mensagem_enviada = null
   where candidatura_id in (select id from public.candidaturas where candidato_id = p_candidato_id);

  update public.candidaturas
     set dados_pessoais = null, email_assunto = null, email_message_id = null, observacao_atribuicao = null,
         status_registro = 'expurgado', expurgado_em = now(), inativado_em = coalesce(inativado_em, now())
   where candidato_id = p_candidato_id;

  -- sugestões que ainda estavam pendentes deste candidato perdem o sentido
  update public.sanitizacao_sugestoes
     set status = 'expirada', decidido_em = now(), observacao = 'Dados do candidato excluídos'
   where candidato_id = p_candidato_id and status = 'pendente';

  -- só o hash de identidade fica (para reconhecer um reenvio futuro), além de datas e situação
  update public.candidatos
     set nome = null, sexo = null, data_nascimento = null, idade_informada = null, idade_informada_em = null,
         cidade = null, uf = null, bairro = null, regiao_id = null, regiao_origem = null,
         telefone = null, telefone_e164 = null, email = null,
         escolaridade = null, anos_experiencia = null, cnh = null,
         area_sugerida = null, cargo_sugerido = null, nivel_sugerido = null, ia_confianca = null,
         palavras_chave = '{}',
         revisao_manual = false, analise_atual_id = null, reanalise_solicitada_em = null,
         consentimento_em = null, consentimento_origem = null, ultimo_contato_em = null,
         sanitizacao_adiada_ate = null,
         status_banco = 'expurgado', expurgado_em = now(), inativado_em = coalesce(inativado_em, now()),
         motivo_inativacao = 'dados excluídos'
   where id = p_candidato_id;

  perform public.fn_registra_auditoria(
    'exclusao_manual_lgpd', 'candidatos', p_candidato_id,
    null, jsonb_build_object('status_banco', 'expurgado', 'arquivos_a_remover', v_arquivos),
    coalesce(p_motivo, 'Exclusão de dados'));
  return v_arquivos;
end $$;

create or replace function public.editar_candidato(p_candidato_id uuid, p_dados jsonb)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_campos text[];
  v_sexo   text := nullif(lower(btrim(p_dados ->> 'sexo')), '');
  v_uf     text := nullif(upper(btrim(p_dados ->> 'uf')), '');
  v_esc    text := nullif(lower(btrim(p_dados ->> 'escolaridade')), '');
  v_regiao uuid;
begin
  perform public.fn_exige_usuario_ativo();
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' then
    raise exception 'Dados inválidos.';
  end if;
  if p_dados ? 'sexo' and v_sexo is not null and v_sexo not in ('masculino', 'feminino') then
    raise exception 'Sexo deve ser masculino ou feminino.';
  end if;
  if p_dados ? 'uf' and v_uf is not null and v_uf !~ '^[A-Z]{2}$' then
    raise exception 'UF deve ter 2 letras (ex.: DF).';
  end if;
  if p_dados ? 'escolaridade' and v_esc is not null
     and v_esc not in ('nenhuma', 'fundamental', 'medio', 'tecnico', 'superior', 'pos') then
    raise exception 'Escolaridade inválida.';
  end if;
  if p_dados ? 'regiao_id' then
    v_regiao := nullif(btrim(p_dados ->> 'regiao_id'), '')::uuid;
    if v_regiao is not null and not exists (select 1 from public.regioes_df where id = v_regiao) then
      raise exception 'Região inválida.';
    end if;
  end if;

  select coalesce(array_agg(k order by k), '{}') into v_campos
    from jsonb_object_keys(p_dados) k
   where k in ('nome', 'sexo', 'data_nascimento', 'idade_informada', 'cidade', 'uf', 'bairro', 'regiao_id', 'telefone',
               'telefone_e164', 'email', 'escolaridade', 'anos_experiencia', 'cnh');

  update public.candidatos c set
    nome             = case when p_dados ? 'nome'             then nullif(btrim(p_dados ->> 'nome'), '') else c.nome end,
    sexo             = case when p_dados ? 'sexo'             then v_sexo else c.sexo end,
    data_nascimento  = case when p_dados ? 'data_nascimento'  then nullif(p_dados ->> 'data_nascimento', '')::date else c.data_nascimento end,
    idade_informada  = case when p_dados ? 'idade_informada'  then nullif(p_dados ->> 'idade_informada', '')::smallint else c.idade_informada end,
    idade_informada_em = case when p_dados ? 'idade_informada' then current_date else c.idade_informada_em end,
    cidade           = case when p_dados ? 'cidade'           then nullif(btrim(p_dados ->> 'cidade'), '') else c.cidade end,
    uf               = case when p_dados ? 'uf'               then v_uf else c.uf end,
    bairro           = case when p_dados ? 'bairro'           then nullif(btrim(p_dados ->> 'bairro'), '') else c.bairro end,
    -- região escolhida à mão vale sempre; em branco volta ao automático (o gatilho acha pela cidade/bairro)
    regiao_id        = case when p_dados ? 'regiao_id'        then v_regiao else c.regiao_id end,
    regiao_origem    = case when p_dados ? 'regiao_id'        then (case when v_regiao is null then null else 'manual' end) else c.regiao_origem end,
    telefone         = case when p_dados ? 'telefone'         then nullif(btrim(p_dados ->> 'telefone'), '') else c.telefone end,
    telefone_e164    = case when p_dados ? 'telefone_e164'    then nullif(btrim(p_dados ->> 'telefone_e164'), '') else c.telefone_e164 end,
    email            = case when p_dados ? 'email'            then nullif(lower(btrim(p_dados ->> 'email')), '') else c.email end,
    escolaridade     = case when p_dados ? 'escolaridade'     then v_esc else c.escolaridade end,
    anos_experiencia = case when p_dados ? 'anos_experiencia' then nullif(p_dados ->> 'anos_experiencia', '')::numeric else c.anos_experiencia end,
    cnh              = case when p_dados ? 'cnh'              then nullif(upper(btrim(p_dados ->> 'cnh')), '') else c.cnh end
  where c.id = p_candidato_id and c.status_banco <> 'expurgado';

  if not found then
    raise exception 'Candidato não encontrado (ou já excluído).';
  end if;

  -- só os NOMES dos campos vão para a auditoria, nunca os valores (LGPD)
  perform public.fn_registra_auditoria('alteracao_candidato', 'candidatos', p_candidato_id, null,
    jsonb_build_object('campos', to_jsonb(v_campos)), 'Dados do candidato editados pelo RH');
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  8) A view do banco informa a região (colunas novas, sempre no fim)
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
  c.palavras_chave,
  -- região onde mora (030)
  c.regiao_id, rg.nome                                                                 as regiao_nome, c.regiao_origem, c.bairro
from public.candidatos c
left join public.analises_ia a on a.id = c.analise_atual_id
left join public.regioes_df rg on rg.id = c.regiao_id
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
revoke all on public.vw_consideracoes from anon, authenticated;
grant select on public.vw_consideracoes to authenticated;
grant all on public.vw_consideracoes to service_role;

revoke execute on function
  public.fn_regiao_por_texto(text, text),
  public.fn_candidato_regiao(),
  public.distancia_km(numeric, numeric, numeric, numeric),
  public.fn_lojas_da_vaga(uuid),
  public.distancias_para_vaga(uuid, uuid[]),
  public.ranking_candidatos_vaga(uuid, integer, integer, text, numeric),
  public.registrar_consideracao(uuid, text, uuid),
  public.excluir_consideracao(uuid)
from public, anon, authenticated;
-- o painel chama estas (as de dentro do ranking rodam com a sessão dele, por isso também precisam de EXECUTE)
grant execute on function
  public.fn_regiao_por_texto(text, text),
  public.distancia_km(numeric, numeric, numeric, numeric),
  public.fn_lojas_da_vaga(uuid),
  public.distancias_para_vaga(uuid, uuid[]),
  public.ranking_candidatos_vaga(uuid, integer, integer, text, numeric),
  public.registrar_consideracao(uuid, text, uuid),
  public.excluir_consideracao(uuid)
to authenticated;
grant execute on all functions in schema public to service_role;
