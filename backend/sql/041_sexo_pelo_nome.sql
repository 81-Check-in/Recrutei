-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — SEXO ESTIMADO PELO NOME (041)
--
--  Rodar depois da 040. Pode rodar de novo sem problema.
--
--  O currículo raramente traz o sexo, e a empresa quer comparar quantos currículos de mulheres e de homens chegam por mês e quantos
--  são contratados (relatório e comparação, NUNCA critério de seleção nem de eliminação). A IA passa a ESTIMAR o sexo pelo primeiro
--  nome de quem não informou, e o RH corrige à mão quando ela errar. Para os relatórios separarem o que é dado do que é estimativa:
--
--    • candidatos.sexo_origem — 'informado' (o currículo diz), 'ia_nome' (estimado pelo nome) ou 'manual' (o RH definiu ou corrigiu,
--      inclusive deixando em branco). O que o RH decidiu NUNCA é sobrescrito por uma estimativa da IA.
--    • editar_candidato() grava 'manual' quando o RH mexe no sexo.
--    • fn_candidato_carimbos() não conta a estimativa da IA como movimentação: o robô completando o cadastro não é um fato novo do
--      candidato e não pode adiar a sanitização (a atualização por um RH continua contando).
--    • vw_banco_talentos informa sexo_origem (coluna nova, no fim).
--
--  Quem já tinha sexo (vindo do currículo, ou de uma edição anterior do RH) fica como 'informado': o sistema não guardava a diferença.
-- ════════════════════════════════════════════════════════════════════════

alter table public.candidatos
  add column if not exists sexo_origem text check (sexo_origem in ('informado', 'ia_nome', 'manual'));
comment on column public.candidatos.sexo_origem is
  'De onde veio o sexo: informado (currículo), ia_nome (estimado pela IA pelo primeiro nome), manual (RH; vazio + manual = o RH deixou em branco de propósito). Só para relatório e comparação; nunca critério de seleção.';

-- quem já tinha sexo: veio do currículo (ou de uma edição do RH antes desta coluna)
update public.candidatos set sexo_origem = 'informado' where sexo is not null and sexo_origem is null;

-- ───────────────────────────────────────────────────────────────────────
--  1) A estimativa da IA não conta como movimentação do candidato
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_candidato_carimbos()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.updated_at := now();
  -- mudou algum dado do candidato: conta como atualização e como movimentação. O sexo ESTIMADO pela IA (041) não conta: é o
  -- robô completando o cadastro, não um fato novo do candidato, e não pode adiar a sanitização
  if (new.nome, case when new.sexo_origem = 'ia_nome' then old.sexo else new.sexo end, new.data_nascimento, new.idade_informada, new.cidade, new.uf, new.telefone,
      new.telefone_e164, new.email, new.escolaridade, new.anos_experiencia, new.cnh)
     is distinct from
     (old.nome, old.sexo, old.data_nascimento, old.idade_informada, old.cidade, old.uf, old.telefone,
      old.telefone_e164, old.email, old.escolaridade, old.anos_experiencia, old.cnh) then
    new.ultima_atualizacao := now();
    new.ultima_movimentacao := now();
  end if;
  return new;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  2) Editar candidato: mexer no sexo é decisão do RH
-- ───────────────────────────────────────────────────────────────────────
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
    -- o RH mexeu no sexo (inclusive deixando em branco): a decisão dele nunca é refeita pela estimativa da IA (041)
    sexo_origem      = case when p_dados ? 'sexo'             then 'manual' else c.sexo_origem end,
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
--  3) A view do banco informa de onde veio o sexo
--
--  Dentro de um DO (não um CREATE OR REPLACE VIEW direto): se esta migração for reaplicada depois de uma mais
--  nova que também estendeu a view (ex.: 052_historico_no_banco.sql), o Postgres recusa por tirar coluna do
--  fim ("cannot drop columns from view") — o deploy repete tudo, então isso pode acontecer. Cai fora só desse
--  erro específico (a migração mais nova prevalece, como deveria); qualquer outro erro continua estourando.
-- ───────────────────────────────────────────────────────────────────────
do $mig041_view$
begin
  execute $viewsql$
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
  c.sexo_origem
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
where c.status_banco <> 'expurgado';
  $viewsql$;
exception when others then
  if sqlerrm !~ 'cannot drop columns from view' then
    raise;
  end if;
  raise notice 'vw_banco_talentos já foi estendida por uma migração mais nova que 041 (ex.: 052) — mantida como está.';
end $mig041_view$;
