#!/usr/bin/env bash
# Iteração rápida no SQL: recria o banco "rec" (dados sintéticos antigos), aplica todas as migrações e roda os testes de
# SQL. Não mede desempenho, não reaplica e não ensaia o "zerar" — para isso use ensaio.sh. Deixa o contêiner no ar.
#   backend/sql/ensaio/rapido.sh            tudo
#   backend/sql/ensaio/rapido.sh 14         só os testes cujo nome começa com 14 (as migrações rodam sempre)
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../../.." && pwd)"
C=pg-ensaio-recrutei
PORTA_PG="${PORTA_PG:-55432}"
# shellcheck source=migracoes.sh
source "$AQUI/migracoes.sh"

psql_() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
sql()   { psql_ -d "$1" -f "/repo/backend/sql/$2"; }

if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run -d --name "$C" -e POSTGRES_PASSWORD=x -p "$PORTA_PG:5432" -v "$RAIZ":/repo:ro postgres:17-alpine >/dev/null
  # A imagem do Postgres sobe um servidor TEMPORÁRIO para inicializar e depois o definitivo: pg_isready responde já no
# primeiro. O definitivo só está pronto quando a mensagem "ready to accept connections" aparece pela segunda vez.
for _ in $(seq 1 90); do
  [[ "$(docker logs "$C" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ]] && docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
fi
if ! psql_ -At -c "select 1 from pg_database where datname='rec_base'" | grep -q 1; then
  psql_ -c "create database rec_base" >/dev/null
  sql rec_base ensaio/00_base.sql >/dev/null 2>&1; sql rec_base ensaio/01_views_rls.sql >/dev/null 2>&1; sql rec_base ensaio/02_dados.sql >/dev/null
fi
psql_ -c "drop database if exists rec with (force)" -c "create database rec template rec_base" >/dev/null

for f in "${MIGRACOES[@]}"; do
  saida="$(sql rec "$f" 2>&1)" || { echo "ERRO em $f"; echo "$saida" | grep -E "ERROR|DETAIL|HINT|LINE" | head; exit 1; }
done
echo "migrações aplicadas: ${#MIGRACOES[@]}"

filtro="${1:-}"
for t in "${TESTES_SQL[@]}"; do
  [[ -z "$filtro" || "$(basename "$t")" == "$filtro"* ]] || continue
  saida="$(sql rec "$t" 2>&1)" || { echo "FALHOU $t"; echo "$saida" | grep -E "ERROR|DETAIL|CONTEXT|HINT" | head; exit 1; }
  echo "$saida" | grep -E "NOTICE" | sed 's/^psql:[^ ]* //'
done
