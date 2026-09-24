-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · PASSO 6 de 6: migração dos dados existentes
--
--  O que faz (tudo em UMA transação: se qualquer verificação falhar, NADA muda):
--   1. Agrupa as candidaturas antigas por pessoa (hash de identidade; sem hash = uma pessoa por linha)
--      e cria um CANDIDATO por pessoa, com os dados pessoais da candidatura mais recente.
--   2. Liga cada candidatura ao seu candidato e move o currículo (arquivo, texto, e-mail de origem)
--      para o candidato. Se a pessoa mandou mais de um currículo, todos ficam como versões e o mais
--      recente vira o "atual".
--   3. Normaliza o histórico de candidaturas — nada é apagado:
--        recebido / em_analise / avaliado  → o vínculo era só sugestão automática da IA: vira "cancelado"
--                                            (origem "triagem_legada"); as avaliações continuam ligadas a ele
--        selecionado                       → aguardando
--        entrevista_* / aprovado / não compareceu → continuam como estão (candidato "em processo")
--        reprovado / contratado            → continuam, agora encerradas
--        descartado                        → cancelado; a pessoa vira "inativo" (o RH tinha descartado)
--   4. Cria uma análise inicial por candidato a partir da última avaliação (marcada "revisão manual")
--      e pede a nova análise da IA — o pipeline faz na próxima execução (python main.py --reanalisar).
--   5. Recalcula a situação de cada candidato no banco e finaliza restrições e índices.
--   6. Só então apaga dos registros antigos os dados pessoais que agora vivem em "candidatos".
--
--  ANTES DE RODAR:
--   • Faça backup (Supabase → Database → Backups) e PAUSE o cron da rotina no Railway.
--   • Rode 020 a 024 antes (este arquivo confere).
--   • Ensaie: cole BEGIN; + este arquivo sem o COMMIT final + ROLLBACK; (como foi feito na 016).
--   Pode rodar de novo: só toca candidaturas que ainda não têm candidato.
-- ════════════════════════════════════════════════════════════════════════

begin;

do $$
begin
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'status_candidatura' and e.enumlabel = 'aguardando')
     or to_regclass('public.candidatos') is null
     or to_regprocedure('public.fn_recalcular_status_banco(uuid,boolean)') is null
     or to_regclass('public.vw_banco_talentos') is null
     or to_regprocedure('public.fn_gerar_sugestoes_sanitizacao(text,boolean)') is null then
    raise exception 'Rode antes os arquivos 020 a 024, nesta ordem.';
  end if;
end $$;

-- fotografia do "antes", para conferir no fim que nada se perdeu
create temp table _mig_antes on commit drop as
select (select count(*) from public.candidaturas)  as candidaturas,
       (select count(*) from public.curriculos)    as curriculos,
       (select count(*) from public.avaliacoes)    as avaliacoes,
       (select count(*) from public.entrevistas)   as entrevistas,
       (select count(*) from public.candidaturas where candidato_id is null) as a_migrar;

-- Durante a migração os gatilhos de negócio ficam desligados (eles recalculariam datas e situação a cada
-- linha); a situação é recalculada de uma vez no passo 5. Voltam a ligar antes do COMMIT.
alter table public.candidaturas disable trigger trg_candidatura_sincroniza_banco;
alter table public.candidaturas disable trigger trg_candidatura_carimbos;
alter table public.candidaturas disable trigger trg_cand_auditoria;
alter table public.candidaturas disable trigger trg_candidaturas_updated_at;

-- ───────────────────────────────────────────────────────────────────────
--  1. Uma pessoa = um candidato
-- ───────────────────────────────────────────────────────────────────────
create temp table _mig_cand_ids on commit drop as
select id from public.candidaturas where candidato_id is null;

create temp table _mig_grupos on commit drop as
select coalesce(ca.hash_identidade, 'sem-hash:' || ca.id::text)                                as chave,
       -- dados pessoais vêm da candidatura mais recente que ainda os tem
       (array_agg(ca.id order by (ca.dados_pessoais is not null) desc, ca.recebido_em desc, ca.id))[1] as mestre_id,
       min(ca.recebido_em)                                                                     as primeira,
       max(ca.recebido_em)                                                                     as ultima,
       max(ca.data_ultimo_evento)                                                              as ultimo_evento,
       bool_or(ca.status_registro = 'ativo')                                                   as tem_ativo,
       bool_and(ca.status_registro = 'expurgado')                                              as todos_expurgados,
       min(ca.inativado_em)                                                                    as inativado_em,
       max(ca.expurgado_em)                                                                    as expurgado_em,
       bool_or(ca.retencao_permanente)                                                         as retencao_permanente
  from public.candidaturas ca
 where ca.candidato_id is null
 group by 1;

-- quem já existe como candidato (mesmo hash) é reaproveitado; os demais recebem um id novo
create temp table _mig_map (chave text primary key, candidato_id uuid not null, novo boolean not null) on commit drop;
insert into _mig_map
select distinct on (g.chave) g.chave, c.id, false
  from _mig_grupos g join public.candidatos c on c.hash_identidade = g.chave
 order by g.chave, c.data_entrada;
insert into _mig_map
select g.chave, gen_random_uuid(), true from _mig_grupos g
 where not exists (select 1 from _mig_map m where m.chave = g.chave);

create function pg_temp.uf_valida(t text) returns text language sql immutable as $$
  select case when upper(t) in ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR',
                                'PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO') then upper(t) end
$$;

insert into public.candidatos
  (id, nome, sexo, idade_informada, idade_informada_em, cidade, uf, telefone, telefone_e164, email,
   escolaridade, anos_experiencia, cnh, hash_identidade, status_banco, origem_entrada,
   data_entrada, ultima_atualizacao, ultima_movimentacao, inativado_em, motivo_inativacao, expurgado_em, retencao_permanente)
select m.candidato_id,
       nullif(btrim(d.dp ->> 'nome'), ''),
       case when d.dp ->> 'sexo' in ('masculino', 'feminino') then d.dp ->> 'sexo' end,
       case when d.dp ->> 'idade' ~ '^[0-9]{1,3}$' and (d.dp ->> 'idade')::int between 14 and 85
            then (d.dp ->> 'idade')::smallint end,
       case when d.dp ->> 'idade' ~ '^[0-9]{1,3}$' and (d.dp ->> 'idade')::int between 14 and 85
            then mestre.recebido_em::date end,           -- a idade foi lida do currículo nesta data
       loc.cidade, loc.uf,
       nullif(btrim(d.dp ->> 'telefone'), ''),
       nullif(btrim(d.dp ->> 'telefone_e164'), ''),
       nullif(lower(btrim(d.dp ->> 'email')), ''),
       case when d.dp ->> 'escolaridade' in ('nenhuma', 'fundamental', 'medio', 'tecnico', 'superior', 'pos')
            then d.dp ->> 'escolaridade' end,
       case when d.dp ->> 'anos_experiencia' ~ '^[0-9]{1,3}(\.[0-9])?[0-9]*$'
            then least((d.dp ->> 'anos_experiencia')::numeric, 99.9)::numeric(4, 1) end,
       nullif(upper(btrim(d.dp ->> 'cnh')), ''),
       case when g.chave like 'sem-hash:%' then null else g.chave end,
       case when g.todos_expurgados then 'expurgado'
            when g.tem_ativo        then 'ativo'
            else 'inativo' end::public.status_banco_talentos,
       'migracao',
       g.primeira, g.ultima, greatest(g.ultima, g.ultimo_evento),
       case when g.todos_expurgados or not g.tem_ativo then coalesce(g.inativado_em, g.expurgado_em, now()) end,
       case when g.todos_expurgados then 'dados excluídos pela retenção automática anterior'
            when not g.tem_ativo    then 'Inativado pela retenção automática anterior' end,
       case when g.todos_expurgados then coalesce(g.expurgado_em, now()) end,
       g.retencao_permanente
  from _mig_map m
  join _mig_grupos g on g.chave = m.chave
  join public.candidaturas mestre on mestre.id = g.mestre_id
  cross join lateral (select case when g.todos_expurgados then '{}'::jsonb else coalesce(mestre.dados_pessoais, '{}'::jsonb) end as dp) d
  cross join lateral (
    select case when pg_temp.uf_valida(substring(d.dp ->> 'cidade' from '[/,–-]\s*([A-Za-z]{2})\s*$')) is not null
                then nullif(btrim(substring(d.dp ->> 'cidade' from '^(.*?)\s*[/,–-]\s*[A-Za-z]{2}\s*$')), '')
                else nullif(btrim(d.dp ->> 'cidade'), '') end                                as cidade,
           pg_temp.uf_valida(substring(d.dp ->> 'cidade' from '[/,–-]\s*([A-Za-z]{2})\s*$')) as uf
  ) loc
 where m.novo;

-- ───────────────────────────────────────────────────────────────────────
--  2. Candidaturas e currículos passam a apontar para o candidato
-- ───────────────────────────────────────────────────────────────────────
update public.candidaturas ca
   set candidato_id = m.candidato_id
  from _mig_map m
 where ca.candidato_id is null
   and coalesce(ca.hash_identidade, 'sem-hash:' || ca.id::text) = m.chave;

-- currículos: o e-mail de origem sai da candidatura e vai para o currículo
update public.curriculos cu
   set atual = false
 where cu.candidato_id is null;          -- (a unicidade "um atual por candidato" só vale para quem já tem candidato)
update public.curriculos cu
   set candidato_id     = ca.candidato_id,
       remetente_id     = ca.remetente_id,
       email_message_id = ca.email_message_id,
       email_assunto    = ca.email_assunto,
       recebido_em      = ca.recebido_em
  from public.candidaturas ca
 where ca.id = cu.candidatura_id and cu.candidato_id is null;

-- o currículo "atual" de cada candidato: o mais recente que ainda tem conteúdo (senão, o mais recente)
update public.curriculos cu
   set atual = true
  from (select distinct on (c.candidato_id) c.id
          from public.curriculos c
         where c.candidato_id in (select candidato_id from _mig_map)
           and not exists (select 1 from public.curriculos x where x.candidato_id = c.candidato_id and x.atual)
         order by c.candidato_id,
                  (c.texto_extraido is not null or c.storage_path is not null) desc,
                  c.recebido_em desc, c.id) pick
 where cu.id = pick.id;

-- ───────────────────────────────────────────────────────────────────────
--  3. Histórico de candidaturas: status novos, sem apagar nada
-- ───────────────────────────────────────────────────────────────────────
-- 3a. triagem antiga: o vínculo era escolha automática da IA, nunca decisão do RH → fechado como histórico
update public.candidaturas
   set status = 'cancelado', origem = 'triagem_legada', encerrada_em = now(), avaliacao_pendente = false,
       resultado_final = 'Vínculo automático da triagem anterior, desfeito na migração para o Banco de Talentos (a avaliação da IA foi preservada).'
 where id in (select id from _mig_cand_ids) and status in ('recebido', 'em_analise', 'avaliado');

-- 3b. descartado pelo RH: encerrada; a pessoa fica "inativa" (ver 4)
update public.candidaturas
   set status = 'cancelado',
       origem = case when selecionado_em is not null then 'atribuicao_manual' else 'triagem_legada' end,
       encerrada_em = coalesce(descartado_em, now()),
       resultado_final = 'Descartado pelo RH' || coalesce(': ' || nullif(btrim(motivo_descarte), ''), '')
 where id in (select id from _mig_cand_ids) and status = 'descartado';

-- 3c. selecionado passa a se chamar aguardando
update public.candidaturas set status = 'aguardando'
 where id in (select id from _mig_cand_ids) and status = 'selecionado';

-- 3d. decisões do RH mantêm quem atribuiu e quando
update public.candidaturas
   set data_atribuicao = coalesce(selecionado_em, recebido_em),
       atribuido_por   = selecionado_por
 where id in (select id from _mig_cand_ids) and origem = 'atribuicao_manual';

-- 3e. reprovado / contratado: continuam, agora encerradas
update public.candidaturas
   set encerrada_em    = coalesce(encerrada_em, data_ultimo_evento, now()),
       resultado_final = coalesce(resultado_final, case status when 'reprovado' then 'Reprovado' else 'Contratado' end)
 where id in (select id from _mig_cand_ids) and status in ('reprovado', 'contratado');

-- o modelo novo permite UMA candidatura aberta por candidato: confere antes de criar o índice
do $$
declare r record;
begin
  for r in select candidato_id, count(*) n from public.candidaturas
            where encerrada_em is null group by 1 having count(*) > 1 loop
    raise exception 'O candidato % tem % candidaturas abertas ao mesmo tempo (o modelo novo permite uma). Encerre uma delas e rode de novo.',
      r.candidato_id, r.n;
  end loop;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  4. Situação de cada candidato no banco
-- ───────────────────────────────────────────────────────────────────────
-- 4a. o RH tinha descartado o currículo: continua fora da lista de disponíveis
update public.candidatos c
   set status_banco = 'inativo', inativado_em = coalesce(c.inativado_em, now()),
       motivo_inativacao = 'Descartado pelo RH na triagem anterior'
 where c.status_banco = 'ativo'
   and c.id in (select candidato_id from _mig_map)
   and exists (select 1 from public.candidaturas ca where ca.candidato_id = c.id and ca.descartado_em is not null);

-- 4b. contratado: sai do banco e não entra na sanitização
update public.candidatos c
   set status_banco = 'inativo', retencao_permanente = true, inativado_em = coalesce(c.inativado_em, now()),
       motivo_inativacao = 'contratado'
 where c.status_banco <> 'expurgado'
   and c.id in (select candidato_id from _mig_map)
   and exists (select 1 from public.candidaturas ca where ca.candidato_id = c.id and ca.status = 'contratado');

-- 4c. candidatura aberta = em processo
update public.candidatos c
   set status_banco = 'em_processo'
 where c.status_banco <> 'expurgado'
   and c.id in (select candidato_id from _mig_map)
   and exists (select 1 from public.candidaturas ca where ca.candidato_id = c.id and ca.encerrada_em is null);

-- 4d. última movimentação = a mais recente entre as candidaturas do candidato
update public.candidatos c
   set ultima_movimentacao = greatest(c.ultima_movimentacao,
         coalesce((select max(greatest(ca.data_ultimo_evento, ca.recebido_em))
                     from public.candidaturas ca where ca.candidato_id = c.id), c.ultima_movimentacao))
 where c.id in (select candidato_id from _mig_map);

-- ───────────────────────────────────────────────────────────────────────
--  5. Análise inicial (a partir da última avaliação por vaga) + pedido da análise nova
-- ───────────────────────────────────────────────────────────────────────
-- A vaga que o classificador antigo escolheu indica a ÁREA; cargo e nível ficam em branco. Tudo entra como
-- "revisão manual" até a IA refazer a análise (o pedido de reanálise é gravado logo abaixo).
insert into public.analises_ia
  (candidato_id, sequencia, pontos_positivos, pontos_negativos, area_sugerida, cargo_sugerido, nivel_sugerido,
   confianca, revisao_manual, motivo_revisao, texto_resumo_ia, data_analise, versao_modelo_ia, origem)
select distinct on (ca.candidato_id)
       ca.candidato_id, 1, av.pontos_fortes, av.lacunas, s.nome, null, null,
       null, true, 'Análise migrada da avaliação por vaga do modelo antigo; aguardando a nova análise da IA.',
       av.resumo_ia, av.created_at, 'legado-avaliacao:' || av.modelo_ia, 'migracao'
  from public.avaliacoes av
  join public.candidaturas ca on ca.id = av.candidatura_id
  join public.candidatos c on c.id = ca.candidato_id and c.status_banco <> 'expurgado'
  left join public.vagas v on v.id = ca.vaga_id
  left join public.setores s on s.id = v.setor_id
 where ca.candidato_id in (select candidato_id from _mig_map)
   and not exists (select 1 from public.analises_ia x where x.candidato_id = ca.candidato_id)
 order by ca.candidato_id, av.created_at desc, av.sequencia desc;

-- (o gatilho da análise mexeu em ultima_atualizacao/reanalise; acerta as datas e pede a análise nova)
update public.candidatos c
   set ultima_atualizacao = g.ultima,
       reanalise_solicitada_em = case when exists (select 1 from public.curriculos cu
                                                    where cu.candidato_id = c.id and cu.atual and cu.texto_extraido is not null)
                                      then now() end
  from _mig_map m join _mig_grupos g on g.chave = m.chave
 where c.id = m.candidato_id and m.novo and c.status_banco <> 'expurgado';

update public.uploads_manuais u
   set candidato_gerado_id = ca.candidato_id
  from public.candidaturas ca
 where ca.id = u.candidatura_gerada_id and u.candidato_gerado_id is null;

-- ───────────────────────────────────────────────────────────────────────
--  6. Restrições e índices do modelo novo; dados pessoais saem dos registros antigos
-- ───────────────────────────────────────────────────────────────────────
alter table public.candidaturas alter column candidato_id set not null;
alter table public.curriculos   alter column candidato_id set not null;

create unique index if not exists uq_candidatura_aberta_por_candidato
  on public.candidaturas (candidato_id) where encerrada_em is null;

-- Já migrados os dados pessoais, o registro antigo não os guarda mais (evita duas cópias — LGPD).
-- O hash e o e-mail de origem estão em candidatos/curriculos.
update public.candidaturas
   set dados_pessoais = null, email_assunto = null, email_message_id = null, hash_identidade = null
 where id in (select id from _mig_cand_ids);

-- índices do modelo antigo (retenção por tempo, hash e e-mail na candidatura, JSON de dados pessoais)
drop index if exists public.idx_cand_dados_pessoais;
drop index if exists public.idx_cand_expurgo;
drop index if exists public.idx_cand_retencao;
drop index if exists public.idx_cand_hash_identidade;
drop index if exists public.idx_cand_message_id;

alter table public.candidaturas enable trigger trg_candidatura_sincroniza_banco;
alter table public.candidaturas enable trigger trg_candidatura_carimbos;
alter table public.candidaturas enable trigger trg_cand_auditoria;
alter table public.candidaturas enable trigger trg_candidaturas_updated_at;

-- Verificação que sempre aborta a transação (não depende do parâmetro plpgsql.check_asserts)
create function pg_temp.exige(ok boolean, msg text) returns void language plpgsql as $$
begin
  if ok is not true then
    raise exception 'MIGRAÇÃO ABORTADA — verificação falhou: %', msg;
  end if;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Verificações: qualquer falha aborta a transação inteira
-- ───────────────────────────────────────────────────────────────────────
do $$
declare
  a record;
  v_aguardando int;
  resumo text;
begin
  select * into a from _mig_antes;

  perform pg_temp.exige((select count(*) from public.candidaturas) = a.candidaturas, 'o total de candidaturas mudou');
  perform pg_temp.exige((select count(*) from public.curriculos)   = a.curriculos,   'o total de currículos mudou');
  perform pg_temp.exige((select count(*) from public.avaliacoes)   = a.avaliacoes,   'o total de avaliações mudou (nada pode ser apagado)');
  perform pg_temp.exige((select count(*) from public.entrevistas)  = a.entrevistas,  'o total de entrevistas mudou');

  perform pg_temp.exige((select count(*) from public.candidaturas where candidato_id is null) = 0, 'sobrou candidatura sem candidato');
  perform pg_temp.exige((select count(*) from public.curriculos   where candidato_id is null) = 0, 'sobrou currículo sem candidato');
  perform pg_temp.exige((select count(*) from public.candidaturas where dados_pessoais is not null) = 0, 'sobrou dado pessoal na candidatura');

  -- um currículo atual por candidato que tem currículo (e no máximo um sempre)
  perform pg_temp.exige(not exists (select 1 from public.curriculos where atual group by candidato_id having count(*) > 1),
    'candidato com mais de um currículo atual');
  perform pg_temp.exige(not exists (select 1 from public.candidatos c
                      where c.status_banco <> 'expurgado'
                        and exists (select 1 from public.curriculos x where x.candidato_id = c.id)
                        and not exists (select 1 from public.curriculos x where x.candidato_id = c.id and x.atual)),
    'candidato com currículo mas sem currículo atual');

  -- em_processo <=> tem candidatura aberta
  perform pg_temp.exige(not exists (select 1 from public.candidatos c
                      where c.status_banco = 'em_processo'
                        and not exists (select 1 from public.candidaturas ca where ca.candidato_id = c.id and ca.encerrada_em is null)),
    'candidato em processo sem candidatura aberta');
  perform pg_temp.exige(not exists (select 1 from public.candidatos c
                      where c.status_banco in ('ativo', 'inativo')
                        and exists (select 1 from public.candidaturas ca where ca.candidato_id = c.id and ca.encerrada_em is null)),
    'candidato com candidatura aberta fora de "em processo"');

  -- toda candidatura encerrada tem data e resultado; toda aberta não tem
  perform pg_temp.exige(not exists (select 1 from public.candidaturas
                      where (status in ('reprovado', 'cancelado', 'descartado', 'contratado')) <> (encerrada_em is not null)),
    'encerrada_em inconsistente com o status');
  perform pg_temp.exige(not exists (select 1 from public.candidaturas where encerrada_em is not null and resultado_final is null),
    'candidatura encerrada sem resultado_final');

  -- expurgado não guarda dado pessoal
  perform pg_temp.exige(not exists (select 1 from public.candidatos
                      where status_banco = 'expurgado' and (nome is not null or email is not null or telefone is not null)),
    'candidato expurgado com dado pessoal');

  -- as entrevistas continuam ligadas a candidaturas que sobreviveram
  perform pg_temp.exige(not exists (select 1 from public.entrevistas e where not exists (select 1 from public.candidaturas c where c.id = e.candidatura_id)),
    'entrevista órfã');

  -- resumo para conferir a olho
  select string_agg(x.situacao || '=' || x.qtd, ', ' order by x.situacao) into resumo
    from (select status_banco::text as situacao, count(*) as qtd from public.candidatos group by 1) x;
  raise notice 'Candidatos por situação: %', resumo;
  select string_agg(x.situacao || '=' || x.qtd, ', ' order by x.situacao) into resumo
    from (select status::text as situacao, count(*) as qtd from public.candidaturas group by 1) x;
  raise notice 'Candidaturas por status: %', resumo;
  select count(*) into v_aguardando from public.candidatos where reanalise_solicitada_em is not null;
  raise notice 'Candidatos aguardando a nova análise da IA: % (rode: python main.py --reanalisar)', v_aguardando;
end $$;

select public.fn_registra_auditoria(
  'atualizacao', 'candidatos', null, null,
  jsonb_build_object('candidatos', (select count(*) from _mig_map), 'candidaturas', (select a_migrar from _mig_antes)),
  'Migração dos dados para o Banco de Talentos (passo 025)');

commit;
