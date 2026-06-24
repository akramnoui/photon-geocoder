#!/usr/bin/env bash
# Télécharge les dumps JSON Photon pour Europe + Brésil + Argentine.
# Reprend automatiquement un téléchargement interrompu (curl -C -).
set -euo pipefail
cd "$(dirname "$0")"

DUMPS="$PWD/data/dumps"
mkdir -p "$DUMPS"
BASE="https://download1.graphhopper.com/public"

URLS=(
  "$BASE/europe/photon-dump-europe-1.0-latest.jsonl.zst"
  "$BASE/south-america/brazil/photon-dump-brazil-1.0-latest.jsonl.zst"
  "$BASE/south-america/argentina/photon-dump-argentina-1.0-latest.jsonl.zst"
)

for u in "${URLS[@]}"; do
  out="$DUMPS/$(basename "$u")"
  echo ">> $(basename "$u")"
  curl -L -C - -S -s -o "$out" "$u"
  echo "   OK $(du -h "$out" | cut -f1)"
done
echo ">> Téléchargement terminé."
