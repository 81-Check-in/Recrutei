-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Cadastro manual de candidato sem currículo (077)
--
--  Rodar depois da 076. Pode rodar de novo sem problema.
--
--  O RH digita os dados de quem não mandou arquivo (indicação, contato por telefone, balcão). Obrigatórios: nome e telefone;
--  o resto é opcional.
--    • cadastrar_candidato_manual(p_dados, p_vaga_id) — cria o candidato ("ativo", origem upload_manual) e um currículo SEM
--      arquivo, só com a observação "Currículo enviado manualmente sem anexo" (é o que o painel mostra no lugar do arquivo).
--      Não há análise da IA: sem vaga, o candidato fica em "revisão manual" até o RH atribuí-lo a uma vaga (a atribuição grava
--      setor, função e nível — 034); com p_vaga_id, já é atribuído à vaga.
--      Recusa quem já está no banco com o mesmo nome e telefone.
--      p_dados: nome, telefone, telefone_e164 (só dígitos, com DDI e DDD — o painel normaliza) e, opcionais, os mesmos campos
--      de editar_candidato (email, cidade, uf, bairro, data_nascimento, sexo, escolaridade, anos_experiencia, cnh).
--  Quando a pessoa mandar o currículo de verdade por e-mail, o robô reconhece o cadastro (nome + telefone) e o currículo
--  substitui a observação (pipeline._motivo_para_nao_reler / database.buscar_candidato_existente).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.cadastrar_candidato_manual(p_dados jsonb, p_vaga_id uuid default null)
returns uuid
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_nome   text;
  v_tel    text;
  v_e164   text;
  v_id     uuid;
  v_resto  jsonb;
begin
  perform public.fn_exige_usuario_ativo();
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' then
    raise exception 'Dados inválidos.';
  end if;

  v_nome := nullif(btrim(regexp_replace(coalesce(p_dados ->> 'nome', ''), '\s+', ' ', 'g')), '');
  v_tel  := nullif(btrim(p_dados ->> 'telefone'), '');
  v_e164 := nullif(regexp_replace(coalesce(p_dados ->> 'telefone_e164', p_dados ->> 'telefone', ''), '\D', '', 'g'), '');
  if v_nome is null or length(v_nome) < 3 or length(v_nome) > 200 then
    raise exception 'Informe o nome do candidato.';
  end if;
  if v_e164 is null or length(v_e164) < 10 or length(v_e164) > 15 then
    raise exception 'Informe um telefone válido, com DDD.';
  end if;

  if exists (select 1 from public.candidatos c
              where c.status_banco <> 'expurgado'
                and c.nome_norm = public.norm_busca(v_nome)
                and public.fn_telefones_batem(regexp_replace(coalesce(c.telefone_e164, c.telefone, ''), '\D', '', 'g'), v_e164)) then
    raise exception 'Já existe um candidato com este nome e telefone no Banco de Talentos.';
  end if;

  insert into public.candidatos (nome, telefone, telefone_e164, status_banco, origem_entrada, revisao_manual)
  values (v_nome, coalesce(v_tel, v_e164), v_e164, 'ativo', 'upload_manual', true)
  returning id into v_id;

  insert into public.curriculos (candidato_id, origem, tipo_mime, texto_extraido, atual, extracao_ok, recebido_em)
  values (v_id, 'upload_manual', 'text/plain', 'Currículo enviado manualmente sem anexo', true, true, now());

  perform public.fn_registra_auditoria('criacao', 'candidatos', v_id, null,
    jsonb_build_object('origem', 'cadastro_manual_sem_curriculo'), 'Candidato cadastrado manualmente pelo RH, sem currículo');

  -- os opcionais passam pelas mesmas validações de "Editar dados" (só o que veio preenchido)
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into v_resto
    from jsonb_each_text(p_dados - 'nome' - 'telefone' - 'telefone_e164') as t(k, v)
   where nullif(btrim(v), '') is not null;
  if v_resto <> '{}'::jsonb then
    perform public.editar_candidato(v_id, v_resto);
  end if;

  if p_vaga_id is not null then
    perform public.atribuir_candidato_vaga(v_id, p_vaga_id);
  end if;
  return v_id;
end $$;

revoke all on function public.cadastrar_candidato_manual(jsonb, uuid) from public, anon;
grant execute on function public.cadastrar_candidato_manual(jsonb, uuid) to authenticated;
grant execute on function public.cadastrar_candidato_manual(jsonb, uuid) to service_role;
