-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · SELEÇÃO DE CURRÍCULOS POR QUALIFICAÇÃO
--
--  Rodar depois da 032. Pode rodar de novo sem problema.
--
--  A IA qualifica cada currículo (setor, função e nível, 031) e dá uma nota. Na vaga NÃO há mais IA escolhendo
--  currículo: o RH pede "Selecionar CVs" e o banco devolve, por SQL, os currículos qualificados com o MESMO setor,
--  função e nível da vaga, do maior para o menor nota.
--
--    • curriculos.nota_classificacao — a nota (0–100) que a IA deu ao currículo
--    • vagas.funcao_setor / vagas.nivel_funcao — a função e o nível que a vaga pede (o setor já existia)
--    • selecionar_curriculos_vaga()   — a seleção; fn_curriculos_da_vaga() é o filtro, compartilhado com a contagem
--      "No banco" do card da vaga
--    • atribuir candidato a uma vaga deixa de pedir avaliação da IA (avaliacao_pendente = false)
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  1) Nota do currículo
-- ───────────────────────────────────────────────────────────────────────
alter table public.curriculos
  add column if not exists nota_classificacao smallint
    check (nota_classificacao is null or nota_classificacao between 0 and 100);
comment on column public.curriculos.nota_classificacao is
  'Nota de 0 a 100 que a IA deu ao currículo ao qualificá-lo (critério de nota do prompt). Ordena a seleção de currículos de uma vaga. Nulo = ainda não qualificado.';

-- Seleção: setor + função + nível iguais, do maior para o menor nota (só o currículo atual de cada candidato)
create index if not exists idx_curriculos_selecao
  on public.curriculos (setor_adequado, funcao_setor, nivel_funcao, nota_classificacao desc nulls last)
  where atual and setor_adequado is not null;

-- O expurgo apaga tudo o que a IA disse do currículo (gatilho da 032, agora também com a nota)
create or replace function public.fn_curriculo_limpa_ao_expurgar()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.setor_adequado     := null;
  new.funcao_setor       := null;
  new.nivel_funcao       := null;
  new.nota_classificacao := null;
  new.email_envio        := null;
  return new;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  2) Função e nível da vaga
-- ───────────────────────────────────────────────────────────────────────
-- Nulos nas vagas que já existiam: o painel exige os dois ao salvar. Sem eles a vaga não seleciona currículos.
alter table public.vagas
  add column if not exists funcao_setor text,
  add column if not exists nivel_funcao text references public.niveis_funcao(codigo) on update cascade on delete set null;
comment on column public.vagas.funcao_setor is 'Função que a vaga pede (nome em "funcoes_setor", do setor da vaga). Junto com o setor e o nível, filtra os currículos.';
comment on column public.vagas.nivel_funcao is 'Nível que a vaga pede (código em "niveis_funcao").';

-- A função tem de existir (e estar ativa) no setor da vaga: um texto solto nunca casaria com nenhum currículo.
create or replace function public.fn_vaga_valida_funcao()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.funcao_setor is not null and not exists (
       select 1 from public.funcoes_setor f
        where f.setor_id = new.setor_id and f.nome = new.funcao_setor and f.ativo) then
    raise exception 'A função "%" não existe no setor escolhido. Escolha uma função da lista.', new.funcao_setor;
  end if;
  return new;
end $$;

drop trigger if exists trg_vaga_valida_funcao on public.vagas;
create trigger trg_vaga_valida_funcao
  before insert or update of setor_id, funcao_setor on public.vagas
  for each row execute function public.fn_vaga_valida_funcao();

-- ───────────────────────────────────────────────────────────────────────
--  3) Seleção de currículos da vaga
-- ───────────────────────────────────────────────────────────────────────
-- O filtro: candidatos disponíveis cujo currículo ATUAL tem exatamente o setor, a função e o nível da vaga. Fora: quem não
-- está disponível, quem está na lista negra e quem já tem candidatura ABERTA nesta vaga ou foi reprovado/descartado NELA
-- (só volta em vaga nova). Vaga sem função ou nível não seleciona ninguém. É SECURITY INVOKER: vale a RLS de quem chama.
create or replace function public.fn_curriculos_da_vaga(p_vaga_id uuid)
returns table (candidato_id uuid, curriculo_id uuid, nota smallint, ultima_movimentacao timestamptz)
language sql stable
set search_path = public
as $$
  select c.id, cu.id, cu.nota_classificacao, c.ultima_movimentacao
    from public.vagas v
    join public.setores s on s.id = v.setor_id
    join public.curriculos cu
      on cu.atual
     and cu.setor_adequado = s.nome
     and cu.funcao_setor   = v.funcao_setor
     and cu.nivel_funcao   = v.nivel_funcao
    join public.candidatos c on c.id = cu.candidato_id
   where v.id = p_vaga_id
     and v.funcao_setor is not null and v.nivel_funcao is not null
     and c.status_banco = 'ativo'
     and not c.lista_negra
     and not exists (select 1 from public.candidaturas ca
                      where ca.candidato_id = c.id and ca.vaga_id = p_vaga_id
                        and (ca.encerrada_em is null or ca.status in ('reprovado', 'descartado')))
$$;

--     p_ordem: 'nota' (padrão: maior nota primeiro) ou 'distancia' (mais perto da loja primeiro; empate pela nota)
--     p_km_max: só quem mora até tantos km da loja mais próxima (sem região identificada fica de fora quando há limite)
--     total = quantos currículos combinam ao todo (igual em todas as linhas), para a paginação da tela
create or replace function public.selecionar_curriculos_vaga(
  p_vaga_id uuid, p_limite integer default 50, p_deslocamento integer default 0,
  p_ordem text default 'nota', p_km_max numeric default null)
returns table (candidato_id uuid, nota integer, total integer, km_mais_proxima numeric, loja_mais_proxima text)
language sql stable
set search_path = public
as $$
  with lojas as (select * from public.fn_lojas_da_vaga(p_vaga_id)),
  base as (
    select f.candidato_id, f.nota, f.ultima_movimentacao, rc.latitude as lat, rc.longitude as lon
      from public.fn_curriculos_da_vaga(p_vaga_id) f
      join public.candidatos c on c.id = f.candidato_id
      left join public.regioes_df rc on rc.id = c.regiao_id
  ),
  perto as (
    select b.*, d.km, d.sigla
      from base b
      left join lateral (
        select min(public.distancia_km(b.lat, b.lon, l.lat, l.lon)) as km,
               (array_agg(l.sigla order by public.distancia_km(b.lat, b.lon, l.lat, l.lon), l.sigla))[1] as sigla
          from lojas l where b.lat is not null
      ) d on true
     where p_km_max is null or d.km <= p_km_max
  )
  select x.candidato_id, x.nota::integer, (count(*) over ())::integer, x.km, x.sigla
    from perto x
   order by case when p_ordem = 'distancia' then x.km end asc nulls last,
            x.nota desc nulls last, x.ultima_movimentacao asc, x.candidato_id
   limit greatest(p_limite, 1) offset greatest(p_deslocamento, 0)
$$;

-- ───────────────────────────────────────────────────────────────────────
--  4) Card da vaga: "No banco" passa a contar os currículos que combinam em setor + função + nível
--     (colunas novas sempre no fim: é o que o CREATE OR REPLACE VIEW permite)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.vw_vagas_resumo with (security_invoker = true) as
select
  v.id, v.titulo, v.descricao, v.quantidade, v.versao_criterios, v.data_abertura, v.status,
  (current_date - v.data_abertura)                    as dias_aberta,
  s.id as setor_id, s.nome as setor_nome, s.cor as setor_cor, s.icone as setor_icone,
  coalesce(m.total_candidatos, 0::bigint)             as total_candidatos,
  coalesce(m.total_em_aberto, 0::bigint)              as total_em_aberto,
  coalesce(m.total_entrevistas, 0::bigint)            as total_entrevistas,
  coalesce(m.total_contratados, 0::bigint)            as total_contratados,
  (select count(*) from public.fn_curriculos_da_vaga(v.id)) as compativeis_no_banco,
  (select string_agg(emp.sigla, ' · ' order by emp.sigla)
     from public.vaga_empresas ve join public.empresas emp on emp.id = ve.empresa_id
    where ve.vaga_id = v.id)                          as empresas,
  v.funcao_setor, v.nivel_funcao
from public.vagas v
join public.setores s on s.id = v.setor_id
left join lateral (
  select count(*)                                                                       as total_candidatos,
         count(*) filter (where c.encerrada_em is null)                                 as total_em_aberto,
         count(*) filter (where c.status = any (array['entrevista_agendada', 'entrevista_realizada']::public.status_candidatura[])) as total_entrevistas,
         count(*) filter (where c.status = 'contratado')                                as total_contratados
    from public.candidaturas c
   where c.vaga_id = v.id and c.status_registro = 'ativo' and c.origem <> 'triagem_legada'
) m on true
where v.status = 'ativo';

-- ───────────────────────────────────────────────────────────────────────
--  5) Atribuir candidato a uma vaga não pede mais avaliação da IA (era avaliacao_pendente = true).
--     A função é a da 028, idêntica, exceto por esse valor.
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_atribuir_candidato_vaga(
  p_candidato_id uuid, p_vaga_id uuid, p_usuario_id uuid, p_observacao text default null)
returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status      public.status_banco_talentos;
  v_negra       boolean;
  v_vaga_status public.status_registro;
  v_id          uuid;
begin
  select status_banco, lista_negra into v_status, v_negra from public.candidatos where id = p_candidato_id for update;
  if not found then
    raise exception 'Candidato não encontrado.';
  end if;
  if v_negra then
    raise exception 'Este candidato está na lista negra e não pode ser atribuído a vagas.';
  elsif v_status = 'em_processo' then
    raise exception 'Este candidato já está em um processo seletivo. Encerre a candidatura atual antes de atribuí-lo a outra vaga.';
  elsif v_status = 'inativo' then
    raise exception 'Candidato inativo. Reative-o no Banco de Talentos antes de atribuir a uma vaga.';
  elsif v_status = 'expurgado' then
    raise exception 'Os dados deste candidato foram excluídos.';
  end if;

  select status into v_vaga_status from public.vagas where id = p_vaga_id;
  if not found then
    raise exception 'Vaga não encontrada.';
  end if;
  if v_vaga_status <> 'ativo' then
    raise exception 'Esta vaga não está mais aberta.';
  end if;

  if exists (select 1 from public.candidaturas
              where candidato_id = p_candidato_id and vaga_id = p_vaga_id and status in ('reprovado', 'descartado')) then
    raise exception 'Este candidato já foi reprovado nesta vaga. Ele só pode voltar em uma vaga nova.';
  end if;

  insert into public.candidaturas
         (candidato_id, vaga_id, status, atribuido_por, data_atribuicao, vaga_confirmada_rh,
          avaliacao_pendente, origem, observacao_atribuicao)
  values (p_candidato_id, p_vaga_id, 'aguardando', p_usuario_id, now(), true,
          false, 'atribuicao_manual', nullif(btrim(p_observacao), ''))
  returning id into v_id;

  perform public.fn_registra_auditoria(
    'atribuicao_candidato', 'candidaturas', v_id, null,
    jsonb_build_object('candidato_id', p_candidato_id, 'vaga_id', p_vaga_id),
    'Candidato atribuído à vaga pelo RH');
  return v_id;
end $$;

-- Pedidos de avaliação que ainda estivessem na fila deixam de valer
update public.candidaturas set avaliacao_pendente = false where avaliacao_pendente;

-- ───────────────────────────────────────────────────────────────────────
--  Privilégios
-- ───────────────────────────────────────────────────────────────────────
revoke execute on function
  public.fn_curriculos_da_vaga(uuid),
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric)
from public, anon, authenticated;
-- o painel chama a seleção; a view do card e a seleção chamam o filtro com a sessão dele, por isso também precisa de EXECUTE
grant execute on function
  public.fn_curriculos_da_vaga(uuid),
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric)
to authenticated, service_role;
