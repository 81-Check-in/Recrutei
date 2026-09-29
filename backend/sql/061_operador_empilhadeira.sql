-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Nova função: Logística / Operador de Empilhadeira (061)
--
--  Rodar depois da 060. Pode rodar de novo sem problema.
--
--  Vale para as vagas e para a qualificação da IA (o catálogo é lido de funcoes_setor). Níveis: Júnior, Pleno e Sênior
--  (aceita_iniciante = false: Jovem Aprendiz e Trainee não existem para este cargo).
-- ════════════════════════════════════════════════════════════════════════

insert into public.funcoes_setor (setor_id, nome, aceita_iniciante)
select s.id, 'Operador de Empilhadeira', false
  from public.setores s
 where s.nome = 'Logística'
on conflict (setor_id, nome) do update set ativo = true, aceita_iniciante = false;
