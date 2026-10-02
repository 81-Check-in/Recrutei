-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — O banco limpa o Message-ID em vez de recusar (074)
--
--  Rodar depois da 073. Pode rodar de novo sem problema.
--
--  A 056 barra Message-ID com caractere de controle (\r\n do "folding" do RFC 5322), segunda camada da defesa contra injeção
--  de comando IMAP. A primeira camada é o robô limpar o valor ao ler o e-mail (leitor_email._message_id_seguro). Um robô que
--  ainda não limpa (versão anterior a 29/09 no ar) mandava o valor cru, o banco recusava o currículo E a exceção, e o e-mail
--  ficava não lido para sempre: a cada leitura a IA era paga de novo pelo mesmo e-mail.
--    • fn_limpa_message_id — antes de gravar, faz o mesmo que _message_id_seguro: tira caracteres de controle e os "<> " das
--      pontas (vazio vira null). O valor gravado continua sem caractere de controle, então a trava da 056 segue valendo e
--      continua barrando qualquer outro caminho; só deixa de recusar o e-mail legítimo que veio "dobrado".
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.fn_limpa_message_id()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.email_message_id is not null then
    new.email_message_id := nullif(btrim(regexp_replace(new.email_message_id, '[[:cntrl:]]', '', 'g'), '<> '), '');
  end if;
  return new;
end $$;

drop trigger if exists trg_curriculos_limpa_message_id on public.curriculos;
create trigger trg_curriculos_limpa_message_id
  before insert or update of email_message_id on public.curriculos
  for each row execute function public.fn_limpa_message_id();

drop trigger if exists trg_excecoes_limpa_message_id on public.excecoes;
create trigger trg_excecoes_limpa_message_id
  before insert or update of email_message_id on public.excecoes
  for each row execute function public.fn_limpa_message_id();
