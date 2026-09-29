-- Teste da trava contra Message-ID com caractere de controle embutido (056), a correção
-- da injeção de comando IMAP via cabeçalho "dobrado". Roda depois de 020–056.
-- Tudo dentro de uma transação que termina em ROLLBACK: não deixa nada no banco.
\set ON_ERROR_STOP on
begin;

do $$
declare
  falhou boolean;
begin
  begin
    insert into excecoes (email_remetente, tipo, status, detalhe_erro, email_message_id)
    values ('teste@exemplo.com', 'sem_anexo', 'pendente', 'teste', E'abc\r\n A1 LOGOUT\r\n xyz@exemplo.com');
    falhou := false;
  exception when check_violation then
    falhou := true;
  end;
  assert falhou, 'Message-ID com \r\n embutido tem de ser barrado pela constraint';

  insert into excecoes (email_remetente, tipo, status, detalhe_erro, email_message_id)
  values ('teste@exemplo.com', 'sem_anexo', 'pendente', 'teste', 'abc123@exemplo.com');

  raise notice 'message_id_seguro: ok';
end $$;

rollback;
