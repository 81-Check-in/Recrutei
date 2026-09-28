-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Encaminhar ao gerente da loja (051)
--
--  Rodar depois da 050 (o valor novo do enum). Pode rodar de novo sem problema.
--
--  Vagas do setor Loja (Repositor, Operador de Caixa, Vendedor…) não passam por entrevista marcada pelo RH: a
--  triagem final é feita com o gerente da loja. O RH manda o currículo a ele por fora do sistema (WhatsApp,
--  e-mail…) e, quando o gerente responde, registra a decisão aqui. Por isso:
--
--    • encaminhar_ao_gerente(candidatura) — move a candidatura para 'aguardando_gerente' (a "última fase"; só
--      muda a fase, não envia nada: o currículo continua sendo mandado por fora). Só vale para candidaturas
--      abertas de vagas do setor Loja.
--    • aprovar_candidatura_gerente(candidatura, motivo) — o gerente aprovou: status vira 'aprovado', o mesmo que
--      já acontece quando o RH registra "Aprovado" numa entrevista (a candidatura continua aberta, o candidato
--      continua em processo). Só vale a partir de 'aguardando_gerente'.
--    • Para reprovar, o botão usa a mesma encerrar_candidatura(candidatura, 'reprovado', motivo) que as demais
--      vagas já usam (022): fecha a candidatura e devolve o candidato ao Banco de Talentos. Nenhuma função nova
--      precisa disso.
--    • vw_candidatos (037/045) ganha 'aguardando_gerente' na lista de status que aparecem em "Em processo" —
--      sem isso o candidato encaminhado sumiria da tela.
-- ════════════════════════════════════════════════════════════════════════

alter table public.candidaturas
  add column if not exists encaminhado_gerente_em  timestamptz,
  add column if not exists encaminhado_gerente_por  uuid;
comment on column public.candidaturas.encaminhado_gerente_em is
  'Quando o RH encaminhou o candidato ao gerente da loja (fora do sistema). Só usado nas vagas do setor Loja.';

-- ───────────────────────────────────────────────────────────────────────
--  1) Encaminhar / aprovar
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.encaminhar_ao_gerente(p_candidatura_id uuid)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status    public.status_candidatura;
  v_encerrada timestamptz;
  v_setor     text;
begin
  perform public.fn_exige_usuario_ativo();

  select ca.status, ca.encerrada_em, s.nome
    into v_status, v_encerrada, v_setor
    from public.candidaturas ca
    left join public.vagas vg on vg.id = ca.vaga_id
    left join public.setores s on s.id = vg.setor_id
   where ca.id = p_candidatura_id
     for update of ca;
  if not found then
    raise exception 'Candidatura não encontrada.';
  end if;
  if v_encerrada is not null then
    raise exception 'Esta candidatura já foi encerrada.';
  end if;
  if v_setor is distinct from 'Loja' then
    raise exception 'Encaminhar ao gerente só vale para vagas do setor Loja.';
  end if;
  if v_status = 'aguardando_gerente' then
    raise exception 'Este candidato já foi encaminhado ao gerente.';
  end if;

  update public.candidaturas
     set status                  = 'aguardando_gerente'::public.status_candidatura,
         encaminhado_gerente_em  = now(),
         encaminhado_gerente_por = auth.uid()
   where id = p_candidatura_id;
end $$;

create or replace function public.aprovar_candidatura_gerente(p_candidatura_id uuid, p_motivo text default null)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status    public.status_candidatura;
  v_encerrada timestamptz;
begin
  perform public.fn_exige_usuario_ativo();

  select status, encerrada_em into v_status, v_encerrada
    from public.candidaturas where id = p_candidatura_id for update;
  if not found then
    raise exception 'Candidatura não encontrada.';
  end if;
  if v_encerrada is not null then
    raise exception 'Esta candidatura já foi encerrada.';
  end if;
  if v_status <> 'aguardando_gerente' then
    raise exception 'Esta candidatura não está aguardando a decisão do gerente.';
  end if;

  update public.candidaturas
     set status          = 'aprovado'::public.status_candidatura,
         resultado_final = coalesce(nullif(btrim(p_motivo), ''), 'Aprovado pelo gerente da loja')
   where id = p_candidatura_id;
end $$;

revoke execute on function
  public.encaminhar_ao_gerente(uuid),
  public.aprovar_candidatura_gerente(uuid, text)
from public, anon, authenticated;
grant execute on function
  public.encaminhar_ao_gerente(uuid),
  public.aprovar_candidatura_gerente(uuid, text)
to authenticated;
grant execute on function
  public.encaminhar_ao_gerente(uuid),
  public.aprovar_candidatura_gerente(uuid, text)
to service_role;

-- ───────────────────────────────────────────────────────────────────────
--  2) vw_candidatos: "aguardando_gerente" também aparece em "Em processo"
--     (idêntica à da 045, só com o status novo na lista)
-- ───────────────────────────────────────────────────────────────────────
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
                             'aguardando_gerente', 'aprovado', 'reprovado', 'nao_compareceu',
                             'contratado']::public.status_candidatura[]);
