-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Revisão manual "sem nível" passa a ser Júnior (066)
--
--  Rodar depois da 065. Pode rodar de novo sem problema.
--
--  Regra nova do robô (ia.py): setor e função identificados, mas sem nível → Júnior, e o currículo não vai mais para a
--  revisão manual. Esta migração aplica a mesma regra a quem JÁ está na fila só por isso: análise atual com o motivo exato
--  "A IA não classificou: nível" e setor e função preenchidos. Quem não teve setor/função classificados (motivo com
--  "área" ou "cargo") continua na revisão manual; quem o RH marcou para reanálise também.
--  Grava o nível na análise, no candidato e no currículo atual, e tira a marca de revisão.
-- ════════════════════════════════════════════════════════════════════════

with alvo as (
  select c.id as candidato_id, c.analise_atual_id, a.curriculo_id
    from public.candidatos c
    join public.analises_ia a on a.id = c.analise_atual_id
   where c.revisao_manual
     and c.reanalise_solicitada_em is null
     and c.nivel_sugerido is null
     and c.area_sugerida is not null
     and c.cargo_sugerido is not null
     and a.motivo_revisao = 'A IA não classificou: nível'
),
analises as (
  update public.analises_ia a
     set nivel_sugerido = 'junior', revisao_manual = false, motivo_revisao = null
    from alvo where a.id = alvo.analise_atual_id
  returning a.id
),
curriculos as (
  update public.curriculos cu
     set nivel_funcao = 'junior'
    from alvo where cu.id = alvo.curriculo_id and cu.nivel_funcao is null
  returning cu.id
)
update public.candidatos c
   set nivel_sugerido = 'junior', revisao_manual = false
  from alvo where c.id = alvo.candidato_id;
