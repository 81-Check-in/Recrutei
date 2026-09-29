-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Encaminhar ao gerente já abrindo o WhatsApp dele (055)
--
--  Rodar depois da 054. Pode rodar de novo sem problema.
--
--  051_gerente_loja.sql criou "Encaminhar ao gerente" (marca a candidatura como aguardando_gerente; o RH
--  mandava o currículo por fora, sem ajuda do painel). Esta migração dá esse empurrão: o botão já abre o
--  WhatsApp do gerente da loja, com o nome do candidato e um link pro currículo, prontos.
--
--  Uma vaga do setor Loja normalmente vale pra várias lojas ao mesmo tempo (ex.: "Vendedor" nas 10 lojas) —
--  não dá pra saber sozinho qual gerente contactar. Por isso:
--    • empresas.gerente_whatsapp — o WhatsApp do gerente de cada loja (o RH cadastra em Configurações).
--    • candidaturas.encaminhado_gerente_empresa_id — registra pra qual loja (das vinculadas à vaga) foi.
--    • encaminhar_ao_gerente ganha o parâmetro p_empresa_id (opcional, mantém compatível com quem não escolher
--      loja nenhuma — ex.: nenhuma das lojas da vaga tem WhatsApp cadastrado, o RH manda por fora como sempre).
-- ════════════════════════════════════════════════════════════════════════

alter table public.empresas add column if not exists gerente_whatsapp text;
comment on column public.empresas.gerente_whatsapp is
  'WhatsApp do gerente desta loja (formato livre — normalizado com DDI/DDD ao abrir, igual ao telefone do candidato). Vazio = "Encaminhar ao gerente" não abre o WhatsApp sozinho.';

alter table public.candidaturas
  add column if not exists encaminhado_gerente_empresa_id uuid references public.empresas(id) on delete set null;
comment on column public.candidaturas.encaminhado_gerente_empresa_id is
  'A loja (entre as vinculadas à vaga) escolhida na hora de encaminhar ao gerente — uma vaga do setor Loja pode valer pra várias lojas.';

-- ───────────────────────────────────────────────────────────────────────
--  encaminhar_ao_gerente ganha p_empresa_id (precisa recriar: o parâmetro novo muda a assinatura)
-- ───────────────────────────────────────────────────────────────────────
drop function if exists public.encaminhar_ao_gerente(uuid);

create function public.encaminhar_ao_gerente(p_candidatura_id uuid, p_empresa_id uuid default null)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status    public.status_candidatura;
  v_encerrada timestamptz;
  v_vaga      uuid;
  v_setor     text;
begin
  perform public.fn_exige_usuario_ativo();

  select ca.status, ca.encerrada_em, ca.vaga_id, s.nome
    into v_status, v_encerrada, v_vaga, v_setor
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
  -- a loja informada precisa ser mesmo uma das vinculadas à vaga (o painel só oferece essas, mas a função confere de novo)
  if p_empresa_id is not null and not exists (
    select 1 from public.vaga_empresas where vaga_id = v_vaga and empresa_id = p_empresa_id
  ) then
    raise exception 'Esta loja não está vinculada à vaga do candidato.';
  end if;

  update public.candidaturas
     set status                         = 'aguardando_gerente'::public.status_candidatura,
         encaminhado_gerente_em         = now(),
         encaminhado_gerente_por        = auth.uid(),
         encaminhado_gerente_empresa_id = p_empresa_id
   where id = p_candidatura_id;
end $$;

revoke execute on function public.encaminhar_ao_gerente(uuid, uuid) from public, anon, authenticated;
grant execute on function public.encaminhar_ao_gerente(uuid, uuid) to authenticated;
grant execute on function public.encaminhar_ao_gerente(uuid, uuid) to service_role;

-- ───────────────────────────────────────────────────────────────────────
--  Mensagem padrão ao encaminhar (mesma ideia da mensagem_convocacao_padrao, 023) — marcadores {nome},{vaga},{link}
-- ───────────────────────────────────────────────────────────────────────
insert into public.configuracoes (chave, valor, descricao) values
  ('mensagem_gerente_padrao', to_jsonb(
    'Olá! Segue o currículo de {nome} para a vaga de {vaga}. Dá uma olhada e me fala o que achou:\n{link}'::text),
   'Mensagem sugerida ao encaminhar um candidato ao gerente da loja (o RH ainda pode editar antes de enviar). Marcadores: {nome}, {vaga}, {link}.')
on conflict (chave) do nothing;
