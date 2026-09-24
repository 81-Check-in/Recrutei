-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · TELA "CANDIDATOS EM PROCESSO" POR VAGA
--
--  Rodar depois da 036. Pode rodar de novo sem problema. Só ACRESCENTA colunas (sempre no fim: é o que o CREATE OR REPLACE
--  VIEW permite), com o resto das duas views idêntico ao da 024.
--
--  O número de candidatos do card da vaga abre a tela "Candidatos em processo" filtrada por ela. Para isso:
--    • vw_candidatos   ganha vaga_id, a qualificação do candidato (área/cargo/nível) e nota_curriculo (a nota da IA ao currículo)
--    • vw_candidaturas ganha nota_curriculo (o detalhe da candidatura mostra a nota do currículo, já que a vaga não tem mais
--      avaliação da IA)
-- ════════════════════════════════════════════════════════════════════════

create or replace view public.vw_candidaturas with (security_invoker = true) as
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
  cur.storage_path, cur.nome_arquivo, cur.origem                 as curriculo_origem,
  cur.nota_classificacao                                         as nota_curriculo
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
  select cu.storage_path, cu.nome_arquivo, cu.origem, cu.nota_classificacao
    from public.curriculos cu where cu.candidato_id = ca.candidato_id and cu.atual limit 1
) cur on true
where ca.status_registro = 'ativo' and k.status_banco <> 'expurgado';

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
  cur.nota_classificacao as nota_curriculo
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
