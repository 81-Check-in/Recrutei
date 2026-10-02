-- Testes do Message-ID limpo no banco (074). Roda depois de 020–074.
-- Tudo dentro de uma transação que termina em ROLLBACK: não deixa nada no banco.
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_cur uuid; v_exc uuid; s text;
begin
  insert into excecoes (email_remetente, tipo, status, detalhe_erro)
    values ('teste@exemplo.com', 'sem_anexo', 'pendente', 'teste') returning id into v_exc;
  select id into v_cur from curriculos limit 1;
  if v_cur is null then
    insert into curriculos (candidato_id, nome_arquivo, tipo_mime, origem, texto_extraido)
      values ((select id from candidatos limit 1), 'cv.pdf', 'application/pdf', 'anexo_pdf', 'Currículo de teste')
      returning id into v_cur;
  end if;

  -- valor "dobrado" do Outlook: o banco limpa em vez de recusar
  update curriculos set email_message_id = E'\r\n <YQ1P288MB118@prod.outlook.com>' where id = v_cur;
  select email_message_id into s from curriculos where id = v_cur;
  assert s = 'YQ1P288MB118@prod.outlook.com', 'currículo: Message-ID limpo, got ' || coalesce(s, 'null');

  update excecoes set email_message_id = E'\r\n\t<CPWPR80MB61@prod.outlook.com>' where id = v_exc;
  select email_message_id into s from excecoes where id = v_exc;
  assert s = 'CPWPR80MB61@prod.outlook.com', 'exceção: Message-ID limpo, got ' || coalesce(s, 'null');

  -- tentativa de injeção: a quebra de linha some, nada de controle chega ao banco
  update excecoes set email_message_id = E'<a@x>\r\nA1 DELETE INBOX' where id = v_exc;
  select email_message_id into s from excecoes where id = v_exc;
  assert s !~ '[[:cntrl:]]', 'nenhum caractere de controle gravado';

  -- só controle/espaço: vira null
  update curriculos set email_message_id = E'\r\n <>' where id = v_cur;
  assert (select email_message_id from curriculos where id = v_cur) is null, 'valor vazio vira null';

  -- valor normal não muda (a não ser os <> das pontas, como no robô)
  update curriculos set email_message_id = 'abc@mail.gmail.com' where id = v_cur;
  assert (select email_message_id from curriculos where id = v_cur) = 'abc@mail.gmail.com', 'valor limpo fica igual';

  raise notice 'message_id limpo: ok';
end $$;

rollback;
