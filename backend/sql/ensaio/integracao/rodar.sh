#!/usr/bin/env bash
# Teste de INTEGRAÇÃO do painel: o frontend de verdade (jsdom) contra o Postgres migrado do ensaio, via PostgREST.
#   1. sobe o Postgres do ensaio migrado (ensaio.sh --manter) e o PostgREST em rede do host
#   2. roda frontend.test.js e depois banco_zerado.test.js (node:test) e derruba tudo
# Precisa de: Docker, Node 20+ e internet na primeira vez (npm install do jsdom e do supabase-js).
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSAIO="$AQUI/.."
PORTA_PG="${PORTA_PG:-55432}"
SEGREDO="super-secret-jwt-token-with-at-least-32-characters-long"
limpar() { docker rm -f postgrest-ensaio pg-ensaio-recrutei >/dev/null 2>&1 || true; }
trap limpar EXIT

[[ -d "$AQUI/node_modules" ]] || (cd "$AQUI" && npm install --no-audit --no-fund --loglevel=error)

"$ENSAIO/ensaio.sh" --manter | grep -E "TUDO CERTO|ERROR" || { echo "o ensaio SQL falhou"; exit 1; }

docker rm -f postgrest-ensaio >/dev/null 2>&1 || true
docker run -d --name postgrest-ensaio --network host \
  -e PGRST_DB_URI="postgres://authenticator:x@localhost:$PORTA_PG/rec" -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET="$SEGREDO" -e PGRST_SERVER_PORT=3000 postgrest/postgrest:latest >/dev/null
for _ in $(seq 1 30); do curl -s -m 2 -o /dev/null http://localhost:3000/ && break; sleep 1; done

cd "$AQUI"
JWT_SECRET="$SEGREDO" node --test frontend.test.js
# depois: o mesmo painel contra o banco ZERADO (zerar_banco_talentos.sql) — vem depois porque apaga tudo
JWT_SECRET="$SEGREDO" node --test banco_zerado.test.js
