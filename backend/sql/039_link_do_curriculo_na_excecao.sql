-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Fila de Exceção · LINK DO CURRÍCULO NA PLATAFORMA (039)
--
--  Rodar depois da 038. Pode rodar de novo sem problema.
--
--  Plataformas de vagas que a empresa usa para captar currículos (Trabalha Brasil) mandam um AVISO por e-mail: o currículo
--  não vem no e-mail, só o link "Ver perfil" para a plataforma. O pipeline guarda esse link na exceção (backend/config.py,
--  PORTAIS_DE_CURRICULO) e o painel mostra o botão "Abrir currículo" no lugar de "Ver e-mail" e "Reprocessar": o RH abre a
--  plataforma, baixa o currículo e o envia por "Enviar currículo".
--
--    • excecoes.link_curriculo — o endereço (só http/https: o texto vem de terceiros e o painel o usa em um botão)
-- ════════════════════════════════════════════════════════════════════════

alter table public.excecoes add column if not exists link_curriculo text;
comment on column public.excecoes.link_curriculo is
  'Endereço do currículo em uma plataforma de vagas (ex.: "Ver perfil" do Trabalha Brasil), tirado do e-mail de aviso. O painel mostra "Abrir currículo". Só http/https.';

alter table public.excecoes drop constraint if exists excecoes_link_curriculo_web;
alter table public.excecoes add constraint excecoes_link_curriculo_web
  check (link_curriculo is null or link_curriculo ~* '^https?://[^[:space:]]+$');

-- Avisos do Trabalha Brasil que já estão na fila (antes desta coluna): o link sai do próprio HTML guardado, do botão "Ver perfil".
-- Só as pendentes; o que já foi revisado ou ignorado não é mexido.
update public.excecoes e
   set link_curriculo = x.link,
       detalhe_erro   = 'Aviso do Trabalha Brasil: o currículo está na plataforma, não no e-mail. Clique em "Abrir currículo", baixe o currículo lá e envie por "Enviar currículo".'
  from (select id, (regexp_match(email_corpo, 'href=[''"]([^''"]+)[''"][^>]*>\s*<button[^>]*>\s*Ver perfil', 'i'))[1] as link
          from public.excecoes
         where status = 'pendente' and tipo = 'sem_anexo' and link_curriculo is null
           and email_remetente ~* '@([a-z0-9-]+\.)*trabalhabrasil\.com\.br$') x
 where e.id = x.id and x.link ~* '^https?://[^[:space:]]+$';
