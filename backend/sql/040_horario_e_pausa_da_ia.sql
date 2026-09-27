-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Horário da rotina e PAUSA DE EMERGÊNCIA DA IA (040)
--
--  Rodar depois da 039. Pode rodar de novo sem problema.
--
--    • ia_pausada — o interruptor da "Zona de perigo" (Configurações). true = o robô e o servidor HTTP não enviam NADA à IA
--      (Anthropic). O que estiver em andamento para no próximo envio; e-mails, envios manuais e pedidos de análise ficam como
--      estão (nenhum currículo vira exceção nem se perde) e seguem quando a pausa for desfeita. O painel só ATUALIZA esta linha
--      (política config_escrita_admin: só administrador), por isso ela precisa existir.
--    • horario_execucao_pipeline — o campo já existia mas nada o lia. Agora o robô (python main.py --agendada, chamado a cada
--      15 minutos pelo Cron Schedule do Railway) só executa a partir deste horário, uma vez por dia, dentro de uma janela de 2 horas.
-- ════════════════════════════════════════════════════════════════════════

insert into public.configuracoes (chave, valor, descricao) values
  ('ia_pausada', 'false'::jsonb,
   'Zona de perigo: true = nada é enviado à IA (robô e servidor HTTP). Use só em emergência; desfazer é o mesmo botão.')
on conflict (chave) do nothing;

update public.configuracoes
   set descricao = 'Horário diário de leitura da caixa de e-mail (HH:MM, America/Sao_Paulo). O robô roda uma vez por dia, a partir deste horário, dentro de uma janela de 2 horas.'
 where chave = 'horario_execucao_pipeline';
