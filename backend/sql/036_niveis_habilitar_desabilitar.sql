-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Banco de Talentos · HABILITAR / DESABILITAR OS NÍVEIS JOVEM APRENDIZ E TRAINEE
--
--  Rodar depois da 035. Pode rodar de novo sem problema.
--
--  Jovem Aprendiz e Trainee são os dois níveis cujo critério ainda precisa ser auditado. O administrador pode habilitá-los
--  ou desabilitá-los (e reescrever o critério de qualquer nível) em Configurações, sem SQL:
--    • desabilitado: a IA deixa de recebê-lo, o formulário da vaga deixa de oferecê-lo e o banco recusa uma vaga com ele.
--      Currículos e vagas que já o têm continuam como estão (nada é apagado).
--    • Júnior, Pleno e Sênior não podem ser desabilitados: são a base da classificação.
--    • cada mudança fica na auditoria (logs_auditoria, ação "alteracao_criterios"), com quem, quando, antes e depois.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.alterar_nivel_funcao(p_codigo text, p_ativo boolean, p_descricao text)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_antes  public.niveis_funcao%rowtype;
  v_desc   text := nullif(btrim(p_descricao), '');
begin
  perform public.fn_exige_admin();

  select * into v_antes from public.niveis_funcao where codigo = p_codigo for update;
  if not found then
    raise exception 'Nível não encontrado.';
  end if;
  if p_ativo is not null and not p_ativo and p_codigo not in ('jovem_aprendiz', 'trainee') then
    raise exception 'Só Jovem Aprendiz e Trainee podem ser desabilitados: Júnior, Pleno e Sênior são a base da classificação.';
  end if;
  if p_descricao is not null and (v_desc is null or length(v_desc) < 10) then
    raise exception 'Escreva o critério do nível (é o que a IA lê para escolher entre os níveis).';
  end if;

  update public.niveis_funcao
     set ativo = coalesce(p_ativo, ativo), descricao = coalesce(v_desc, descricao)
   where codigo = p_codigo;

  if (v_antes.ativo, v_antes.descricao) is distinct from
     ((select ativo from public.niveis_funcao where codigo = p_codigo), (select descricao from public.niveis_funcao where codigo = p_codigo)) then
    perform public.fn_registra_auditoria(
      'alteracao_criterios', 'niveis_funcao', md5('niveis_funcao:' || p_codigo)::uuid,
      jsonb_build_object('codigo', p_codigo, 'ativo', v_antes.ativo, 'descricao', v_antes.descricao),
      (select jsonb_build_object('codigo', codigo, 'ativo', ativo, 'descricao', descricao) from public.niveis_funcao where codigo = p_codigo),
      case when p_ativo is distinct from v_antes.ativo and p_ativo is not null
           then format('Nível %s %s', v_antes.nome, case when p_ativo then 'habilitado' else 'desabilitado' end)
           else format('Critério do nível %s alterado', v_antes.nome) end);
  end if;
end $$;

revoke execute on function public.alterar_nivel_funcao(text, boolean, text) from public, anon;
grant execute on function public.alterar_nivel_funcao(text, boolean, text) to authenticated, service_role;   -- a função confere se é administrador

-- A vaga só aceita nível habilitado (a 035 já exigia cargo do setor e Jovem Aprendiz/Trainee só nos cargos que os aceitam)
create or replace function public.fn_vaga_valida_funcao()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  v_aceita boolean;
  v_onde   text;
  v_nome   text;
begin
  if new.nivel_funcao is not null then
    select n.nome into v_nome from public.niveis_funcao n where n.codigo = new.nivel_funcao and not n.ativo;
    if found then
      raise exception 'O nível "%" está desabilitado. Escolha outro nível.', v_nome;
    end if;
  end if;
  if new.funcao_setor is not null then
    select f.aceita_iniciante into v_aceita
      from public.funcoes_setor f
     where f.setor_id = new.setor_id and f.nome = new.funcao_setor and f.ativo;
    if not found then
      raise exception 'A função "%" não existe no setor escolhido. Escolha uma função da lista.', new.funcao_setor;
    end if;
    if new.nivel_funcao in ('jovem_aprendiz', 'trainee') and not v_aceita then
      select string_agg(s.nome || ' / ' || f.nome, ', ' order by s.nome, f.nome) into v_onde
        from public.funcoes_setor f join public.setores s on s.id = f.setor_id
       where f.aceita_iniciante and f.ativo;
      raise exception 'Jovem Aprendiz e Trainee só existem para: %. Para "%" escolha Júnior, Pleno ou Sênior.', v_onde, new.funcao_setor;
    end if;
  end if;
  return new;
end $$;
