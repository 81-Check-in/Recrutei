-- ═══════════════════════════════════════════════════════════
--  RECRUTEI — Robô em tempo (quase) real: tela Status e janela de leitura (046)
--
--  Rodar depois da 045. Pode rodar de novo sem problema (não zera o andamento nem desfaz o que o administrador configurou).
--
--    • pipeline_status — UMA linha com o andamento do robô: o estado (ocioso, processando, fora do horário, pausado, erro), quantos
--      e-mails aguardam, quantos ele está processando agora, a última e a próxima leitura e o sinal de vida (verificado_em). Só o robô
--      escreve (chave de serviço, que ignora o RLS); o painel só lê, e só usuário ativo (tela Status). lease_dono/lease_ate são a
--      reserva do trabalho: impedem que duas instâncias do robô (um deploy que sobrepõe a velha e a nova) leiam a caixa em dobro.
--    • leitura_intervalo_minutos, leitura_hora_inicio, leitura_hora_fim, leitura_dias_semana — a janela em que o robô lê a caixa
--      (Configurações). Substituem horario_execucao_pipeline e pipeline_ultima_execucao_diaria: a leitura única por dia acabou.
-- ═══════════════════════════════════════════════════════════

create table if not exists public.pipeline_status (
  id                     boolean primary key default true check (id),      -- só existe a linha "true"
  estado                 text not null default 'ocioso'
                           check (estado in ('ocioso', 'processando', 'fora_do_horario', 'pausado', 'erro')),
  atividade              text,                                             -- o que está fazendo agora, em uma frase
  verificado_em          timestamptz not null default now(),               -- último sinal de vida do robô
  nao_lidos              integer check (nao_lidos is null or nao_lidos >= 0),   -- e-mails que a próxima leitura pegaria
  nao_lidos_em           timestamptz,                                      -- de quando é essa contagem
  processando_total      integer not null default 0 check (processando_total >= 0),
  processando_feitos     integer not null default 0 check (processando_feitos >= 0),
  processando_desde      timestamptz,
  ultima_checagem_em     timestamptz,                                      -- quando o robô olhou a caixa pela última vez, mesmo sem nada a ler (o intervalo conta daqui)
  ultima_leitura_em      timestamptz,                                      -- quando a última leitura COM e-mails a tratar começou
  ultima_leitura_fim     timestamptz,
  ultima_leitura_sucesso boolean,
  ultima_leitura_resumo  jsonb,                                            -- emails_lidos, curriculos_processados, excecoes_geradas, ...
  proxima_leitura_em     timestamptz,
  ultimo_erro            text,
  ultimo_erro_em         timestamptz,
  lease_dono             text,
  lease_ate              timestamptz,
  atualizado_em          timestamptz not null default now()
);
comment on table public.pipeline_status is
  'Andamento do robô para a tela Status: uma linha só, escrita pelo robô (chave de serviço) e lida pelo painel.';

insert into public.pipeline_status (id) values (true) on conflict (id) do nothing;

alter table public.pipeline_status enable row level security;
drop policy if exists pipeline_status_leitura on public.pipeline_status;
create policy pipeline_status_leitura on public.pipeline_status
  for select to authenticated using (public.fn_usuario_ativo());
revoke all on public.pipeline_status from anon, authenticated;
grant select on public.pipeline_status to authenticated;

insert into public.configuracoes (chave, valor, descricao) values
  ('leitura_intervalo_minutos', '10'::jsonb,
   'De quantos em quantos minutos o robô lê os e-mails não lidos, dentro da janela (de 1 a 240).'),
  ('leitura_hora_inicio', '"07:30"'::jsonb,
   'Hora (HH:MM, America/Sao_Paulo) em que o robô começa a ler a caixa de e-mail nos dias configurados.'),
  ('leitura_hora_fim', '"18:00"'::jsonb,
   'Hora (HH:MM, America/Sao_Paulo) em que o robô para de ler: a leitura das 18:00 já não acontece. Tem de ser depois do início.'),
  ('leitura_dias_semana', '[1,2,3,4,5,6]'::jsonb,
   'Dias da semana em que o robô lê a caixa: 1 = segunda ... 7 = domingo. Padrão: segunda a sábado.')
on conflict (chave) do nothing;

-- a leitura única por dia acabou: o horário diário e o marcador do último dia lido não valem mais
delete from public.configuracoes where chave in ('horario_execucao_pipeline', 'pipeline_ultima_execucao_diaria');
