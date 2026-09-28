-- Testes dos filtros de e-mail, telefone e cargos com experiência (048). Termina em ROLLBACK.
-- Roda depois de 020–048 (filtrar_banco_talentos vem da 024; a 048 a reescreve com os três filtros novos).
\set ON_ERROR_STOP on
begin;

-- candidato com currículo atual; retorna o id. O nome é único por teste para conferir "quem veio".
create or replace function pg_temp.cand(p_nome text, p_email text, p_fone text, p_e164 text, p_envio text, p_texto text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into candidatos (nome, email, telefone, telefone_e164) values (p_nome, p_email, p_fone, p_e164) returning id into v;
  insert into curriculos (candidato_id, origem, texto_extraido, email_envio) values (v, 'anexo_pdf', p_texto, p_envio);
  return v;
end $$;
-- nomes que a busca devolveu, ordenados (só os candidatos deste teste: começam com "T48 ")
create or replace function pg_temp.quem(p_filtros jsonb) returns text language sql as $$
  select coalesce(string_agg(nome, ',' order by nome), '-') from filtrar_banco_talentos(p_filtros) where nome like 'T48 %'
$$;

do $$
declare
  a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; g uuid; h uuid;
  total_antes int; s text;
begin
  -- ── massa ──
  -- A: e-mail do cadastro = do currículo; enviou do mesmo endereço; telefone com DDD, guardado normalizado também
  a := pg_temp.cand('T48 Ana',   'Ana.Souza@Gmail.com', '(61) 99999-1234', '5561999991234', 'ana.souza@gmail.com',
        E'DADOS PESSOAIS\nAna Souza\nOBJETIVO\nBuscar vaga de repositor\nEXPERIÊNCIA PROFISSIONAL\nOperadora de Caixa na Loja X (2019-2022)\nFORMAÇÃO\nEnsino médio');
  -- B: enviou de OUTRO endereço (o do cadastro é do currículo); telefone sem máscara e sem DDI
  b := pg_temp.cand('T48 Bia',   'bia@empresa.com.br', '61988887777', null, 'bia.pessoal@hotmail.com',
        E'Bia Lima\nHISTÓRICO PROFISSIONAL\nAçougueiro na Padaria Y (2018-2023)\nCursos\nManipulação de alimentos');
  -- C: só o telefone normalizado (o cru veio vazio); sem e-mail de envio (upload manual)
  c := pg_temp.cand('T48 Caio',  null, null, '5561977776666', null,
        E'Caio Nunes\nObjetivo: operador de empilhadeira\nExperiência profissional\nRepositor de mercadorias (2020-2024)');
  -- D: currículo sem título de experiência (procura no texto todo)
  d := pg_temp.cand('T48 Duda',  'duda@x.com', '61 3333-2222', '556133332222', 'duda@x.com',
        E'Duda Prado, 30 anos. Trabalhei como fiscal de caixa e como estoquista por 5 anos.');
  -- E: menciona o cargo só no objetivo (não tem experiência nele)
  e := pg_temp.cand('T48 Edu',   'edu@x.com', '61955554444', '5561955554444', 'edu@x.com',
        E'Edu Melo\nObjetivo profissional: trabalhar como açougueiro\nExperiências profissionais\nAuxiliar administrativo (2021-2023)');
  -- F: reenviou o currículo de outro endereço; o antigo (não atual) tinha o endereço antigo
  f := pg_temp.cand('T48 Flavia','flavia@x.com', '61944443333', '5561944443333', 'flavia.nova@x.com', 'Flavia. Experiência profissional: Padeira');
  insert into curriculos (candidato_id, origem, texto_extraido, email_envio, atual)
    values (f, 'anexo_pdf', 'Flavia (versão antiga)', 'flavia.antiga@yahoo.com', false);
  -- G: sem nenhum dado de contato nem texto útil
  g := pg_temp.cand('T48 Gil', null, null, null, null, 'Gil');

  -- ── nada preenchido: comportamento de sempre ──
  assert (select count(*) from filtrar_banco_talentos('{}'::jsonb) where nome like 'T48 %') = 7, 'sem filtro devolve todos';
  assert pg_temp.quem('{"email":"","telefone":"","cargos_experiencia":[]}') = 'T48 Ana,T48 Bia,T48 Caio,T48 Duda,T48 Edu,T48 Flavia,T48 Gil',
    'campos vazios não filtram';
  assert pg_temp.quem('{"telefone":"abc () -"}') = 'T48 Ana,T48 Bia,T48 Caio,T48 Duda,T48 Edu,T48 Flavia,T48 Gil', 'telefone sem nenhum número não filtra';
  assert pg_temp.quem('{"email":"   "}') = 'T48 Ana,T48 Bia,T48 Caio,T48 Duda,T48 Edu,T48 Flavia,T48 Gil', 'e-mail em branco não filtra';

  -- ── E-MAIL: o do cadastro (currículo) e o de quem enviou; maiúsculas não importam; pedaço serve ──
  assert pg_temp.quem('{"email":"ana.souza@gmail.com"}') = 'T48 Ana', 'e-mail completo (cadastro tem maiúsculas: Ana.Souza@Gmail.com)';
  assert pg_temp.quem('{"email":"ANA.SOUZA@GMAIL.COM"}') = 'T48 Ana', 'digitar em maiúsculas dá o mesmo';
  assert pg_temp.quem('{"email":"gmail"}') = 'T48 Ana', 'pedaço do domínio';
  assert pg_temp.quem('{"email":"bia@empresa"}') = 'T48 Bia', 'e-mail que está no currículo (cadastro), diferente do de envio';
  assert pg_temp.quem('{"email":"bia.pessoal"}') = 'T48 Bia', 'e-mail de quem ENVIOU o currículo, diferente do cadastro';
  assert pg_temp.quem('{"email":"hotmail"}') = 'T48 Bia', 'pedaço do endereço de envio';
  assert pg_temp.quem('{"email":"flavia.nova"}') = 'T48 Flavia', 'envio do currículo atual';
  assert pg_temp.quem('{"email":"flavia.antiga"}') = 'T48 Flavia', 'envio de um currículo ANTIGO do mesmo candidato também vale';
  assert pg_temp.quem('{"email":"x.com"}') = 'T48 Duda,T48 Edu,T48 Flavia', 'vários candidatos com o mesmo domínio';
  assert pg_temp.quem('{"email":"naoexiste@nada.com"}') = '-', 'ninguém';
  assert pg_temp.quem('{"email":"  gmail  "}') = 'T48 Ana', 'espaços nas pontas são ignorados';

  -- ── TELEFONE: só os números; máscara, DDD e DDI não atrapalham; pedaço serve ──
  assert pg_temp.quem('{"telefone":"(61) 99999-1234"}') = 'T48 Ana', 'digitado com máscara';
  assert pg_temp.quem('{"telefone":"61999991234"}') = 'T48 Ana', 'só números';
  assert pg_temp.quem('{"telefone":"999991234"}') = 'T48 Ana', 'sem o DDD';
  assert pg_temp.quem('{"telefone":"+55 61 99999-1234"}') = 'T48 Ana', 'com o DDI';
  assert pg_temp.quem('{"telefone":"1234"}') = 'T48 Ana', 'só o final';
  assert pg_temp.quem('{"telefone":"88887777"}') = 'T48 Bia', 'telefone guardado sem máscara e sem normalizado';
  assert pg_temp.quem('{"telefone":"(61) 98888-7777"}') = 'T48 Bia', 'digitado com máscara, guardado sem';
  assert pg_temp.quem('{"telefone":"5561977776666"}') = 'T48 Caio', 'só o telefone normalizado existe';
  assert pg_temp.quem('{"telefone":"977776666"}') = 'T48 Caio', 'pedaço do normalizado';
  assert pg_temp.quem('{"telefone":"3333-2222"}') = 'T48 Duda', 'fixo guardado com máscara (61 3333-2222)';
  assert pg_temp.quem('{"telefone":"00000000"}') = '-', 'ninguém';
  assert pg_temp.quem('{"telefone":"9999"}') = 'T48 Ana', 'trecho do meio';

  -- ── CARGOS COM EXPERIÊNCIA: sem maiúsculas/acentos; pedaço serve; do título de experiência em diante ──
  assert pg_temp.quem('{"cargos_experiencia":["operador de caixa"]}') = '-', 'a Ana foi "Operadora": o cargo digitado no masculino não acha o feminino inteiro';
  assert pg_temp.quem('{"cargos_experiencia":["operadora de caixa"]}') = 'T48 Ana', 'cargo com experiência';
  assert pg_temp.quem('{"cargos_experiencia":["OPERADORA DE CAIXA"]}') = 'T48 Ana', 'maiúsculas não importam';
  assert pg_temp.quem('{"cargos_experiencia":["acougueiro"]}') = 'T48 Bia',
    'sem acento acha "Açougueiro" (histórico profissional); Edu só QUER ser açougueiro (objetivo) e não entra';
  assert pg_temp.quem('{"cargos_experiencia":["AÇOUGUEIRO"]}') = 'T48 Bia', 'com acento e maiúsculas também';
  assert pg_temp.quem('{"cargos_experiencia":["repositor"]}') = 'T48 Caio', 'Ana só QUER repositor (objetivo): não entra; Caio foi repositor';
  assert pg_temp.quem('{"cargos_experiencia":["empilhadeira"]}') = '-', 'cargo citado só no objetivo não conta';
  assert pg_temp.quem('{"cargos_experiencia":["fiscal de caixa"]}') = 'T48 Duda', 'currículo sem título de experiência: procura no texto todo';
  assert pg_temp.quem('{"cargos_experiencia":["auxiliar administrativo"]}') = 'T48 Edu', 'Edu tem experiência como auxiliar administrativo';
  assert pg_temp.quem('{"cargos_experiencia":["padeira"]}') = 'T48 Flavia', 'título "Experiência profissional" no meio da linha';
  assert pg_temp.quem('{"cargos_experiencia":["repositor","acougueiro"]}') = 'T48 Bia,T48 Caio', 'vários cargos: qualquer um deles';
  assert pg_temp.quem('{"cargos_experiencia":["  repositor  "]}') = 'T48 Caio', 'espaços nas pontas são ignorados';
  assert pg_temp.quem('{"cargos_experiencia":["astronauta"]}') = '-', 'ninguém';

  -- ── o recorte do currículo (trecho_de_experiencia) ──
  assert trecho_de_experiencia('objetivo: repositor. experiencia profissional: caixa') = 'experiencia profissional: caixa', 'corta o que vem antes do título';
  assert trecho_de_experiencia('sem titulo nenhum, trabalhei de caixa') = 'sem titulo nenhum, trabalhei de caixa', 'sem título: o texto todo';
  assert trecho_de_experiencia('a. historico profissional: x. experiencia profissional: y') = 'historico profissional: x. experiencia profissional: y',
    'vale o PRIMEIRO título que aparecer, qualquer que seja';
  assert trecho_de_experiencia('experiencias profissionais: a') = 'experiencias profissionais: a' and trecho_de_experiencia('trajetoria profissional b') = 'trajetoria profissional b',
    'plural e outros títulos';
  assert trecho_de_experiencia(null) is null and trecho_de_experiencia('') = '', 'nulo e vazio não quebram';
  assert not has_function_privilege('anon', 'public.trecho_de_experiencia(text)', 'execute')
     and has_function_privilege('authenticated', 'public.trecho_de_experiencia(text)', 'execute'), 'só usuário logado executa';

  -- ── combinados entre si e com os filtros que já existiam ──
  assert pg_temp.quem('{"email":"x.com","cargos_experiencia":["padeira"]}') = 'T48 Flavia', 'e-mail + cargo';
  assert pg_temp.quem('{"email":"x.com","telefone":"5555-4444"}') = 'T48 Edu', 'e-mail + telefone';
  assert pg_temp.quem('{"email":"gmail","telefone":"7777"}') = '-', 'e-mail de um e telefone de outro: ninguém';
  assert pg_temp.quem('{"palavras":["caixa"],"cargos_experiencia":["operadora"]}') = 'T48 Ana', 'palavras-chave + cargo';
  assert pg_temp.quem('{"local":"padaria","cargos_experiencia":["acougueiro"]}') = 'T48 Bia', 'local + cargo (o texto "Padaria Y" está no currículo do Bia)';
  assert pg_temp.quem('{"palavras":["repositor"],"cargos_experiencia":["repositor"]}') = 'T48 Caio', 'a palavra-chave acha quem só cita; o cargo, quem teve';
  assert pg_temp.quem('{"palavras":["repositor"]}') = 'T48 Ana,T48 Caio', 'palavras-chave continuam achando a menção no objetivo (sem mudança)';

  -- ── a view ainda serve e o resto da função segue igual ──
  select count(*) into total_antes from filtrar_banco_talentos('{"rotatividade":"alta"}'::jsonb);
  assert total_antes >= 0, 'filtro de rotatividade continua funcionando';
  assert (select count(*) from filtrar_banco_talentos('{"palavras":["caixa"]}'::jsonb) where nome = 'T48 Ana') = 1, 'palavras-chave sem mudança';

  -- ── permissões: como antes (usuário logado executa; anônimo não) ──
  assert has_function_privilege('authenticated', 'public.filtrar_banco_talentos(jsonb)', 'execute'), 'usuário logado executa';
  assert not has_function_privilege('anon', 'public.filtrar_banco_talentos(jsonb)', 'execute'), 'anônimo não executa';

  raise notice 'TESTE DOS FILTROS DE E-MAIL, TELEFONE E CARGOS: tudo certo';
end $$;

rollback;
