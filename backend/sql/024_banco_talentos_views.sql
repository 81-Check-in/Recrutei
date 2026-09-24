-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · PASSO 5 de 6: views e busca
--
--  • vw_banco_talentos          a lista do Banco de Talentos (candidato + sugestão da IA + situação)
--  • vw_banco_opcoes            áreas e cargos que existem no banco (opções dos filtros)
--  • filtrar_banco_talentos()   filtros que a view não expressa (palavras no currículo, local, rotatividade)
--  • vw_candidaturas            uma candidatura (candidato ↔ vaga) com nota, currículo e sugestão da IA
--  • vw_sanitizacao_sugestoes   a fila de sanitização
--  • refeitas sobre o modelo novo: vw_candidatos, vw_agenda_entrevistas, vw_vagas_resumo,
--    vw_dashboard_metricas, vw_reincidentes
--  • REMOVIDAS: vw_triagem e filtrar_triagem (a Triagem virou o Banco de Talentos). Além de obsoleta,
--    vw_triagem não usava security_invoker: qualquer usuário logado lia os dados dela, mesmo inativo.
--
--  Todas com security_invoker: valem as políticas (RLS) de quem consulta.
--  Pode rodar de novo sem problema.
-- ════════════════════════════════════════════════════════════════════════

drop function if exists public.filtrar_triagem(jsonb);
drop view if exists public.vw_triagem;
drop function if exists public.filtrar_banco_talentos(jsonb);
drop view if exists public.vw_banco_opcoes;
drop view if exists public.vw_banco_talentos;
drop view if exists public.vw_candidaturas;
drop view if exists public.vw_sanitizacao_sugestoes;
drop view if exists public.vw_candidatos;
drop view if exists public.vw_agenda_entrevistas;
drop view if exists public.vw_dashboard_metricas;
drop view if exists public.vw_reincidentes;
drop view if exists public.vw_vagas_resumo;

-- ───────────────────────────────────────────────────────────────────────
--  BANCO DE TALENTOS
--  Os filtros da tela caem em colunas de "candidatos" (nome_norm, sexo, nascimento_ref, cidade_norm,
--  área/cargo/nível, status_banco), todas com índice (ver 021).
-- ───────────────────────────────────────────────────────────────────────
create view public.vw_banco_talentos with (security_invoker = true) as
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
           where s.candidato_id = c.id and s.status = 'pendente')                      as sanitizacao_pendente
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

-- Valores que existem hoje no banco (áreas e cargos que a IA sugeriu, com a contagem), para montar os filtros
-- da tela: a IA pode sugerir uma área fora da lista de setores, e o filtro precisa enxergá-la.
create view public.vw_banco_opcoes with (security_invoker = true) as
select 'area'::text as tipo, c.area_sugerida as valor, count(*) as total
  from public.candidatos c where c.status_banco <> 'expurgado' and c.area_sugerida is not null
 group by c.area_sugerida
union all
select 'cargo', c.cargo_sugerido, count(*)
  from public.candidatos c where c.status_banco <> 'expurgado' and c.cargo_sugerido is not null
 group by c.cargo_sugerido;

-- Filtros que dependem de TEXTO (currículo, análise da IA) e por isso não cabem em um índice comum.
-- O painel aplica por cima os filtros indexados (nome, sexo, idade, cidade, área, cargo, nível, status,
-- escolaridade, experiência, CNH) e a ordenação, como fazia com a Triagem.
--
-- filtros (jsonb, todos opcionais):
--   palavras          ["empilhadeira", "cnh b"]     termos (frase inteira conta como um termo)
--   palavras_modo     "todas" | "qualquer"          padrão: todas
--   palavras_onde     "curriculo" | "analise" | "ambos"   padrão: curriculo
--   local             "samambaia"                   cidade/bairro/endereço (início do currículo, 1.500 caracteres)
--   excluir_locais    ["planaltina", "itapoa"]      remove quem mora nesses lugares
--   rotatividade      "alta" | "baixa" | "sem_alta" a IA registra "Alta/Baixa rotatividade: …" na análise
create function public.filtrar_banco_talentos(filtros jsonb default '{}'::jsonb)
returns setof public.vw_banco_talentos
language sql stable
set search_path = public
as $$
  with f as (
    select
      array(select public.norm_busca(x)
              from jsonb_array_elements_text(coalesce(filtros -> 'palavras', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as palavras,
      coalesce(filtros ->> 'palavras_modo', 'todas')                 as modo,
      coalesce(filtros ->> 'palavras_onde', 'curriculo')             as onde,
      nullif(btrim(public.norm_busca(filtros ->> 'local')), '')      as local,
      array(select public.norm_busca(x)
              from jsonb_array_elements_text(coalesce(filtros -> 'excluir_locais', '[]'::jsonb)) x
             where btrim(x) <> '')                                   as excluir,
      filtros ->> 'rotatividade'                                     as rot
  )
  select v.*
  from f
  cross join public.vw_banco_talentos v
  left join lateral (
    select cu.texto_extraido from public.curriculos cu
     where cu.candidato_id = v.id and cu.atual limit 1
  ) cu on true
  cross join lateral (
    select
      public.norm_busca(cu.texto_extraido)                                        as cv,
      public.norm_busca(concat_ws(' ', v.resumo_ia,
             array_to_string(v.pontos_positivos, ' '),
             array_to_string(v.pontos_negativos, ' ')))                           as analise,
      public.norm_busca(concat_ws(' ', v.cidade, v.uf, left(cu.texto_extraido, 1500))) as local_txt
  ) t
  cross join lateral (
    select case f.onde when 'analise' then t.analise
                       when 'ambos'   then t.cv || ' ' || t.analise
                       else t.cv end                                              as alvo
  ) a
  where
    (cardinality(f.palavras) = 0
     or case f.modo
          when 'qualquer' then exists (select 1 from unnest(f.palavras) p where position(p in a.alvo) > 0)
          else not exists (select 1 from unnest(f.palavras) p where position(p in a.alvo) = 0)
        end)
    and (f.local is null or position(f.local in t.local_txt) > 0)
    and not exists (select 1 from unnest(f.excluir) e where position(e in t.local_txt) > 0)
    and (f.rot is null
         or (f.rot = 'alta'     and exists (select 1 from unnest(v.pontos_negativos) x where x like 'Alta rotatividade%'))
         or (f.rot = 'baixa'    and exists (select 1 from unnest(v.pontos_positivos) x where x like 'Baixa rotatividade%'))
         or (f.rot = 'sem_alta' and not exists (select 1 from unnest(v.pontos_negativos) x where x like 'Alta rotatividade%')))
$$;

-- ───────────────────────────────────────────────────────────────────────
--  CANDIDATURA (candidato ↔ vaga): detalhe, nota e currículo
-- ───────────────────────────────────────────────────────────────────────
create view public.vw_candidaturas with (security_invoker = true) as
select
  ca.id, ca.candidato_id,
  k.nome, k.telefone, k.telefone_e164, k.email, k.cidade, k.uf, k.sexo,
  k.area_sugerida, k.cargo_sugerido, k.nivel_sugerido, k.ia_confianca, k.revisao_manual, k.status_banco,
  ca.status, ca.origem, ca.aderencia_vaga, ca.recebido_em, ca.data_atribuicao, ca.atribuido_por,
  public.fn_nome_usuario(ca.atribuido_por)                       as atribuido_por_nome,
  ca.selecionado_em, ca.encerrada_em, ca.resultado_final, ca.observacao_atribuicao, ca.avaliacao_pendente,
  v.id                                                           as vaga_id,
  v.titulo                                                       as vaga_titulo,
  s.nome                                                         as setor_nome,
  s.cor                                                          as setor_cor,
  s.icone                                                        as setor_icone,
  av.nota, av.resumo_nota, av.resumo_ia, av.pontos_fortes, av.lacunas, av.requisitos_faltantes,
  av.eliminado_por_regra, av.divergencia_detectada,
  cur.storage_path, cur.nome_arquivo, cur.origem                 as curriculo_origem
from public.candidaturas ca
join public.candidatos k on k.id = ca.candidato_id
left join public.vagas v on v.id = ca.vaga_id
left join public.setores s on s.id = v.setor_id
left join lateral (
  select a.nota, a.resumo_nota, a.resumo_ia, a.pontos_fortes, a.lacunas, a.requisitos_faltantes,
         a.eliminado_por_regra, a.divergencia_detectada
    from public.avaliacoes a where a.candidatura_id = ca.id order by a.sequencia desc limit 1
) av on true
left join lateral (
  select cu.storage_path, cu.nome_arquivo, cu.origem
    from public.curriculos cu where cu.candidato_id = ca.candidato_id and cu.atual limit 1
) cur on true
where ca.status_registro = 'ativo' and k.status_banco <> 'expurgado';

-- Candidatos em processo (tela "Em processo"): candidaturas atribuídas pelo RH, abertas ou já decididas.
-- Vínculos automáticos do modelo antigo (triagem_legada) ficam de fora: eram só sugestão da IA.
create view public.vw_candidatos with (security_invoker = true) as
select
  ca.id, ca.candidato_id,
  k.nome, k.telefone, k.telefone_e164, k.email,
  ca.status, ca.selecionado_em, ca.data_atribuicao, ca.encerrada_em, ca.resultado_final,
  public.fn_nome_usuario(coalesce(ca.atribuido_por, ca.selecionado_por)) as selecionado_por_nome,
  v.titulo as vaga_titulo, s.nome as setor_nome, s.cor as setor_cor,
  a.nota,
  e.id as entrevista_id, e.data_hora as entrevista_data_hora,
  e.resultado as entrevista_resultado, e.local as entrevista_local
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
where ca.status_registro = 'ativo'
  and ca.origem <> 'triagem_legada'
  and k.status_banco <> 'expurgado'
  and ca.status = any (array['aguardando', 'selecionado', 'entrevista_agendada', 'entrevista_realizada',
                             'aprovado', 'reprovado', 'nao_compareceu', 'contratado']::public.status_candidatura[]);

create view public.vw_agenda_entrevistas with (security_invoker = true) as
select
  e.id, e.candidatura_id, ca.candidato_id,
  e.data_hora, e.duracao_minutos, e.local, e.entrevistador, e.resultado, e.observacoes,
  (e.data_hora + ((e.duracao_minutos || ' minutes'))::interval) as data_hora_fim,
  (e.data_hora)::date                                           as data,
  k.nome                                                        as candidato_nome,
  k.telefone                                                    as candidato_telefone,
  k.telefone_e164                                               as candidato_telefone_e164,
  v.titulo                                                      as vaga_titulo,
  s.nome                                                        as setor_nome,
  s.cor                                                         as setor_cor,
  cur.storage_path                                              as curriculo_path
from public.entrevistas e
join public.candidaturas ca on ca.id = e.candidatura_id
join public.candidatos k on k.id = ca.candidato_id
left join public.vagas v on v.id = ca.vaga_id
left join public.setores s on s.id = v.setor_id
left join lateral (
  select cu.storage_path from public.curriculos cu where cu.candidato_id = ca.candidato_id and cu.atual limit 1
) cur on true
where ca.status_registro = 'ativo' and k.status_banco <> 'expurgado';

-- Vagas abertas: quantos candidatos atribuídos, entrevistas, e quantos do banco combinam com o setor
create view public.vw_vagas_resumo with (security_invoker = true) as
select
  v.id, v.titulo, v.descricao, v.quantidade, v.versao_criterios, v.data_abertura, v.status,
  (current_date - v.data_abertura)                    as dias_aberta,
  s.id as setor_id, s.nome as setor_nome, s.cor as setor_cor, s.icone as setor_icone,
  coalesce(m.total_candidatos, 0::bigint)             as total_candidatos,
  coalesce(m.total_em_aberto, 0::bigint)              as total_em_aberto,
  coalesce(m.total_entrevistas, 0::bigint)            as total_entrevistas,
  coalesce(m.total_contratados, 0::bigint)            as total_contratados,
  (select count(*) from public.candidatos k
    where k.status_banco = 'ativo' and public.norm_busca(k.area_sugerida) = public.norm_busca(s.nome)) as compativeis_no_banco,
  (select string_agg(emp.sigla, ' · ' order by emp.sigla)
     from public.vaga_empresas ve join public.empresas emp on emp.id = ve.empresa_id
    where ve.vaga_id = v.id)                          as empresas
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

create view public.vw_dashboard_metricas with (security_invoker = true) as
select
  (select count(*) from public.curriculos where recebido_em >= (current_date - 7))                                     as curriculos_7d,
  (select count(*) from public.curriculos where recebido_em >= date_trunc('month', current_date::timestamptz))         as curriculos_mes,
  (select count(*) from public.candidaturas where origem <> 'triagem_legada' and data_atribuicao >= (current_date - 7)) as selecionados_7d,
  (select count(*) from public.candidaturas where origem <> 'triagem_legada' and data_atribuicao >= date_trunc('month', current_date::timestamptz)) as selecionados_mes,
  (select count(*) from public.entrevistas e join public.candidaturas c on c.id = e.candidatura_id
    where c.status_registro = 'ativo' and e.data_hora >= (current_date - 7))                                           as entrevistas_7d,
  (select count(*) from public.entrevistas e join public.candidaturas c on c.id = e.candidatura_id
    where c.status_registro = 'ativo' and e.data_hora >= date_trunc('month', current_date::timestamptz))               as entrevistas_mes,
  (select count(*) from public.vagas where status = 'ativo')                                                           as vagas_abertas,
  (select count(*) from public.excecoes where status = 'pendente')                                                     as excecoes_pendentes,
  (select count(*) from public.candidatos where status_banco <> 'expurgado')                                           as banco_total,
  (select count(*) from public.candidatos where status_banco = 'ativo')                                                as banco_ativos,
  (select count(*) from public.candidatos where status_banco = 'em_processo')                                          as banco_em_processo,
  (select count(*) from public.candidatos where status_banco = 'ativo' and revisao_manual and reanalise_solicitada_em is null) as revisao_manual_pendente,
  (select count(*) from public.sanitizacao_sugestoes where status = 'pendente')                                        as sanitizacao_pendentes;

create view public.vw_reincidentes with (security_invoker = true) as
select
  r.id, r.email, r.total_envios, r.primeiro_envio_em, r.ultimo_envio_em, r.bloqueado, r.bloqueado_em,
  r.motivo_bloqueio, u.nome as bloqueado_por_nome,
  (select count(distinct ca.id)
     from public.curriculos cu
     join public.candidaturas ca on ca.candidato_id = cu.candidato_id
    where cu.remetente_id = r.id and ca.status in ('reprovado', 'descartado')) as vezes_descartado,
  (select max(cu.recebido_em) from public.curriculos cu where cu.remetente_id = r.id) as ultima_candidatura_em
from public.remetentes r
left join public.usuarios u on u.id = r.bloqueado_por
where r.total_envios > 1;

-- ───────────────────────────────────────────────────────────────────────
--  SANITIZAÇÃO: a fila de sugestões (pendentes e o histórico de decisões)
-- ───────────────────────────────────────────────────────────────────────
create view public.vw_sanitizacao_sugestoes with (security_invoker = true) as
select
  sg.id, sg.ciclo_id, ci.gerada_em, ci.origem as ciclo_origem,
  sg.candidato_id, k.nome, k.cidade, k.uf, k.area_sugerida, k.cargo_sugerido, k.nivel_sugerido,
  k.status_banco, k.data_entrada,
  sg.motivos, sg.motivo_texto, sg.pontos, sg.prioridade, sg.ultima_movimentacao,
  sg.status, sg.decidido_por, public.fn_nome_usuario(sg.decidido_por) as decidido_por_nome,
  sg.decidido_em, sg.observacao, sg.adiada_ate
from public.sanitizacao_sugestoes sg
join public.sanitizacao_ciclos ci on ci.id = sg.ciclo_id
left join public.candidatos k on k.id = sg.candidato_id;

-- Views são só para leitura
revoke all on
  public.vw_banco_talentos, public.vw_banco_opcoes, public.vw_candidaturas, public.vw_candidatos, public.vw_agenda_entrevistas,
  public.vw_vagas_resumo, public.vw_dashboard_metricas, public.vw_reincidentes, public.vw_sanitizacao_sugestoes
from anon, authenticated;
grant select on
  public.vw_banco_talentos, public.vw_banco_opcoes, public.vw_candidaturas, public.vw_candidatos, public.vw_agenda_entrevistas,
  public.vw_vagas_resumo, public.vw_dashboard_metricas, public.vw_reincidentes, public.vw_sanitizacao_sugestoes
to authenticated;
grant all on
  public.vw_banco_talentos, public.vw_banco_opcoes, public.vw_candidaturas, public.vw_candidatos, public.vw_agenda_entrevistas,
  public.vw_vagas_resumo, public.vw_dashboard_metricas, public.vw_reincidentes, public.vw_sanitizacao_sugestoes
to service_role;

revoke all on function public.filtrar_banco_talentos(jsonb) from public, anon;
grant execute on function public.filtrar_banco_talentos(jsonb) to authenticated, service_role;
