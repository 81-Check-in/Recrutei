-- Testes de HABILITAR / DESABILITAR os níveis Jovem Aprendiz e Trainee (036). Roda depois de 020–036.
-- Tudo dentro de uma transação que termina em ROLLBACK.
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.como(p_usuario uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_usuario::text, ''), true);
  reset role;
  if p_usuario is not null then set local role authenticated; end if;
end $$;
create or replace function pg_temp.deve_falhar(p_sql text, p_trecho text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_trecho in sqlerrm) = 0 then
      raise exception 'falhou com a mensagem errada. Esperado conter [%], veio [%]', p_trecho, sqlerrm;
    end if;
    return;
  end;
  raise exception 'deveria ter falhado (esperado: %)', p_trecho;
end $$;

do $$
declare
  ana  constant uuid := '00000000-0000-0000-0000-0000000000a1';   -- administradora
  beto constant uuid := '00000000-0000-0000-0000-0000000000b1';   -- gerente de RH
  logistica uuid; vaga uuid; descricao_antes text;
begin
  select id into logistica from setores where nome = 'Logística';
  select descricao into descricao_antes from niveis_funcao where codigo = 'trainee';

  -- ── só o administrador altera ──
  perform pg_temp.como(beto);
  perform pg_temp.deve_falhar($f$select alterar_nivel_funcao('trainee', false, null)$f$, 'Somente o administrador');
  perform pg_temp.como(null);
  set local role anon;
  begin
    perform alterar_nivel_funcao('trainee', false, null);
    raise exception 'anon não deveria executar';
  exception when insufficient_privilege then null;
  end;
  reset role;
  assert (select ativo from niveis_funcao where codigo = 'trainee'), 'nada mudou';

  -- ── Júnior, Pleno e Sênior não desabilitam; o critério tem de ter texto ──
  perform pg_temp.como(ana);
  perform pg_temp.deve_falhar($f$select alterar_nivel_funcao('junior', false, null)$f$, 'Só Jovem Aprendiz e Trainee');
  perform pg_temp.deve_falhar($f$select alterar_nivel_funcao('senior', false, null)$f$, 'Só Jovem Aprendiz e Trainee');
  perform pg_temp.deve_falhar($f$select alterar_nivel_funcao('trainee', null, '   ')$f$, 'Escreva o critério');
  perform pg_temp.deve_falhar($f$select alterar_nivel_funcao('trainee', null, 'curto')$f$, 'Escreva o critério');
  perform pg_temp.deve_falhar($f$select alterar_nivel_funcao('nao_existe', true, null)$f$, 'Nível não encontrado');

  -- ── desabilitar Trainee: o critério continua, a auditoria registra, a vaga com ele é recusada ──
  perform alterar_nivel_funcao('trainee', false, null);
  assert not (select ativo from niveis_funcao where codigo = 'trainee'), 'Trainee desabilitado';
  assert (select descricao from niveis_funcao where codigo = 'trainee') = descricao_antes, 'o critério não mudou';
  assert exists (select 1 from logs_auditoria where acao = 'alteracao_criterios' and entidade = 'niveis_funcao'
                    and dados_antes ->> 'ativo' = 'true' and dados_depois ->> 'ativo' = 'false'
                    and detalhe = 'Nível Trainee desabilitado' and usuario_id = ana), 'a auditoria guarda quem, quando, antes e depois';
  perform pg_temp.como(null);
  perform pg_temp.deve_falhar(format($f$insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (%L, 'x', 1, 'Auxiliar', 'trainee')$f$, logistica),
                              'está desabilitado');
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao)
    values (logistica, 'Auxiliar com Jovem Aprendiz', 1, 'Auxiliar', 'jovem_aprendiz') returning id into vaga;       -- o outro segue habilitado

  -- ── mesmo estado de novo não gera auditoria; reescrever o critério de um nível sim ──
  perform pg_temp.como(ana);
  perform alterar_nivel_funcao('trainee', false, null);
  assert (select count(*) from logs_auditoria where acao = 'alteracao_criterios' and entidade = 'niveis_funcao' and dados_depois ->> 'codigo' = 'trainee') = 1,
    'sem mudança, sem registro';
  perform alterar_nivel_funcao('jovem_aprendiz', null, 'Sem experiência profissional e em busca do primeiro emprego (critério novo).');
  assert (select descricao from niveis_funcao where codigo = 'jovem_aprendiz') like 'Sem experiência profissional e em busca%', 'critério reescrito';
  assert (select ativo from niveis_funcao where codigo = 'jovem_aprendiz'), 'e continua habilitado';
  assert exists (select 1 from logs_auditoria where detalhe = 'Critério do nível Jovem Aprendiz alterado'), 'reescrever o critério também fica registrado';

  -- ── habilitar de novo ──
  perform alterar_nivel_funcao('trainee', true, null);
  assert (select ativo from niveis_funcao where codigo = 'trainee'), 'Trainee habilitado de novo';
  perform pg_temp.como(null);
  insert into vagas (setor_id, titulo, quantidade, funcao_setor, nivel_funcao) values (logistica, 'Auxiliar com Trainee', 1, 'Auxiliar', 'trainee');

  -- ── vaga que já tinha o nível desabilitado depois: editar outra coisa não quebra; trocar de setor/cargo/nível exige um nível habilitado ──
  update niveis_funcao set ativo = false where codigo = 'jovem_aprendiz';
  update vagas set titulo = 'Auxiliar com Jovem Aprendiz (renomeada)' where id = vaga;
  perform pg_temp.deve_falhar(format($f$update vagas set funcao_setor = 'Auxiliar' where id = %L$f$, vaga), 'está desabilitado');

  raise notice 'TESTE DOS NÍVEIS: tudo certo';
end $$;

rollback;
