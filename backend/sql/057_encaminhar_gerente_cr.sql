-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Encaminhar ao gerente também nas vagas do CR (057)
--
--  Rodar depois da 056. Pode rodar de novo sem problema.
--
--  050/051/055 criaram "Encaminhar ao gerente" só para vagas do setor Loja: cada loja tem seu próprio gerente,
--  cadastrado em empresas.gerente_whatsapp (uma vaga pode valer pra várias lojas, por isso o RH escolhe qual).
--  O setor CR não tem "lojas": há um único gerente para todas as vagas do CR, então não faz sentido usar o
--  mesmo mecanismo de empresas/vaga_empresas — o WhatsApp dele fica direto em configuracoes.gerente_whatsapp_cr
--  (o RH cadastra em Configurações) e o frontend monta o link do WhatsApp sozinho, sem escolher loja nem passar
--  p_empresa_id (a função já aceita null desde a 055).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.encaminhar_ao_gerente(p_candidatura_id uuid, p_empresa_id uuid default null)
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
  if v_setor is distinct from 'Loja' and v_setor is distinct from 'CR' then
    raise exception 'Encaminhar ao gerente só vale para vagas do setor Loja ou CR.';
  end if;
  if v_status = 'aguardando_gerente' then
    raise exception 'Este candidato já foi encaminhado ao gerente.';
  end if;
  -- a loja informada precisa ser mesmo uma das vinculadas à vaga (o painel só oferece essas, mas a função confere de novo);
  -- nas vagas do CR isto não se aplica: p_empresa_id vem sempre null (não há "loja" do CR)
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
-- assinatura não muda: create or replace basta, sem precisar refazer o revoke/grant da 055

-- "Aprovado pelo gerente da loja" (051) virava um resultado_final errado num candidato do CR; generaliza
-- o texto padrão (quem passa um motivo próprio, via p_motivo, não é afetado).
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
         resultado_final = coalesce(nullif(left(btrim(p_motivo), 500), ''), 'Aprovado pelo gerente')
   where id = p_candidatura_id;
end $$;
-- assinatura não muda: create or replace basta, sem precisar refazer o revoke/grant da 051

insert into public.configuracoes (chave, valor, descricao) values
  ('gerente_whatsapp_cr', to_jsonb(''::text),
   'WhatsApp do gerente do CR (formato livre — normalizado com DDI/DDD ao abrir, igual ao telefone do candidato). Vazio = "Encaminhar ao gerente" não abre o WhatsApp sozinho nas vagas do CR.')
on conflict (chave) do nothing;

-- O número vira o destino do link do WhatsApp com o currículo: só aceita telefone (ou vazio), nada de texto livre.
create or replace function public.fn_valida_config_whatsapp()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.chave = 'gerente_whatsapp_cr'
     and (jsonb_typeof(new.valor) <> 'string'
          or new.valor #>> '{}' !~ '^([0-9+() -]{8,20})?$') then
    raise exception 'WhatsApp do gerente inválido: use só dígitos, +, espaço, parênteses e hífen (8 a 20 caracteres).';
  end if;
  return new;
end $$;

drop trigger if exists trg_valida_config_whatsapp on public.configuracoes;
create trigger trg_valida_config_whatsapp
  before insert or update on public.configuracoes
  for each row execute function public.fn_valida_config_whatsapp();

-- Quem controla o número do gerente do CR é o RH (gerente de RH e administrador), não só o administrador:
-- mesma regra de empresas.gerente_whatsapp (loja). Só esta chave: as demais continuam só do administrador
-- (config_escrita_admin). Por ser política de UPDATE, o RH não cria nem apaga chaves; o trigger acima valida o formato.
drop policy if exists config_escrita_gerente_cr on public.configuracoes;
create policy config_escrita_gerente_cr on public.configuracoes
  for update to authenticated
  using      (chave = 'gerente_whatsapp_cr' and (select public.fn_usuario_ativo()))
  with check (chave = 'gerente_whatsapp_cr' and (select public.fn_usuario_ativo()));
