-- Teste de vw_banco_opcoes ganhando o tipo "cidade" (053), pro autocomplete do Banco de Talentos. Roda depois de 020–053.
-- Tudo dentro de uma transação que termina em ROLLBACK: não deixa nada no banco.
\set ON_ERROR_STOP on
begin;

do $$
declare
  n int;
begin
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Teste Opcoes Um',  'Ceilândia', 'DF', 'hash-opc-cid-1');
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Teste Opcoes Dois', 'Ceilândia', 'DF', 'hash-opc-cid-2');
  insert into candidatos (nome, cidade, uf, hash_identidade) values ('Teste Opcoes Tres', 'Gama',      'DF', 'hash-opc-cid-3');

  select total into n from vw_banco_opcoes where tipo = 'cidade' and valor = 'Ceilândia';
  assert n >= 2, 'conta os candidatos ativos daquela cidade, got ' || coalesce(n::text, 'null');

  select count(*) into n from vw_banco_opcoes where tipo = 'cidade' and valor = 'Gama';
  assert n = 1, 'cada cidade aparece uma vez só, com sua contagem';

  raise notice 'opcoes_cidade: ok';
end $$;

rollback;
