-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — E-mails ignorados não são lidos pela IA de novo (073)
--
--  Rodar depois da 072. Pode rodar de novo sem problema.
--
--  O reenvio de quem já está no Banco de Talentos é ignorado, mas só DEPOIS de a IA identificar a pessoa (uma chamada paga).
--  Como nada era gravado, o mesmo e-mail que continuasse não lido na caixa pagava essa chamada a cada leitura (de 10 em 10
--  minutos). Agora o Message-ID do e-mail ignorado fica aqui e a checagem de idempotência (database.email_ja_processado) o
--  barra antes de qualquer extração ou chamada à IA.
--    • emails_ignorados — só o identificador do e-mail, o motivo e a data: nenhum dado pessoal. Só o robô (service_role)
--      lê e escreve; o painel não usa.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.emails_ignorados (
  email_message_id text primary key
                     check (length(email_message_id) between 1 and 1000 and email_message_id !~ '[[:cntrl:]]'),
  motivo           text check (motivo is null or length(motivo) <= 300),
  criado_em        timestamptz not null default now()
);
comment on table public.emails_ignorados is
  'Message-ID dos e-mails que o robô leu e decidiu não importar (reenvio de quem já está no banco). Evita pagar a identificação da IA de novo pelo mesmo e-mail. Sem dados pessoais.';

alter table public.emails_ignorados enable row level security;      -- sem policy: só o service_role (o robô) acessa
revoke all on public.emails_ignorados from public, anon, authenticated;
grant select, insert, update, delete on public.emails_ignorados to service_role;
