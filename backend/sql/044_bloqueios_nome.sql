-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — "Lista negra" passa a se chamar "Bloqueios" (044)
--
--  O painel trocou o nome (menu, tela, botões, avisos). Esta migração troca o mesmo nome nos TEXTOS que o banco devolve ao
--  painel ou grava (mensagens de erro, motivo da inativação, resultado da candidatura cancelada, detalhe da auditoria).
--  Os nomes internos NÃO mudam (tabela/colunas lista_negra*, vw_lista_negra, fn_lista_negra_candidato, bloquear_email…):
--  renomeá-los quebraria o painel e o robô sem ganho para quem usa.
--
--  Em vez de copiar o corpo das funções (e arriscar divergir da versão que está no ar), pega a definição atual de cada função
--  que cita "lista negra", troca só as frases abaixo e a recria. Se sobrar alguma citação que não esteja na lista de trocas,
--  a migração PARA com erro em vez de deixar texto misturado.
--  Linhas já gravadas (motivo_inativacao, resultado_final, auditoria) mantêm o texto de quando nasceram; em produção não há nenhuma.
--
--  Pode rodar de novo sem problema (na segunda vez não acha mais nada para trocar).
-- ════════════════════════════════════════════════════════════════════════

do $$
declare
  r      record;
  v_novo text;
  v_n    integer := 0;
begin
  for r in
    select p.oid, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and pg_get_functiondef(p.oid) ilike '%lista negra%'
     order by p.proname
  loop
    v_novo := pg_get_functiondef(r.oid);

    v_novo := replace(v_novo, 'Este candidato está na lista negra. Tire-o da lista negra antes de reativá-lo.',
                              'Este candidato está bloqueado. Remova o bloqueio antes de reativá-lo.');
    v_novo := replace(v_novo, 'Este candidato está na lista negra e não pode ser atribuído a vagas.',
                              'Este candidato está bloqueado e não pode ser atribuído a vagas.');
    v_novo := replace(v_novo, 'Este e-mail não está na lista negra.', 'Este e-mail não está bloqueado.');
    v_novo := replace(v_novo, 'Bloqueio na lista negra. Motivo: ', 'Bloqueio. Motivo: ');
    v_novo := replace(v_novo, 'Removido da lista negra', 'Bloqueio removido');
    v_novo := replace(v_novo, 'Candidato na lista negra', 'Candidato bloqueado');
    v_novo := replace(v_novo, '''Lista negra''', '''Bloqueado''');          -- candidatos.motivo_inativacao

    if v_novo ilike '%lista negra%' then
      raise exception 'A função % ainda cita "lista negra" depois das trocas: acrescente a frase que faltou em 044_bloqueios_nome.sql.', r.proname;
    end if;

    execute v_novo;                       -- create or replace: mantém dono, permissões e comentário
    v_n := v_n + 1;
  end loop;

  raise notice 'Bloqueios: % função(ões) com o texto atualizado', v_n;
end $$;
