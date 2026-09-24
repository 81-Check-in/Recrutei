-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · ATRIBUIR A UMA VAGA GRAVA A QUALIFICAÇÃO DA VAGA NO CURRÍCULO
--
--  Rodar depois da 033. Pode rodar de novo sem problema.
--
--  Quando o RH direciona um candidato a uma vaga, um humano decidiu que o currículo serve para ela. O setor, a função e
--  o nível da VAGA passam a ser a qualificação do currículo atual do candidato — feito pelo banco, objetivamente, sem IA.
--
--    • curriculos.setor_adequado / funcao_setor / nivel_funcao   = os da vaga
--    • candidatos.area_sugerida / cargo_sugerido / nivel_sugerido = os mesmos (é o que o painel lê)
--    • candidatos.revisao_manual = false (a pendência de classificação foi resolvida por uma pessoa)
--    • a NOTA do currículo não muda (continua sendo a da IA)
--
--  Só vale para vaga completa (setor + função + nível): vaga antiga sem função ou nível não mexe em nada, para não deixar
--  um currículo com metade da qualificação de um setor e metade de outro.
--
--  Cancelar a seleção (encerrar_candidatura → "cancelado") NÃO desfaz isso: o candidato volta ao Banco de Talentos com a
--  qualificação que o currículo tinha. A qualificação de ANTES fica na auditoria (logs_auditoria) e a análise da IA, no
--  histórico (analises_ia), ambos intactos.
-- ════════════════════════════════════════════════════════════════════════

-- É a função da 033, idêntica, exceto pelo bloco "qualificação da vaga" e pelo detalhe da auditoria.
create or replace function public.fn_atribuir_candidato_vaga(
  p_candidato_id uuid, p_vaga_id uuid, p_usuario_id uuid, p_observacao text default null)
returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_status      public.status_banco_talentos;
  v_negra       boolean;
  v_vaga_status public.status_registro;
  v_id          uuid;
  v_setor       text;
  v_funcao      text;
  v_nivel       text;
  v_ant         jsonb;
  v_gravou      integer := 0;
begin
  select status_banco, lista_negra into v_status, v_negra from public.candidatos where id = p_candidato_id for update;
  if not found then
    raise exception 'Candidato não encontrado.';
  end if;
  if v_negra then
    raise exception 'Este candidato está na lista negra e não pode ser atribuído a vagas.';
  elsif v_status = 'em_processo' then
    raise exception 'Este candidato já está em um processo seletivo. Encerre a candidatura atual antes de atribuí-lo a outra vaga.';
  elsif v_status = 'inativo' then
    raise exception 'Candidato inativo. Reative-o no Banco de Talentos antes de atribuir a uma vaga.';
  elsif v_status = 'expurgado' then
    raise exception 'Os dados deste candidato foram excluídos.';
  end if;

  select v.status, s.nome, v.funcao_setor, v.nivel_funcao into v_vaga_status, v_setor, v_funcao, v_nivel
    from public.vagas v join public.setores s on s.id = v.setor_id where v.id = p_vaga_id;
  if not found then
    raise exception 'Vaga não encontrada.';
  end if;
  if v_vaga_status <> 'ativo' then
    raise exception 'Esta vaga não está mais aberta.';
  end if;

  if exists (select 1 from public.candidaturas
              where candidato_id = p_candidato_id and vaga_id = p_vaga_id and status in ('reprovado', 'descartado')) then
    raise exception 'Este candidato já foi reprovado nesta vaga. Ele só pode voltar em uma vaga nova.';
  end if;

  insert into public.candidaturas
         (candidato_id, vaga_id, status, atribuido_por, data_atribuicao, vaga_confirmada_rh,
          avaliacao_pendente, origem, observacao_atribuicao)
  values (p_candidato_id, p_vaga_id, 'aguardando', p_usuario_id, now(), true,
          false, 'atribuicao_manual', nullif(btrim(p_observacao), ''))
  returning id into v_id;

  -- Qualificação da vaga no currículo atual (só com a vaga completa). O que estava antes vai para a auditoria.
  if v_funcao is not null and v_nivel is not null then
    select jsonb_build_object('setor', cu.setor_adequado, 'funcao', cu.funcao_setor, 'nivel', cu.nivel_funcao)
      into v_ant from public.curriculos cu where cu.candidato_id = p_candidato_id and cu.atual limit 1;

    update public.curriculos
       set setor_adequado = v_setor, funcao_setor = v_funcao, nivel_funcao = v_nivel
     where candidato_id = p_candidato_id and atual;
    get diagnostics v_gravou = row_count;

    if v_gravou > 0 then
      update public.candidatos
         set area_sugerida = v_setor, cargo_sugerido = v_funcao, nivel_sugerido = v_nivel,
             revisao_manual = false, ultima_atualizacao = now()
       where id = p_candidato_id;
    end if;
  end if;

  perform public.fn_registra_auditoria(
    'atribuicao_candidato', 'candidaturas', v_id, null,
    jsonb_build_object('candidato_id', p_candidato_id, 'vaga_id', p_vaga_id)
      || case when v_gravou > 0
              then jsonb_build_object('qualificacao_gravada',
                     jsonb_build_object('setor', v_setor, 'funcao', v_funcao, 'nivel', v_nivel, 'anterior', v_ant))
              else '{}'::jsonb end,
    'Candidato atribuído à vaga pelo RH');
  return v_id;
end $$;
