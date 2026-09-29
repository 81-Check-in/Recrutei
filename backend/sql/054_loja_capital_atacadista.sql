-- ════════════════════════════════════════════════════════════════════════
--  RECRUTEI — Loja Capital Atacadista (054)
--
--  Rodar depois da 053. Pode rodar de novo sem problema.
--
--  Loja à parte, quase sem demanda de vaga. Fica disponível pra marcar como empresa de uma vaga (modal de
--  vaga, frontend/js/vagas.js já lista TODAS as empresas ativas — nada a mudar lá), mas o chip "Distância em
--  relação a" do Banco de Talentos (banco-talentos.js, montarLojasRanking) só deve mostrá-la quando a vaga
--  selecionada estiver mesmo vinculada a ela — ao contrário das lojas de sempre, que continuam aparecendo
--  sempre. `padrao_distancia` é essa marcação: true (default, não muda nada pras lojas existentes) = sempre
--  aparece no chip; false = só aparece quando a vaga está em vaga_empresas com essa loja.
-- ════════════════════════════════════════════════════════════════════════

alter table public.empresas
  add column if not exists padrao_distancia boolean not null default true;
comment on column public.empresas.padrao_distancia is
  'true = sempre aparece no chip de distância do Banco de Talentos. false = só aparece quando a vaga está vinculada a essa loja (vaga_empresas)';

-- Coordenadas exatas informadas pelo RH (Taguatinga: 15°51''51"S 48°01''49"W) — ponto direto, sem
-- depender de região (mesma ideia de latitude/longitude "opcional: ponto exato da loja" da 030).
insert into public.empresas (sigla, nome, latitude, longitude, padrao_distancia)
select 'ATACADISTA', 'Capital Atacadista', -15.864167, -48.030278, false
where not exists (select 1 from public.empresas where upper(sigla) = 'ATACADISTA');
