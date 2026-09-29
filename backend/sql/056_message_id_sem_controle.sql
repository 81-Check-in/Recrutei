-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Trava de segurança no Message-ID gravado (056)
--
--  Rodar depois da 054. Pode rodar de novo sem problema.
--
--  Correção de segurança: um e-mail malicioso podia mandar o cabeçalho Message-ID
--  "dobrado" (RFC 5322 folding), embutindo um \r\n no meio do valor. Esse valor era
--  gravado sem filtro em email_message_id e, ao reprocessar uma exceção, ia direto
--  pro comando IMAP (conn.uid("SEARCH", "HEADER", "Message-ID", message_id)) — o
--  imaplib não escapa os argumentos, então o \r\n virava uma segunda linha de
--  comando na sessão autenticada (injeção de comando IMAP, podendo apagar a caixa).
--  O leitor_email.py já foi corrigido para nunca gravar/usar um valor assim; esta
--  migração garante o mesmo no banco, como segunda camada: limpa o que já estiver
--  gravado e barra qualquer valor futuro com caractere de controle.
-- ════════════════════════════════════════════════════════════════════════

-- limpa valores já gravados que tenham caractere de controle embutido (CR, LF, tab etc.)
update public.excecoes
   set email_message_id = regexp_replace(email_message_id, '[[:cntrl:]]', '', 'g')
 where email_message_id ~ '[[:cntrl:]]';

update public.curriculos
   set email_message_id = regexp_replace(email_message_id, '[[:cntrl:]]', '', 'g')
 where email_message_id ~ '[[:cntrl:]]';

alter table public.excecoes
  drop constraint if exists excecoes_message_id_sem_controle,
  add constraint excecoes_message_id_sem_controle
    check (email_message_id !~ '[[:cntrl:]]');

alter table public.curriculos
  drop constraint if exists curriculos_message_id_sem_controle,
  add constraint curriculos_message_id_sem_controle
    check (email_message_id !~ '[[:cntrl:]]');
