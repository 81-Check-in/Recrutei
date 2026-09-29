-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Nova mensagem de convocação do WhatsApp (067)
--
--  Rodar depois da 066. Pode rodar de novo sem problema.
--
--  Troca o texto padrão da convocação. Marcadores aceitos: {nome}, {gestor}, {data}, {dia}, {hora}, {vaga}.
-- ════════════════════════════════════════════════════════════════════════

insert into public.configuracoes (chave, valor, descricao) values
  ('mensagem_convocacao_padrao', to_jsonb(
    E'Olá!\nSou do RH da Home Center Castelo Forte.\n\n'
    'Recebi seu currículo e estamos com vagas em aberto para {vaga}. Você tem interesse em participar de uma entrevista?\n\n'
    'Caso tenha interesse, comparecer *{dia}* ({hora}), na loja da Samambaia Sul.\n\n'
    'Localização: https://g.co/kgs/aCQqY2\n\n'
    'Trazer RG e Reservista, ir para a recepção e avisar que veio para a entrevista.\n\n'
    'Favor, confirmar a presença em caso de interesse.'::text),
   'Texto sugerido ao agendar a entrevista. Marcadores: {nome}, {gestor}, {data}, {dia}, {hora}, {vaga}.')
on conflict (chave) do update set valor = excluded.valor;
