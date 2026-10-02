-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — E-mail que falha 3 vezes é descartado (075)
--
--  Rodar depois da 074. Pode rodar de novo sem problema.
--
--  Um e-mail só continua não lido quando a leitura dá erro E nem a exceção consegue ser gravada (a fila do RH fica sem ele).
--  Antes ele era lido de novo a cada leitura, para sempre, pagando a IA toda vez (foi o que aconteceu com o Message-ID
--  "dobrado" entre 29/09 e 02/10). Agora cada falha é contada aqui; na 3ª o robô marca o e-mail como lido e desiste, e
--  nas leituras seguintes ele é pulado antes de qualquer extração ou chamada à IA.
--    • emails_tentativas — chave do e-mail (Message-ID, ou "uid:<UIDVALIDITY>:<UID>" sem ele), quantas falhas, o último erro e
--      quando foi descartado. Sem nome nem endereço do remetente. Só o robô (service_role) lê e escreve.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.emails_tentativas (
  chave          text primary key check (length(chave) between 1 and 1000 and chave !~ '[[:cntrl:]]'),
  tentativas     integer not null default 0 check (tentativas >= 0),
  ultimo_erro    text check (ultimo_erro is null or length(ultimo_erro) <= 500),
  assunto        text check (assunto is null or length(assunto) <= 300),
  recebido_em    timestamptz,
  primeira_falha timestamptz not null default now(),
  ultima_falha   timestamptz not null default now(),
  descartado_em  timestamptz
);
comment on table public.emails_tentativas is
  'Falhas de leitura por e-mail. Na 3ª o robô descarta o e-mail (marca como lido e não lê mais). Sem dados do remetente.';

alter table public.emails_tentativas enable row level security;      -- sem policy: só o service_role (o robô) acessa
revoke all on public.emails_tentativas from public, anon, authenticated;
grant select, insert, update, delete on public.emails_tentativas to service_role;
