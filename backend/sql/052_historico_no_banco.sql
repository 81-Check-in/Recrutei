-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Histórico do candidato aparece no Banco de Talentos (052)
--
--  Rodar depois da 051. Pode rodar de novo sem problema.
--
--  Quem já passou pelo RH antes (entrevista, "não veio", "sem interesse"...) tem isso registrado em
--  historico_candidatos (042). Mas os 10.504 registros importados da planilha antiga (origem 'planilha') não
--  têm candidato_id — só nome e telefone foram copiados. Por isso o casamento usa OS DOIS jeitos:
--
--    • candidato_id igual — o jeito exato; é o que as linhas novas ('sistema', criadas pelo gatilho da 042
--      quando o RH registra o resultado de uma entrevista) sempre têm.
--    • nome OU telefone batendo — para as linhas antigas da planilha, sem candidato_id. Nome comparado já
--      normalizado (nome_norm, sem acento/maiúscula, o mesmo padrão usado na busca do banco). Telefone só pelos
--      dígitos, com um contendo o outro (fn_telefones_batem): o telefone muda com frequência e o "55" na frente
--      às vezes está de um lado só — exigir os dois (nome E telefone) perderia muita gente; só nome OU só
--      telefone já é considerado o bastante.
--
--  vw_banco_talentos ganha total_historico (quantas linhas batem, sempre no fim: é o que o CREATE OR REPLACE
--  VIEW permite) para o aviso no card. Ao clicar, o painel chama historico_do_candidato() — mesma regra de
--  casamento — para mostrar o histórico completo num popup, sem passar pela tela Histórico do candidato.
--
--  "Mais filtros" ganha "Com passagem pelo RH" (total_historico > 0), com a mesma regra de casamento — no Banco
--  de Talentos normal e em "Selecionar CVs" por vaga (fn_bate_colunas_avancadas, 049, redefinida aqui).
-- ════════════════════════════════════════════════════════════════════════

-- Índice comum (o nome_norm já tem um GIN de trigrama, para busca parcial; este é para achar o igual, rápido)
create index if not exists idx_historico_nome_norm_igual on public.historico_candidatos (nome_norm);

-- p_a e p_b: só dígitos (regexp_replace(..., '\D', '', 'g') já aplicado por quem chama). Um contendo o outro
-- cobre o "55" (DDI) que às vezes está de um lado só; o mínimo de 8 dígitos evita bater com lixo/vazio.
create or replace function public.fn_telefones_batem(p_a text, p_b text)
returns boolean
language sql immutable parallel safe
set search_path to ''
as $$
  select length(p_a) >= 8 and length(p_b) >= 8
     and (position(p_a in p_b) > 0 or position(p_b in p_a) > 0)
$$;

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
  c.regiao_id, rg.nome                                                                 as regiao_nome, c.regiao_origem, c.bairro,
  -- e-mail que enviou o currículo atual (032)
  cur.email_envio                                                                      as curriculo_email_envio,
  -- de onde veio o sexo: informado no currículo, estimado pela IA pelo nome, ou definido pelo RH (041)
  c.sexo_origem,
  -- já passou pelo RH antes (042): quantas linhas do Histórico do candidato batem com ele (052)
  coalesce(ht.total_historico, 0)                                                      as total_historico
from public.candidatos c
left join public.analises_ia a on a.id = c.analise_atual_id
left join public.regioes_df rg on rg.id = c.regiao_id
left join lateral (
  select cu.id, cu.storage_path, cu.nome_arquivo, cu.origem, cu.recebido_em, cu.email_envio
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
left join lateral (
  select regexp_replace(coalesce(c.telefone_e164, ''), '\D', '', 'g') as e164,
         regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g')      as simples
) cd on true
left join lateral (
  select count(*) as total_historico
    from public.historico_candidatos hh
   where hh.candidato_id = c.id
      or hh.nome_norm = c.nome_norm
      or public.fn_telefones_batem(hh.telefone_digitos, cd.e164)
      or public.fn_telefones_batem(hh.telefone_digitos, cd.simples)
) ht on true
where c.status_banco <> 'expurgado';

-- ───────────────────────────────────────────────────────────────────────
--  O popup do Banco de Talentos: o histórico completo de um candidato, pela mesma regra de casamento
--  (candidato_id, ou nome, ou telefone). O painel só chama esta função — não filtra vw_historico_candidatos
--  por candidato_id direto, porque isso perderia toda a planilha importada (sem candidato_id).
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.historico_do_candidato(p_candidato_id uuid)
returns setof public.vw_historico_candidatos
language sql stable
set search_path to 'public'
as $$
  with cand as (
    select nome_norm,
           regexp_replace(coalesce(telefone_e164, ''), '\D', '', 'g') as e164,
           regexp_replace(coalesce(telefone, ''), '\D', '', 'g')      as simples
      from public.candidatos where id = p_candidato_id
  )
  select h.*
    from public.vw_historico_candidatos h, cand
   where h.candidato_id = p_candidato_id
      or h.nome_norm = cand.nome_norm
      or public.fn_telefones_batem(h.telefone_digitos, cand.e164)
      or public.fn_telefones_batem(h.telefone_digitos, cand.simples)
   order by h.data_evento desc, h.criado_em desc
$$;

revoke execute on function public.fn_telefones_batem(text, text), public.historico_do_candidato(uuid)
  from public, anon;
grant execute on function public.fn_telefones_batem(text, text), public.historico_do_candidato(uuid)
  to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────
--  "Mais filtros" ganha "Com passagem pelo RH" — no Banco de Talentos normal, o PostgREST filtra total_historico
--  > 0 direto (banco-talentos.js); em "Selecionar CVs" (por vaga) não há essa consulta para encadear em cima,
--  então fn_bate_colunas_avancadas (049) ganha a mesma checagem, redefinida aqui com "tem_historico" a mais
--  (o resto é o mesmo da 049 — git blame se um dia divergir).
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_bate_colunas_avancadas(p_candidato_id uuid, colunas jsonb default '{}'::jsonb)
returns boolean
language sql stable
set search_path to 'public'
as $$
  with c as (
    select coalesce((colunas ->> 'incluir_sem_info')::boolean, true)      as sem,
           nullif(colunas ->> 'idade_min', '')::int                       as idade_min,
           nullif(colunas ->> 'idade_max', '')::int                       as idade_max,
           nullif(colunas ->> 'escolaridade_min', '')                     as escolaridade_min,
           nullif(colunas ->> 'experiencia_min', '')::numeric             as experiencia_min,
           coalesce((colunas ->> 'revisao')::boolean, false)              as revisao,
           coalesce((colunas ->> 'tem_historico')::boolean, false)        as tem_historico
  ),
  k as (select * from public.candidatos where id = p_candidato_id)
  select
    -- idade: as duas pontas (quando informadas) valem juntas; "incluir sem info" deixa passar nascimento_ref nulo.
    -- Todo o "ou" fica entre parênteses: sem isso, o "e" dos filtros seguintes (precedência maior que "ou" em SQL)
    -- grudaria só no último ramo, e qualquer chamada sem filtro de idade (o caso comum) deixaria passar todo mundo,
    -- ignorando escolaridade/experiência/CNH/revisão.
    (
      (c.idade_min is null and c.idade_max is null)
      or (c.sem and k.nascimento_ref is null)
      or (
        (c.idade_min is null or k.nascimento_ref <= current_date - (c.idade_min::text || ' years')::interval)
        and
        (c.idade_max is null or k.nascimento_ref >= current_date - ((c.idade_max + 1)::text || ' years')::interval + interval '1 day')
      )
    )
  and (
    c.escolaridade_min is null
    or (c.sem and k.escolaridade_ord is null)
    or k.escolaridade_ord >= case c.escolaridade_min
         when 'fundamental' then 1 when 'medio' then 2 when 'tecnico' then 3 when 'superior' then 4 when 'pos' then 5 else 0 end
  )
  and (
    c.experiencia_min is null
    or (c.sem and k.anos_experiencia is null)
    or k.anos_experiencia >= c.experiencia_min
  )
  and (not c.revisao or k.revisao_manual)
  and (
    not c.tem_historico
    or exists (
      select 1 from public.historico_candidatos hh
       where hh.candidato_id = k.id
          or hh.nome_norm = k.nome_norm
          or public.fn_telefones_batem(hh.telefone_digitos, regexp_replace(coalesce(k.telefone_e164, ''), '\D', '', 'g'))
          or public.fn_telefones_batem(hh.telefone_digitos, regexp_replace(coalesce(k.telefone, ''), '\D', '', 'g'))
    )
  )
  from c, k
$$;
