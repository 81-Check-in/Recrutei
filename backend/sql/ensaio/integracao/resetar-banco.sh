#!/usr/bin/env bash
# Refaz só o banco "rec" do ensaio (dados antigos sintéticos + migrações 020–025) e recarrega o schema do PostgREST.
# Use entre duas execuções do frontend.test.js: os testes atribuem, editam, inativam e excluem candidatos.
set -euo pipefail
C="${PG_CONTAINER:-pg-ensaio-recrutei}"
docker exec "$C" psql -U postgres -q -c "drop database if exists rec with (force)" -c "create database rec template rec_base"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$AQUI/../migracoes.sh"
for f in "${MIGRACOES[@]}"; do
  docker exec "$C" psql -U postgres -d rec -v ON_ERROR_STOP=1 -q -f "/repo/backend/sql/$f" >/dev/null 2>&1
done
docker kill -s USR1 postgrest-ensaio >/dev/null 2>&1 || true      # PostgREST relê o schema
sleep 2
