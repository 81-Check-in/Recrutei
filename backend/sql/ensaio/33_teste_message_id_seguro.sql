-- Teste da trava contra Message-ID com caractere de controle embutido (056), a correção
-- da injeção de comando IMAP via cabeçalho "dobrado". Roda depois de 020–074.
-- Desde a 074 o banco LIMPA o valor antes de gravar (em vez de recusar o e-mail legítimo que veio "dobrado"); a garantia
-- continua a mesma: nenhum Message-ID gravado tem caractere de controle, e a constraint da 056 segue no lugar.
-- Tudo dentro de uma transação que termina em ROLLBACK: não deixa nada no banco.
\set ON_ERROR_STOP on
begin;

do $$
declare
  v text;
begin
  insert into excecoes (email_remetente, tipo, status, detalhe_erro, email_message_id)
  values ('teste@exemplo.com', 'sem_anexo', 'pendente', 'teste', E'abc\r\n A1 LOGOUT\r\n xyz@exemplo.com')
  returning email_message_id into v;
  assert v !~ '[[:cntrl:]]', 'Message-ID gravado não pode ter \r\n embutido';

  assert exists (select 1 from pg_constraint where conname = 'excecoes_message_id_sem_controle'),
    'a constraint da 056 continua valendo';
  assert exists (select 1 from pg_constraint where conname = 'curriculos_message_id_sem_controle'),
    'a constraint da 056 continua valendo';

  insert into excecoes (email_remetente, tipo, status, detalhe_erro, email_message_id)
  values ('teste@exemplo.com', 'sem_anexo', 'pendente', 'teste', 'abc123@exemplo.com');

  raise notice 'message_id_seguro: ok';
end $$;

rollback;
