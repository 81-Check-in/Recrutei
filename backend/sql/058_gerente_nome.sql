-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Nome do gerente de cada loja e do CR (058)
--
--  Rodar depois da 057. Pode rodar de novo sem problema.
--
--  Em Configurações → "WhatsApp dos gerentes" cada loja aparecia com o nome da LOJA. Agora aparece com o nome
--  do GERENTE, ao lado do número:  CFBS (Fulano de Tal)  +  WhatsApp.
--    • empresas.gerente_nome — nome do gerente da loja (o RH cadastra em Configurações).
--    • configuracoes.gerente_nome_cr — nome do gerente do CR (não há lojas no CR; um gerente atende todas).
--  Quem edita é o RH, igual ao número (config_escrita_gerente_cr, da 057, passa a cobrir as duas chaves do CR).
-- ════════════════════════════════════════════════════════════════════════

alter table public.empresas add column if not exists gerente_nome text;
comment on column public.empresas.gerente_nome is
  'Nome do gerente desta loja. Aparece em Configurações e na escolha da loja ao encaminhar um candidato. Vazio = mostra o nome da loja.';

insert into public.configuracoes (chave, valor, descricao) values
  ('gerente_nome_cr', to_jsonb(''::text), 'Nome do gerente do CR (aparece na escolha do destino ao encaminhar um candidato do CR).')
on conflict (chave) do nothing;

-- O nome é só texto exibido (o painel escapa o HTML), mas não deve ser um texto gigante.
create or replace function public.fn_valida_config_whatsapp()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.chave = 'gerente_whatsapp_cr'
     and (jsonb_typeof(new.valor) <> 'string'
          or new.valor #>> '{}' !~ '^([0-9+() -]{8,20})?$') then
    raise exception 'WhatsApp do gerente inválido: use só dígitos, +, espaço, parênteses e hífen (8 a 20 caracteres).';
  end if;
  if new.chave = 'gerente_nome_cr'
     and (jsonb_typeof(new.valor) <> 'string' or char_length(new.valor #>> '{}') > 80) then
    raise exception 'Nome do gerente inválido: texto de até 80 caracteres.';
  end if;
  return new;
end $$;

alter table public.empresas drop constraint if exists empresas_gerente_nome_tamanho;
alter table public.empresas add constraint empresas_gerente_nome_tamanho check (char_length(gerente_nome) <= 80);

drop policy if exists config_escrita_gerente_cr on public.configuracoes;
create policy config_escrita_gerente_cr on public.configuracoes
  for update to authenticated
  using      (chave in ('gerente_whatsapp_cr', 'gerente_nome_cr') and (select public.fn_usuario_ativo()))
  with check (chave in ('gerente_whatsapp_cr', 'gerente_nome_cr') and (select public.fn_usuario_ativo()));
