#!/usr/bin/env bash
# Teste l'endpoint. Usage: ./query.sh "Buenos Aires"
set -euo pipefail
q="${1:-Paris}"
curl -s "http://localhost:2322/api?q=$(printf %s "$q" | jq -sRr @uri)&limit=5" \
  | jq -r '.features[] | "\(.properties.name) — \(.properties.city // .properties.state // "") \(.properties.country) (\(.properties.countrycode))  [\(.geometry.coordinates | map(tostring) | join(", "))]"'
