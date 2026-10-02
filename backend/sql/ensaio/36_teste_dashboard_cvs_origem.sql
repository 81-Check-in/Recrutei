-- Testes do gráfico "CVs recebidos" por origem (076). Roda depois de 020–076.
-- Tudo dentro de uma transação que termina em ROLLBACK: não deixa nada no banco.
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_cand uuid; r record; antes_email bigint; s text;
begin
  -- os três agrupamentos devolvem o eixo inteiro, mesmo sem dados
  assert (select count(*) from dashboard_cvs_origem_serie('dia')) = 14, '14 dias';
  assert (select count(*) from dashboard_cvs_origem_serie('semana')) = 12, '12 semanas';
  assert (select count(*) from dashboard_cvs_origem_serie('mes')) = 12, '12 meses';

  -- sem o portal instalado (a tabela não existe no ensaio), a coluna do portal vem zerada, sem erro
  assert to_regclass('public.portal_inscricoes') is null, 'o ensaio não tem o portal';
  assert (select sum(pelo_portal) from dashboard_cvs_origem_serie('dia')) = 0, 'portal zerado sem a tabela';

  select por_email into antes_email from dashboard_cvs_origem_serie('dia') order by periodo desc limit 1;

  -- currículo de e-mail lido hoje entra; o envio manual do RH não
  select id into v_cand from candidatos limit 1;
  insert into curriculos (candidato_id, nome_arquivo, tipo_mime, origem, texto_extraido, recebido_em)
    values (v_cand, 'cv.pdf', 'application/pdf', 'anexo_pdf', 'Currículo por e-mail', now());
  insert into curriculos (candidato_id, nome_arquivo, tipo_mime, origem, texto_extraido, recebido_em)
    values (v_cand, 'cv2.pdf', 'application/pdf', 'upload_manual', 'Currículo enviado pelo RH', now());
  select por_email into r from dashboard_cvs_origem_serie('dia') order by periodo desc limit 1;
  assert r.por_email = antes_email + 1, 'só o currículo de e-mail conta, got ' || r.por_email || ' (antes ' || antes_email || ')';

  -- com o portal instalado: inscrição com currículo conta, sem currículo não
  create table public.portal_inscricoes (id uuid primary key default gen_random_uuid(), recebida_em timestamptz not null default now(), curriculo_path text);
  insert into portal_inscricoes (curriculo_path) values ('portal/2026/a.pdf'), ('portal/2026/b.pdf'), (null);
  select pelo_portal::text || '/' || por_email::text into s from dashboard_cvs_origem_serie('dia') order by periodo desc limit 1;
  assert s = '2/' || (antes_email + 1), 'portal conta 2 hoje e o e-mail não muda, got ' || s;
  assert (select sum(pelo_portal) from dashboard_cvs_origem_serie('mes')) = 2, 'o mês soma as inscrições';

  raise notice 'dashboard_cvs_origem: ok';
end $$;

rollback;
