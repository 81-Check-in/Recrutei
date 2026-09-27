-- Testes do LINK DO CURRÍCULO NA EXCEÇÃO (039): a coluna só aceita http/https e o link dos avisos do Trabalha Brasil que já estão na
-- fila é tirado do HTML guardado. Roda depois de 020–039. Tudo dentro de uma transação que termina em ROLLBACK.
\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.deve_falhar(p_sql text, p_trecho text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_trecho in sqlerrm) = 0 then
      raise exception 'falhou com a mensagem errada. Esperado conter [%], veio [%]', p_trecho, sqlerrm;
    end if;
    return;
  end;
  raise exception 'deveria ter falhado (esperado: %)', p_trecho;
end $$;

-- avisos como estavam ANTES da coluna existir (sem link): a 039 reaplicada os completa
insert into excecoes (id, email_remetente, tipo, status, detalhe_erro, email_corpo) values
  ('00000000-0000-0000-0000-00000000e001', 'trabalhabrasil@trabalhabrasil.com.br', 'sem_anexo', 'pendente', 'E-mail sem anexo nem link de currículo',
   $h$Olá. Rafael Lins 28 anos<!DOCTYPE html><html><body><a href='https://events-api.bne.com.br/api/v1/events/tracking-event?evento=t&MessageId=1&url=http%3A%2F%2Fwww.trabalhabrasil.com.br%2Fvisualizar-curriculo%2Fu%3Fcurriculo%3DABC&sig=xyz'> <button style=' width: 10rem; height: 2rem; text-transform: uppercase;'>Ver perfil</button> </a>
      Se a vaga já estiver preenchida, <a href='https://events-api.bne.com.br/api/v1/events/tracking-event?url=administrar-vagas'> clique aqui </a> para inativá-la.</body></html>$h$),
  ('00000000-0000-0000-0000-00000000e002', 'candidata@gmail.com', 'sem_anexo', 'pendente', 'E-mail sem anexo nem link de currículo',
   $h$<a href='https://x.test/a'><button>Ver perfil</button></a>$h$),                                              -- candidata comum: não é plataforma
  ('00000000-0000-0000-0000-00000000e003', 'trabalhabrasil@trabalhabrasil.com.br', 'sem_anexo', 'ignorado', 'antigo',
   $h$<a href='https://events-api.bne.com.br/velho'><button>Ver perfil</button></a>$h$),                          -- já ignorado: fica como está
  ('00000000-0000-0000-0000-00000000e004', 'aviso@mail.trabalhabrasil.com.br', 'sem_anexo', 'pendente', 'E-mail sem anexo nem link de currículo',
   $h$<a href="https://events-api.bne.com.br/outro"><button>Ver perfil</button></a>$h$),                         -- subdomínio, aspas duplas
  ('00000000-0000-0000-0000-00000000e005', 'trabalhabrasil@trabalhabrasil.com.br', 'sem_anexo', 'pendente', 'E-mail sem anexo nem link de currículo',
   $h$<a href="javascript:alert(1)"><button>Ver perfil</button></a>$h$),                                         -- endereço que não é web: não vira link
  ('00000000-0000-0000-0000-00000000e006', 'nottrabalhabrasil@nottrabalhabrasil.com.br', 'sem_anexo', 'pendente', 'E-mail sem anexo nem link de currículo',
   $h$<a href='https://y.test/a'><button>Ver perfil</button></a>$h$);                                            -- domínio parecido: não é a plataforma

\i /repo/backend/sql/039_link_do_curriculo_na_excecao.sql

do $$
declare
  e1 constant uuid := '00000000-0000-0000-0000-00000000e001'; e2 constant uuid := '00000000-0000-0000-0000-00000000e002';
  e3 constant uuid := '00000000-0000-0000-0000-00000000e003'; e4 constant uuid := '00000000-0000-0000-0000-00000000e004';
  e5 constant uuid := '00000000-0000-0000-0000-00000000e005'; e6 constant uuid := '00000000-0000-0000-0000-00000000e006';
begin
  -- o link do "Ver perfil" foi tirado do HTML (e não o do "clique aqui", que inativa a vaga), com a mensagem nova
  assert (select link_curriculo from excecoes where id = e1) like 'https://events-api.bne.com.br/api/v1/events/tracking-event?evento=t&MessageId=1&url=%sig=xyz',
    'o link do "Ver perfil" é guardado inteiro, com os &';
  assert (select detalhe_erro from excecoes where id = e1) like '%Abrir currículo%', 'a mensagem passa a orientar o botão';
  assert (select link_curriculo from excecoes where id = e4) = 'https://events-api.bne.com.br/outro', 'subdomínio e aspas duplas também valem';
  -- o que não é aviso de plataforma pendente fica como estava
  assert (select link_curriculo is null and detalhe_erro like 'E-mail sem anexo%' from excecoes where id = e2), 'candidata comum: nada muda';
  assert (select link_curriculo is null and detalhe_erro = 'antigo' from excecoes where id = e3), 'ignorada: nada muda';
  assert (select link_curriculo is null from excecoes where id = e5), 'javascript: não vira link';
  assert (select link_curriculo is null from excecoes where id = e6), 'domínio parecido não é a plataforma';

  -- reaplicar não muda nada (idempotente)
  assert (select count(*) from excecoes where link_curriculo is not null and id in (e1, e2, e3, e4, e5, e6)) = 2, 'só os dois avisos válidos têm link';

  -- a trava: só http/https, sem espaço
  update excecoes set link_curriculo = 'https://portal.test/perfil?id=1&t=2' where id = e2;
  update excecoes set link_curriculo = 'http://portal.test/perfil' where id = e2;
  update excecoes set link_curriculo = null where id = e2;
  perform pg_temp.deve_falhar(format($f$update excecoes set link_curriculo = %L where id = %L$f$, 'javascript:alert(1)', e2), 'excecoes_link_curriculo_web');
  perform pg_temp.deve_falhar(format($f$update excecoes set link_curriculo = %L where id = %L$f$, 'ftp://portal.test/x', e2), 'excecoes_link_curriculo_web');
  perform pg_temp.deve_falhar(format($f$update excecoes set link_curriculo = %L where id = %L$f$, 'https://portal.test/a b', e2), 'excecoes_link_curriculo_web');
  perform pg_temp.deve_falhar(format($f$update excecoes set link_curriculo = %L where id = %L$f$, 'data:text/html,<script>', e2), 'excecoes_link_curriculo_web');
  perform pg_temp.deve_falhar(format($f$update excecoes set link_curriculo = %L where id = %L$f$, '', e2), 'excecoes_link_curriculo_web');

  raise notice 'TESTE DO LINK DO CURRÍCULO NA EXCEÇÃO: tudo certo';
end $$;

rollback;
