-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Autocomplete de cidade no Banco de Talentos (053)
--
--  Rodar depois da 052. Pode rodar de novo sem problema.
--
--  "Cidade onde mora", "Endereço/bairro contém" e "Exceto quem mora em" eram texto livre, sem sugestão — o RH
--  digitava e torcia para acertar a grafia. vw_banco_opcoes (024, hoje só "area" e "cargo") ganha o tipo
--  "cidade" (mesma ideia: valor + quantos candidatos têm), para o painel oferecer uma lista clicável ao digitar
--  (banco-talentos.js, ligarAutocompleteLocal). Não existe "bairro" normalizado (é texto livre dentro do
--  currículo, sem coluna indexada) — por isso a sugestão é sempre de cidade, mesmo nos campos de endereço/bairro.
-- ════════════════════════════════════════════════════════════════════════

create or replace view public.vw_banco_opcoes with (security_invoker = true) as
select 'area'::text as tipo, c.area_sugerida as valor, count(*) as total
  from public.candidatos c where c.status_banco <> 'expurgado' and c.area_sugerida is not null
 group by c.area_sugerida
union all
select 'cargo', c.cargo_sugerido, count(*)
  from public.candidatos c where c.status_banco <> 'expurgado' and c.cargo_sugerido is not null
 group by c.cargo_sugerido
union all
select 'cidade', c.cidade, count(*)
  from public.candidatos c where c.status_banco <> 'expurgado' and c.cidade is not null
 group by c.cidade;
