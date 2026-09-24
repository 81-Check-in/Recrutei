-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · E-MAIL DE ENVIO e DATA DO ENVIO no currículo
--
--  Rodar depois da 031. Pode rodar de novo sem problema.
--
--  Nem todo currículo é analisado pela IA por inteiro (o e-mail do candidato pode não estar no texto, ou a análise pode
--  falhar). O que vem do PRÓPRIO e-mail, não: por isso o endereço de quem enviou fica gravado no currículo, ao lado da
--  data do envio, e o painel passa a mostrar os dois.
--    • curriculos.email_envio  — o endereço que enviou o e-mail (cabeçalho From). Nulo em upload manual.
--    • curriculos.recebido_em  — a data do envio (cabeçalho Date). Já existia; só ganhou nome no painel.
-- ════════════════════════════════════════════════════════════════════════

alter table public.curriculos add column if not exists email_envio text;

comment on column public.curriculos.email_envio is
  'Endereço que enviou o e-mail com este currículo (cabeçalho From). Vem do e-mail, não da IA. Nulo em upload manual. É dado pessoal: sai no expurgo.';
comment on column public.curriculos.recebido_em is
  'Quando o e-mail com o currículo foi enviado (cabeçalho Date; sem o cabeçalho, quando o sistema o leu). Upload manual: quando foi enviado ao sistema.';

-- Currículos que já estão no banco: o endereço estava só em remetentes (remetente_id). Quem teve os dados excluídos fica de fora.
update public.curriculos c
   set email_envio = lower(r.email::text)
  from public.remetentes r, public.candidatos k
 where r.id = c.remetente_id
   and k.id = c.candidato_id and k.status_banco <> 'expurgado'
   and c.email_envio is null;

-- O expurgo (fn_expurgar_candidato) esvazia o texto do currículo. Junto com ele saem a classificação da IA (031) e o
-- e-mail de envio: nenhum dos dois pode sobrar. Substitui o gatilho da 031, que só cuidava da classificação.
create or replace function public.fn_curriculo_limpa_ao_expurgar()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.setor_adequado := null;
  new.funcao_setor   := null;
  new.nivel_funcao   := null;
  new.email_envio    := null;
  return new;
end $$;

drop trigger if exists trg_curriculo_limpa_qualificacao on public.curriculos;
drop trigger if exists trg_curriculo_limpa_ao_expurgar on public.curriculos;
create trigger trg_curriculo_limpa_ao_expurgar
  before update of texto_extraido on public.curriculos
  for each row
  when (new.texto_extraido is null and old.texto_extraido is not null)
  execute function public.fn_curriculo_limpa_ao_expurgar();
drop function if exists public.fn_curriculo_limpa_qualificacao();

-- A view do banco informa o e-mail de envio (coluna nova, sempre no fim; a data já era curriculo_recebido_em)
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
  cur.email_envio                                                                      as curriculo_email_envio
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
