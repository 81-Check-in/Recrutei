-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Resultado "Sem interesse" + currículo que já passou pela entrevista (072)
--
--  Rodar depois da 071. Pode rodar de novo sem problema.
--
--  1) Entrevistas: "Sem interesse" passa a ser um resultado (ao lado de aprovado, reprovado e não compareceu).
--     A candidatura fecha como cancelada (o candidato volta ao Banco de Talentos sem ser marcado como reprovado)
--     e a linha do Histórico do candidato entra sozinha com o status "Sem interesse".
--  2) Enviar currículo: o RH pode informar que a pessoa JÁ foi entrevistada (vaga aberta + aprovado/reprovado/sem
--     interesse). O currículo entra no Banco de Talentos com a qualificação da vaga, SEM criar candidatura nem
--     entrevista; o desfecho vai direto para o Histórico (origem "registrado à mão").
-- ════════════════════════════════════════════════════════════════════════

-- 1) Entrevista → status da candidatura
create or replace function public.fn_sincroniza_status_entrevista()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if tg_op = 'INSERT' then
    update public.candidaturas
       set status = 'entrevista_agendada'
     where id = new.candidatura_id
       and status in ('aguardando', 'selecionado', 'nao_compareceu', 'entrevista_realizada');
    return new;
  end if;

  if new.resultado is distinct from old.resultado then
    update public.candidaturas
       set status = case new.resultado
                      when 'aprovado'       then 'aprovado'::public.status_candidatura
                      when 'reprovado'      then 'reprovado'::public.status_candidatura
                      when 'nao_compareceu' then 'nao_compareceu'::public.status_candidatura
                      when 'sem_interesse'  then 'cancelado'::public.status_candidatura
                      else status
                    end,
           -- reprovou / sem interesse: o motivo digitado na entrevista vira o resultado final da candidatura
           resultado_final = case when new.resultado = 'reprovado'
                                  then coalesce(nullif(btrim(new.observacoes), ''), 'Reprovado na entrevista')
                                  when new.resultado = 'sem_interesse'
                                  then coalesce(nullif(btrim(new.observacoes), ''), 'Sem interesse na vaga')
                                  else resultado_final end
     where id = new.candidatura_id;

    new.resultado_registrado_em  := coalesce(new.resultado_registrado_em, now());
    new.resultado_registrado_por := coalesce(new.resultado_registrado_por, auth.uid());
  end if;

  return new;
end $$;

-- 1b) Histórico: "sem interesse" também é desfecho
create or replace function public.fn_historico_sincroniza_entrevista()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_cand   uuid;
  v_nome   text;
  v_tel    text;
  v_vaga   uuid;
  v_titulo text;
  v_setor  text;
begin
  if new.resultado::text not in ('aprovado', 'reprovado', 'nao_compareceu', 'sem_interesse') then
    delete from public.historico_candidatos where entrevista_id = new.id and not alterado_manual;
    return new;
  end if;

  select ca.candidato_id,
         coalesce(nullif(btrim(c.nome), ''), nullif(btrim(ca.dados_pessoais ->> 'nome'), ''), 'Nome não informado'),
         coalesce(nullif(btrim(c.telefone), ''), nullif(btrim(c.telefone_e164), ''), nullif(btrim(ca.dados_pessoais ->> 'telefone'), '')),
         ca.vaga_id, v.titulo, s.nome
    into v_cand, v_nome, v_tel, v_vaga, v_titulo, v_setor
    from public.candidaturas ca
    left join public.candidatos c on c.id = ca.candidato_id
    left join public.vagas v on v.id = ca.vaga_id
    left join public.setores s on s.id = v.setor_id
   where ca.id = new.candidatura_id;
  if not found then
    return new;
  end if;

  insert into public.historico_candidatos
    (entrevista_id, candidato_id, vaga_id, nome, telefone, data_evento, setor_vaga, vaga_titulo, status, observacao, origem, registrado_por)
  values
    (new.id, v_cand, v_vaga, v_nome, v_tel, (new.data_hora at time zone 'America/Sao_Paulo')::date, v_setor, v_titulo,
     new.resultado::text, nullif(btrim(new.observacoes), ''), 'sistema', new.resultado_registrado_por)
  on conflict (entrevista_id) do update
     set candidato_id  = excluded.candidato_id,
         vaga_id       = excluded.vaga_id,
         nome          = excluded.nome,
         telefone      = excluded.telefone,
         data_evento   = excluded.data_evento,
         setor_vaga    = excluded.setor_vaga,
         vaga_titulo   = excluded.vaga_titulo,
         status        = excluded.status,
         observacao    = excluded.observacao,
         registrado_por = coalesce(excluded.registrado_por, public.historico_candidatos.registrado_por),
         atualizado_em = now()
   where not public.historico_candidatos.alterado_manual;
  return new;
end $$;

-- 2) Enviar currículo de quem já foi entrevistado
alter table public.uploads_manuais
  add column if not exists resultado_entrevista text;
alter table public.uploads_manuais drop constraint if exists chk_upload_resultado_entrevista;
alter table public.uploads_manuais add constraint chk_upload_resultado_entrevista
  check (resultado_entrevista is null
         or (resultado_entrevista in ('aprovado', 'reprovado', 'sem_interesse') and vaga_id is not null));
comment on column public.uploads_manuais.resultado_entrevista is
  'Preenchido quando o RH informa que a pessoa JÁ foi entrevistada para a vaga escolhida. Não cria candidatura: o desfecho vai direto para o Histórico.';
