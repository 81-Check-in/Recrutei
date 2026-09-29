-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Sigla da Capital Atacadista passa de ATACADISTA para CAPITAL (059)
--
--  Rodar depois da 058. Pode rodar de novo sem problema.
-- ════════════════════════════════════════════════════════════════════════

update public.empresas
   set sigla = 'CAPITAL'
 where upper(sigla) = 'ATACADISTA'
   and not exists (select 1 from public.empresas where upper(sigla) = 'CAPITAL');
