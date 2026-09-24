#!/usr/bin/env bash
# Ensaia as migrações do Banco de Talentos (020–025) em um Postgres 17 DESCARTÁVEL, no Docker.
# Nada aqui toca o Supabase: o banco é uma réplica mínima do schema de produção (00_base.sql,
# 01_views_rls.sql) com dados SINTÉTICOS (02_dados.sql).
#
# O que ele faz, na ordem:
#   1. sobe o Postgres e monta a "produção de mentira" (schema + 116 candidaturas de teste)
#   2. aplica 020 → 025 e roda os testes de regras e de sanitização
#   3. reaplica 021 → 025 (têm que ser idempotentes) e roda os testes de novo
#   4. aplica 020 → 025 num banco SEM dados (instalação nova)
#   5. mede o desempenho da busca com 50 mil candidatos (20_teste_desempenho.sql)
#   6. ensaia o script de zerar (zerar_banco_talentos.sql): a trava, o que some, o que fica, a fila do Storage
#
# Para testar também o PAINEL contra este banco (frontend de verdade + PostgREST): integracao/rodar.sh
#
# Uso:  backend/sql/ensaio/ensaio.sh            (apaga o container ao final)
#       backend/sql/ensaio/ensaio.sh --manter   (deixa o container no ar para você mexer: docker exec -it pg-ensaio-recrutei psql -U postgres -d rec)
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../../.." && pwd)"
C=pg-ensaio-recrutei
PORTA_PG="${PORTA_PG:-55432}"        # o Postgres do ensaio fica acessível em localhost:$PORTA_PG (usado pelo teste de integração)
MANTER=0; [[ "${1:-}" == "--manter" ]] && MANTER=1

psql_() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
sql()   { psql_ -d "$1" -f "/repo/backend/sql/$2"; }
passo() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
limpar() { [[ $MANTER -eq 1 ]] || docker rm -f "$C" >/dev/null 2>&1 || true; }
trap limpar EXIT

command -v docker >/dev/null || { echo "Precisa do Docker."; exit 1; }
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=x -p "$PORTA_PG:5432" -v "$RAIZ":/repo:ro postgres:17-alpine >/dev/null
# A imagem do Postgres sobe um servidor TEMPORÁRIO para inicializar e depois o definitivo: pg_isready responde já no
# primeiro. O definitivo só está pronto quando a mensagem "ready to accept connections" aparece pela segunda vez.
for _ in $(seq 1 90); do
  [[ "$(docker logs "$C" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ]] && docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

passo "1. Produção de mentira (schema + dados sintéticos)"
psql_ -c "create database rec_vazio" -c "create database rec_base"
sql rec_vazio ensaio/00_base.sql;  sql rec_vazio ensaio/01_views_rls.sql          # instalação nova: sem dados
sql rec_base  ensaio/00_base.sql;  sql rec_base  ensaio/01_views_rls.sql; sql rec_base ensaio/02_dados.sql | tail -8
psql_ -c "create database rec template rec_base"

# shellcheck source=migracoes.sh
source "$AQUI/migracoes.sh"

passo "2. Migrações (ver migracoes.sh) sobre os dados antigos"
for f in "${MIGRACOES[@]}"; do echo "   $f"; sql rec "$f" 2>&1 | grep -E "NOTICE:  (Candidat)|ERROR" || true; done
passo "   Testes de regras e de sanitização"
for t in "${TESTES_SQL[@]}"; do sql rec "$t" 2>&1 | grep -E "NOTICE|ERROR"; done

passo "3. Reaplicando 021 → última (idempotência)"
for f in "${MIGRACOES[@]:1}"; do echo "   $f"; sql rec "$f" 2>&1 | grep -E "ERROR" || true; done
for t in "${TESTES_SQL[@]}"; do sql rec "$t" 2>&1 | grep -E "NOTICE|ERROR"; done
psql_ -d rec -At -c "select 'candidatos: ' || count(*) || ' | candidaturas: ' || (select count(*) from candidaturas) || ' (devem ser os mesmos da 1ª execução)' from candidatos"

passo "4. Instalação nova (banco sem dados)"
for f in "${MIGRACOES[@]}"; do sql rec_vazio "$f" 2>&1 | grep -E "ERROR" || true; done
echo "   ok: todas as migrações aplicam em banco vazio"

passo "5. Desempenho da busca (50 mil candidatos)"
psql_ -c "create database rec_carga template rec" >/dev/null
sql rec_carga ensaio/20_teste_desempenho.sql 2>&1 | grep -E "NOTICE|ERROR|ms"

passo "6. Zerar o banco (zerar_banco_talentos.sql)"
psql_ -c "create database rec_zerar template rec" >/dev/null
sql rec_zerar ensaio/12_zerar_preparar.sql | tail -3
contar() { psql_ -d rec_zerar -At -c "select (select count(*) from candidatos) || '/' || (select count(*) from candidaturas) || '/' || (select count(*) from curriculos)"; }
ANTES="$(contar)"
SCRIPT_ZERAR="$RAIZ/backend/sql/zerar_banco_talentos.sql"
[[ "$(grep -c "'NAO', true" "$SCRIPT_ZERAR")" == 1 ]] || { echo "ERRO: a trava do script deveria aparecer uma única vez"; exit 1; }
# 6a. com a trava em NAO (como vem no arquivo) NADA pode mudar
if psql_ -d rec_zerar < "$SCRIPT_ZERAR" >/dev/null 2>&1; then echo "ERRO: zerou com a trava em NAO"; exit 1; fi
[[ "$(contar)" == "$ANTES" ]] || { echo "ERRO: a trava em NAO não impediu a exclusão ($ANTES → $(contar))"; exit 1; }
echo "   ok: com a trava em NAO nada foi apagado ($ANTES candidatos/candidaturas/currículos)"
# 6b. com a trava em SIM: apaga o que devia, guarda o que devia
sed "s/'NAO', true/'SIM', true/" "$SCRIPT_ZERAR" | psql_ -d rec_zerar 2>&1 | grep -E "NOTICE|ERROR"
sql rec_zerar ensaio/13_zerar_conferir.sql 2>&1 | grep -E "NOTICE|ERROR"
# 6c. rodar de novo não pode dar erro nem apagar nada além
sed "s/'NAO', true/'SIM', true/" "$SCRIPT_ZERAR" | psql_ -d rec_zerar >/dev/null 2>&1 || { echo "ERRO: a 2ª execução falhou"; exit 1; }
[[ "$(contar)" == "0/0/0" ]] || { echo "ERRO: o banco não ficou zerado ($(contar))"; exit 1; }
echo "   ok: repetir o script é seguro"

passo "TUDO CERTO"
[[ $MANTER -eq 1 ]] && echo "Container no ar: docker exec -it $C psql -U postgres -d rec   (ou localhost:$PORTA_PG, usuário postgres, senha x)"
