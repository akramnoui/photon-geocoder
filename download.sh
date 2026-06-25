#!/usr/bin/env bash
# Télécharge le jar Photon 1.2.0 + les 3 dumps JSON (Europe, Brésil, Argentine).
# Reprise auto si coupé (curl -C -). Proxy d'entreprise : exporter HTTPS_PROXY / HTTP_PROXY.
# Si la VM n'a pas d'accès internet : voir RUNBOOK-VM.md (section "Pas d'internet : transfert").
set -euo pipefail
cd "$(dirname "$0")"

DATA="$PWD/data"; DUMPS="$DATA/dumps"
mkdir -p "$DUMPS"
BASE="https://download1.graphhopper.com/public"
CURL=(curl -fL -C - -S -s --retry 5 --retry-delay 5)

echo ">> Jar Photon 1.2.0..."
if [ -f "$DATA/photon-1.2.0.jar" ]; then echo "   déjà présent"; else
  "${CURL[@]}" -o "$DATA/photon-1.2.0.jar" \
    "https://github.com/komoot/photon/releases/download/1.2.0/photon-1.2.0.jar"
  echo "   OK"
fi

URLS=(
  "$BASE/europe/photon-dump-europe-1.0-latest.jsonl.zst"
  "$BASE/south-america/brazil/photon-dump-brazil-1.0-latest.jsonl.zst"
  "$BASE/south-america/argentina/photon-dump-argentina-1.0-latest.jsonl.zst"
)
for u in "${URLS[@]}"; do
  out="$DUMPS/$(basename "$u")"
  echo ">> $(basename "$u")..."
  "${CURL[@]}" -o "$out" "$u"
  echo "   OK $(du -h "$out" | cut -f1)"
done
echo ">> Terminé (~13.5 Go de dumps + jar). Vérif: ./import.sh fera 'zstd -t' avant d'importer."
