#!/usr/bin/env bash
# Vérifie que les 3 régions répondent. Usage: ./smoke-test.sh [host:port]   (défaut 127.0.0.1:2322)
set -euo pipefail
HP="${1:-127.0.0.1:2322}"

q() {
  printf '  %-14s ' "$1"
  curl -s "http://$HP/api?q=$(printf %s "$2" | jq -sRr @uri)&limit=1" \
    | jq -r '.features[0] | if . then "\(.properties.name) — \(.properties.country) (\(.properties.countrycode))  \(.geometry.coordinates)" else "AUCUN RÉSULTAT" end'
}

echo "Photon @ $HP"
curl -fs "http://$HP/status" >/dev/null 2>&1 && echo "  status        OK" || { echo "  status        KO (serveur down ?)"; exit 1; }
q "France"      "Paris"
q "Allemagne"   "Berlin"
q "Italie"      "Roma"
q "Espagne"     "Madrid"
q "Portugal"    "Lisboa"
q "Brésil"      "São Paulo"
q "Argentine"   "Buenos Aires"
echo "Reverse (Buenos Aires):"
curl -s "http://$HP/reverse?lat=-34.6037&lon=-58.3816&limit=1" \
  | jq -r '.features[0].properties | "  \(.name) — \(.city // .state) \(.country) (\(.countrycode))"'
