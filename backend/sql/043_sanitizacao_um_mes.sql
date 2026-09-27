-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Sanitização: sugerida 1 mês depois da entrada, e botão "Sanitizar" no cadastro
--
--  1) PRAZO. Ninguém entra na lista de sugestões antes de passar 1 mês SEM NENHUMA ALTERAÇÃO. O relógio começa
--     na data em que o candidato ENTROU NO SISTEMA (candidatos.ultima_movimentacao nasce igual a data_entrada, que é
--     o momento da gravação — nunca a data do e-mail). E-mail de agosto que chegou ao sistema em outubro é sugerido
--     em novembro. Qualquer alteração (candidatura, currículo novo, contato, edição) reinicia a contagem.
--     Este prazo é um PORTÃO: os demais motivos (reprovações, dados incompletos, duplicidade…) só valem para quem já
--     passou por ele e servem para somar pontos/prioridade. Antes, "dados incompletos" sugeria o candidato no dia
--     em que ele entrava. A única exceção é o prazo máximo de armazenamento (LGPD, 24 meses), que é limite legal.
--  2) CONFERÊNCIA SEMANAL. A lista é montada toda semana (parâmetro sanitizacao_intervalo_dias, 7; antes: de 2 em 2 meses),
--     então o candidato que completa 1 mês é sugerido na primeira conferência depois disso (até 6 dias de espera).
--  3) BOTÃO "SANITIZAR". O RH manda um candidato direto para a fila (sanitizacao_enviar_candidato), com prioridade
--     alta; lá a decisão é a de sempre (manter, inativar; excluir só administrador). Substitui o "Excluir dados".
--
--  Pode rodar de novo sem problema.
-- ════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
--  Parâmetros
-- ───────────────────────────────────────────────────────────────────────
insert into public.configuracoes (chave, valor, descricao) values
  ('sanitizacao_intervalo_dias', to_jsonb(7),
   'Sanitização: de quantos em quantos dias o sistema confere quem já venceu o prazo e monta a lista de sugestões. 7 = toda semana (1 = todo dia).')
on conflict (chave) do nothing;
delete from public.configuracoes where chave = 'sanitizacao_intervalo_meses';

update public.configuracoes
   set valor = to_jsonb(1),
       descricao = 'Sanitização: só é sugerido quem ficou N meses sem nenhuma alteração (candidatura, novo currículo, contato, edição), contados da entrada no sistema. Vale para todos os motivos, menos o prazo máximo de armazenamento.'
 where chave = 'sanitizacao_meses_sem_movimentacao';

create or replace function public.fn_sanitizacao_parametros()
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'intervalo_dias',           greatest(1, public.fn_config_numero('sanitizacao_intervalo_dias', 7)::int),
    'meses_sem_movimentacao',   public.fn_config_numero('sanitizacao_meses_sem_movimentacao', 1)::int,
    'reprovacoes_max',          public.fn_config_numero('sanitizacao_reprovacoes_max', 3)::int,
    'aderencia_min',            public.fn_config_numero('sanitizacao_aderencia_min', 40)::int,
    'confianca_min',            public.fn_config_numero('sanitizacao_confianca_min', 50)::int,
    'detectar_duplicidade',     coalesce((select (valor #>> '{}')::boolean from public.configuracoes
                                           where chave = 'sanitizacao_detectar_duplicidade'), true),
    'retencao_maxima_meses',    public.fn_config_numero('sanitizacao_retencao_maxima_meses', 24)::int,
    'adiar_meses',              public.fn_config_numero('sanitizacao_adiar_meses', 6)::int,
    'pesos', '{"sem_movimentacao":2,"reprovacoes":2,"baixa_aderencia":1,"dados_incompletos":2,"duplicidade":3,"prazo_retencao":4,"limite_alta":4,"limite_media":2}'::jsonb
             || coalesce((select case when jsonb_typeof(valor) = 'object' then valor end
                            from public.configuracoes where chave = 'sanitizacao_pesos'), '{}'::jsonb)
  );
$$;

-- ───────────────────────────────────────────────────────────────────────
--  Sugestões que não vêm de um ciclo: as enviadas pelo RH (botão "Sanitizar")
-- ───────────────────────────────────────────────────────────────────────
alter table public.sanitizacao_sugestoes alter column ciclo_id drop not null;
alter table public.sanitizacao_sugestoes add column if not exists origem text not null default 'automatica';
alter table public.sanitizacao_sugestoes add column if not exists enviada_por uuid references public.usuarios(id) on delete set null;

alter table public.sanitizacao_sugestoes drop constraint if exists chk_sugestao_origem;
alter table public.sanitizacao_sugestoes add constraint chk_sugestao_origem
  check (origem in ('automatica', 'manual') and (origem = 'manual' or ciclo_id is not null));

create index if not exists idx_sugestoes_enviada_por
  on public.sanitizacao_sugestoes (enviada_por) where enviada_por is not null;

comment on column public.sanitizacao_sugestoes.origem is
  'automatica = montada pela rotina (tem ciclo); manual = o RH mandou pelo botão Sanitizar no cadastro (sem ciclo).';

-- A fila mostra as duas origens (o ciclo passou a ser opcional)
create or replace view public.vw_sanitizacao_sugestoes with (security_invoker = true) as
select
  sg.id, sg.ciclo_id, coalesce(ci.gerada_em, sg.created_at) as gerada_em, coalesce(ci.origem, 'manual') as ciclo_origem,
  sg.candidato_id, k.nome, k.cidade, k.uf, k.area_sugerida, k.cargo_sugerido, k.nivel_sugerido,
  k.status_banco, k.data_entrada,
  sg.motivos, sg.motivo_texto, sg.pontos, sg.prioridade, sg.ultima_movimentacao,
  sg.status, sg.decidido_por, public.fn_nome_usuario(sg.decidido_por) as decidido_por_nome,
  sg.decidido_em, sg.observacao, sg.adiada_ate,
  sg.origem as sugestao_origem, sg.enviada_por, public.fn_nome_usuario(sg.enviada_por) as enviada_por_nome
from public.sanitizacao_sugestoes sg
left join public.sanitizacao_ciclos ci on ci.id = sg.ciclo_id
left join public.candidatos k on k.id = sg.candidato_id;

-- ───────────────────────────────────────────────────────────────────────
--  Cálculo das sugestões — é a função da 031, com o PORTÃO de 1 mês no "base"
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_sanitizacao_avaliar(p_params jsonb)
returns table (
  candidato_id        uuid,
  motivos             text[],
  motivo_texto        text,
  pontos              integer,
  prioridade          text,
  ultima_movimentacao timestamptz
)
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_mov     int     := (p_params ->> 'meses_sem_movimentacao')::int;
  v_reprov  int     := (p_params ->> 'reprovacoes_max')::int;
  v_ader    int     := (p_params ->> 'aderencia_min')::int;
  v_conf    int     := (p_params ->> 'confianca_min')::int;
  v_dup     boolean := (p_params ->> 'detectar_duplicidade')::boolean;
  v_ret     int     := (p_params ->> 'retencao_maxima_meses')::int;
  w         jsonb   := p_params -> 'pesos';
begin
  return query
  with base as (
    select c.*
      from public.candidatos c
     where c.status_banco in ('ativo', 'inativo')
       and not c.retencao_permanente
       and (c.sanitizacao_adiada_ate is null or c.sanitizacao_adiada_ate <= now())
       -- PORTÃO: só passa quem ficou o prazo todo sem alteração (contado da entrada no sistema, pois
       -- ultima_movimentacao nasce igual a data_entrada) — ou quem estourou o prazo legal de armazenamento.
       -- Fica aqui, antes dos cálculos caros, para eles rodarem só para quem realmente vence.
       and (c.ultima_movimentacao < now() - make_interval(months => v_mov)
            or coalesce(c.consentimento_em, c.data_entrada) < now() - make_interval(months => v_ret))
       and not exists (select 1 from public.sanitizacao_sugestoes s
                        where s.candidato_id = c.id and s.status = 'pendente')
  ),
  hist as (
    select b.id,
           count(distinct ca.vaga_id) filter (where ca.status = 'reprovado')             as vagas_reprovado,
           coalesce(bool_or(ca.status in ('aprovado', 'contratado')), false)              as tem_aprovacao
      from base b left join public.candidaturas ca on ca.candidato_id = b.id
     group by b.id
  ),
  notas as (
    select b.id, max(av.nota) as nota_max
      from base b
      join public.candidaturas ca on ca.candidato_id = b.id
      join public.avaliacoes av on av.candidatura_id = ca.id
     group by b.id
  ),
  sinais as (
    select b.id,
           b.ultima_movimentacao                                                          as ult_mov,
           (b.ultima_movimentacao < now() - make_interval(months => v_mov))               as f_mov,
           (coalesce(h.vagas_reprovado, 0) >= v_reprov and not h.tem_aprovacao)           as f_reprov,
           (n.nota_max is not null and n.nota_max < v_ader)                               as f_ader,
           -- análise ainda pendente não conta como "dado incompleto"
           (b.reanalise_solicitada_em is null and (
                b.analise_atual_id is null or b.revisao_manual
             or b.area_sugerida is null or b.cargo_sugerido is null or b.nivel_sugerido is null
             or (b.ia_confianca is not null and b.ia_confianca < v_conf)))                as f_dados,
           -- só o cadastro MAIS ANTIGO do par é sugerido (o mais recente fica). Um EXISTS por critério, cada
           -- um com o seu índice (hash, telefone, e-mail): um único EXISTS com OR obrigaria a varrer a tabela.
           -- Telefone/e-mail iguais só valem com nome parecido (família ou agência dividem contato).
           (v_dup and (
              (b.hash_identidade is not null and exists (
                 select 1 from public.candidatos d
                  where d.hash_identidade = b.hash_identidade and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)))
              or (b.telefone_e164 is not null and exists (
                 select 1 from public.candidatos d
                  where d.telefone_e164 = b.telefone_e164 and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)
                    and extensions.similarity(d.nome_norm, b.nome_norm) >= 0.5))
              or (b.email is not null and exists (
                 select 1 from public.candidatos d
                  where lower(d.email) = lower(b.email) and d.id <> b.id and d.status_banco <> 'expurgado'
                    and (d.ultima_atualizacao, d.id) > (b.ultima_atualizacao, b.id)
                    and extensions.similarity(d.nome_norm, b.nome_norm) >= 0.5))))          as f_dup,
           (coalesce(b.consentimento_em, b.data_entrada) < now() - make_interval(months => v_ret)) as f_prazo,
           coalesce(h.vagas_reprovado, 0)                                                 as vagas_reprovado,
           n.nota_max,
           b.consentimento_em is null                                                     as sem_consentimento,
           b.data_entrada
      from base b
      join hist h on h.id = b.id
      left join notas n on n.id = b.id
  ),
  pont as (
    select s.*,
           ( (s.f_mov    ::int * (w ->> 'sem_movimentacao')::int)
           + (s.f_reprov ::int * (w ->> 'reprovacoes')::int)
           + (s.f_ader   ::int * (w ->> 'baixa_aderencia')::int)
           + (s.f_dados  ::int * (w ->> 'dados_incompletos')::int)
           + (s.f_dup    ::int * (w ->> 'duplicidade')::int)
           + (s.f_prazo  ::int * (w ->> 'prazo_retencao')::int) ) as total
      from sinais s
  )
  select p.id,
         array_remove(array[
           case when p.f_mov    then 'sem_movimentacao'   end,
           case when p.f_reprov then 'reprovacoes'        end,
           case when p.f_ader   then 'baixa_aderencia'    end,
           case when p.f_dados  then 'dados_incompletos'  end,
           case when p.f_dup    then 'duplicidade'        end,
           case when p.f_prazo  then 'prazo_retencao'     end], null),
         array_to_string(array_remove(array[
           -- "há N meses" a partir de 2 meses; antes disso conta em dias (o limite padrão é 1 mês)
           case when p.f_mov then format('Sem movimentação há %s (limite: %s %s)',
                  case when p.ult_mov <= now() - interval '2 months'
                       then (extract(year from age(now(), p.ult_mov)) * 12 + extract(month from age(now(), p.ult_mov)))::int || ' meses'
                       else (now()::date - p.ult_mov::date) || ' dias' end,
                  v_mov, case when v_mov = 1 then 'mês' else 'meses' end) end,
           case when p.f_reprov then format('Reprovado em %s vagas diferentes sem nenhuma aprovação', p.vagas_reprovado) end,
           case when p.f_ader then format('Melhor aderência da IA às vagas: %s%% (mínimo: %s%%)', p.nota_max, v_ader) end,
           case when p.f_dados then 'Currículo sem classificação confiável da IA (área, cargo ou nível)' end,
           case when p.f_dup then 'Possível cadastro duplicado (há outro mais recente do mesmo candidato)' end,
           case when p.f_prazo then format('No banco há mais de %s meses%s',
                  v_ret, case when p.sem_consentimento then ' sem consentimento registrado' else ' desde o último consentimento' end) end
         ], null), '; '),
         p.total,
         case when p.total >= (w ->> 'limite_alta')::int  then 'alta'
              when p.total >= (w ->> 'limite_media')::int then 'media'
              else 'baixa' end,
         p.ult_mov
    from pont p
   where p.f_mov or p.f_prazo;
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Geração da lista — é a da 023, com o intervalo em DIAS
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.fn_gerar_sugestoes_sanitizacao(
  p_origem text default 'manual', p_forcar boolean default false)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_params  jsonb;
  v_ultima  timestamptz;
  v_proxima timestamptz;
  v_ciclo   uuid;
  v_total   integer;
  v_por     jsonb;
begin
  -- o job usa a service_role (sem usuário); pelo painel só administrador
  if auth.uid() is not null then
    perform public.fn_exige_admin();
  end if;
  if p_origem not in ('job', 'manual') then
    raise exception 'Origem inválida.';
  end if;

  v_params := public.fn_sanitizacao_parametros();
  select max(gerada_em) into v_ultima from public.sanitizacao_ciclos;
  v_proxima := v_ultima + make_interval(days => (v_params ->> 'intervalo_dias')::int);
  if not p_forcar and v_ultima is not null and v_proxima > now() then
    return jsonb_build_object('gerada', false, 'motivo', 'intervalo ainda não venceu', 'proxima_em', v_proxima);
  end if;

  -- pendências de quem já não pode ser sanitizado (entrou em processo, foi excluído) saem da fila
  update public.sanitizacao_sugestoes s
     set status = 'expirada', decidido_em = now(), observacao = 'Candidato entrou em processo ou foi excluído'
    from public.candidatos c
   where c.id = s.candidato_id and s.status = 'pendente' and c.status_banco in ('em_processo', 'expurgado');

  insert into public.sanitizacao_ciclos (origem, gerada_por, parametros)
  values (p_origem, auth.uid(), v_params)
  returning id into v_ciclo;

  insert into public.sanitizacao_sugestoes
         (ciclo_id, candidato_id, motivos, motivo_texto, pontos, prioridade, ultima_movimentacao)
  select v_ciclo, a.candidato_id, a.motivos, a.motivo_texto, a.pontos, a.prioridade, a.ultima_movimentacao
    from public.fn_sanitizacao_avaliar(v_params) a;
  get diagnostics v_total = row_count;

  select coalesce(jsonb_object_agg(prioridade, n), '{}'::jsonb) into v_por
    from (select prioridade, count(*) n from public.sanitizacao_sugestoes where ciclo_id = v_ciclo group by 1) x;

  update public.sanitizacao_ciclos set total_sugeridas = v_total, por_prioridade = v_por where id = v_ciclo;

  perform public.fn_registra_auditoria(
    'sanitizacao_geracao', 'sanitizacao_ciclos', v_ciclo, null,
    jsonb_build_object('origem', p_origem, 'total', v_total, 'por_prioridade', v_por),
    'Lista de sugestões de sanitização gerada');

  return jsonb_build_object('gerada', true, 'ciclo_id', v_ciclo, 'total', v_total, 'por_prioridade', v_por);
end $$;

-- ───────────────────────────────────────────────────────────────────────
--  Botão "Sanitizar": o RH manda o candidato direto para a fila
--  Qualquer usuário ativo pode; a decisão (manter, inativar, excluir) segue as mesmas regras da fila.
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.sanitizacao_enviar_candidato(p_candidato_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  c    public.candidatos%rowtype;
  v_id uuid;
begin
  perform public.fn_exige_usuario_ativo();

  select * into c from public.candidatos where id = p_candidato_id for update;
  if not found then
    raise exception 'Candidato não encontrado.';
  end if;
  if c.status_banco = 'expurgado' then
    raise exception 'Os dados deste candidato já foram excluídos.';
  end if;
  if c.status_banco = 'em_processo' then
    raise exception 'Este candidato está em processo seletivo: encerre a candidatura antes de sanitizar.';
  end if;
  if c.retencao_permanente then
    raise exception 'Este candidato tem retenção permanente (contratado) e não entra na sanitização.';
  end if;

  select id into v_id from public.sanitizacao_sugestoes where candidato_id = c.id and status = 'pendente';
  if found then
    return jsonb_build_object('enviada', false, 'ja_na_lista', true, 'sugestao_id', v_id);
  end if;

  insert into public.sanitizacao_sugestoes
         (ciclo_id, origem, enviada_por, candidato_id, motivos, motivo_texto, pontos, prioridade, ultima_movimentacao)
  values (null, 'manual', auth.uid(), c.id, array['envio_manual'], 'Enviado para a sanitização pelo RH',
          (public.fn_sanitizacao_parametros() -> 'pesos' ->> 'limite_alta')::int, 'alta', c.ultima_movimentacao)
  returning id into v_id;

  -- mesma ação da decisão do RH (a ação é um enum: valor novo exigiria uma migração só para isso)
  perform public.fn_registra_auditoria(
    'sanitizacao_decisao', 'candidatos', c.id, null,
    jsonb_build_object('decisao', 'enviar', 'sugestao_id', v_id, 'prioridade', 'alta'),
    'Sanitização: enviado pelo RH');

  return jsonb_build_object('enviada', true, 'ja_na_lista', false, 'sugestao_id', v_id);
end $$;

revoke execute on function public.sanitizacao_enviar_candidato(uuid) from public, anon, authenticated;
grant execute on function public.sanitizacao_enviar_candidato(uuid) to authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────
--  Sugestões pendentes geradas ANTES desta regra e que ainda não cumpriram o prazo saem da fila
--  (ex.: "dados incompletos" sugerido no dia da entrada). Voltam sozinhas se, passado o prazo, ainda valerem.
--  Só as automáticas: uma enviada pelo RH nunca expira por aqui.
-- ───────────────────────────────────────────────────────────────────────
update public.sanitizacao_sugestoes s
   set status = 'expirada', decidido_em = now(),
       observacao = 'Regra nova: só é sugerido depois de ' ||
                    public.fn_config_numero('sanitizacao_meses_sem_movimentacao', 1)::int || ' mês sem alteração'
  from public.candidatos c
 where c.id = s.candidato_id
   and s.status = 'pendente' and s.origem = 'automatica'
   and c.ultima_movimentacao >= now() - make_interval(months => public.fn_config_numero('sanitizacao_meses_sem_movimentacao', 1)::int)
   and coalesce(c.consentimento_em, c.data_entrada)
         >= now() - make_interval(months => public.fn_config_numero('sanitizacao_retencao_maxima_meses', 24)::int);
