-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Filtro por SEXO nos candidatos selecionados para uma vaga (045)
--
--  Rodar depois da 044. Pode rodar de novo sem problema.
--
--  O Banco de Talentos já filtra por sexo, mas as duas listas de "selecionados" não:
--    • Banco de Talentos → "Selecionar CVs" (currículos selecionados para a vaga): a barra de filtros some nesse modo.
--      selecionar_curriculos_vaga ganha p_sexo no fim: 'feminino', 'masculino' ou 'nao_informado' (sexo em branco);
--      nulo ou vazio = sem filtro. O total devolvido acompanha o filtro (a paginação continua certa).
--    • Em processo → "Candidatos selecionados para a vaga": vw_candidatos ganha a coluna sexo (sempre no fim: é o que o
--      CREATE OR REPLACE VIEW permite), com o resto da view idêntico ao da 037.
-- ════════════════════════════════════════════════════════════════════════

create or replace view public.vw_candidatos with (security_invoker = true) as
select
  ca.id, ca.candidato_id,
  k.nome, k.telefone, k.telefone_e164, k.email,
  ca.status, ca.selecionado_em, ca.data_atribuicao, ca.encerrada_em, ca.resultado_final,
  public.fn_nome_usuario(coalesce(ca.atribuido_por, ca.selecionado_por)) as selecionado_por_nome,
  v.titulo as vaga_titulo, s.nome as setor_nome, s.cor as setor_cor,
  a.nota,
  e.id as entrevista_id, e.data_hora as entrevista_data_hora,
  e.resultado as entrevista_resultado, e.local as entrevista_local,
  -- a vaga e a qualificação do currículo (a tela de uma vaga filtra por vaga_id e mostra a nota do currículo)
  ca.vaga_id, k.area_sugerida, k.cargo_sugerido, k.nivel_sugerido,
  cur.nota_classificacao as nota_curriculo,
  k.sexo
from public.candidaturas ca
join public.candidatos k on k.id = ca.candidato_id
left join public.vagas v on v.id = ca.vaga_id
left join public.setores s on s.id = v.setor_id
left join lateral (
  select av.nota from public.avaliacoes av where av.candidatura_id = ca.id order by av.sequencia desc limit 1
) a on true
left join lateral (
  select en.id, en.data_hora, en.resultado, en.local
    from public.entrevistas en where en.candidatura_id = ca.id order by en.data_hora desc limit 1
) e on true
left join lateral (
  select cu.nota_classificacao from public.curriculos cu where cu.candidato_id = ca.candidato_id and cu.atual limit 1
) cur on true
where ca.status_registro = 'ativo'
  and ca.origem <> 'triagem_legada'
  and k.status_banco <> 'expurgado'
  and ca.status = any (array['aguardando', 'selecionado', 'entrevista_agendada', 'entrevista_realizada',
                             'aprovado', 'reprovado', 'nao_compareceu', 'contratado']::public.status_candidatura[]);

-- A seleção da 038 com uma entrada a mais no fim (a assinatura antiga sai: duas versões da função confundiriam o painel)
--     p_sexo: 'feminino' | 'masculino' | 'nao_informado' (sem sexo cadastrado); nulo ou vazio = todos
drop function if exists public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[]);
create or replace function public.selecionar_curriculos_vaga(
  p_vaga_id uuid, p_limite integer default 50, p_deslocamento integer default 0,
  p_ordem text default 'nota', p_km_max numeric default null, p_lojas text[] default null,
  p_sexo text default null)
returns table (candidato_id uuid, nota integer, total integer, km_mais_proxima numeric, loja_mais_proxima text)
language sql stable
set search_path = public
as $$
  with lojas as (select * from public.fn_lojas_referencia(p_vaga_id, p_lojas)),
  base as (
    select f.candidato_id, f.nota, f.ultima_movimentacao, rc.latitude as lat, rc.longitude as lon
      from public.fn_curriculos_da_vaga(p_vaga_id) f
      join public.candidatos c on c.id = f.candidato_id
      left join public.regioes_df rc on rc.id = c.regiao_id
     where coalesce(p_sexo, '') = ''
        or (p_sexo = 'nao_informado' and c.sexo is null)
        or c.sexo = p_sexo
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

revoke execute on function
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text)
from public, anon, authenticated;
grant execute on function
  public.selecionar_curriculos_vaga(uuid, integer, integer, text, numeric, text[], text)
to authenticated, service_role;
