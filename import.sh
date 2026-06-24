#!/usr/bin/env bash
# Construit la base Photon depuis tous les dumps de data/dumps/.
# Méthode officielle (concat naïve) + garde-fous : intégrité zstd -t, bascule atomique.
set -euo pipefail
cd "$(dirname "$0")"

JAVA="/opt/homebrew/opt/openjdk@21/bin/java"
DATA="$PWD/data"
JAR="$DATA/photon-1.2.0.jar"
DUMPS_DIR="$DATA/dumps"
STAGING="$DATA/staging"
LANGS="${PHOTON_LANGS:-en,fr,es,pt,de,it}"
XMX="${PHOTON_XMX:-8g}"
THREADS="${PHOTON_THREADS:-$(sysctl -n hw.ncpu)}"

shopt -s nullglob
DUMPS=("$DUMPS_DIR"/*.jsonl.zst)
[ "${#DUMPS[@]}" -gt 0 ] || { echo "Aucun dump dans $DUMPS_DIR — lance ./download.sh d'abord." >&2; exit 1; }

echo ">> Contrôle d'intégrité (${#DUMPS[@]} dumps)..."
for f in "${DUMPS[@]}"; do printf '   %-55s ' "$(basename "$f")"; zstd -t "$f" && echo "OK"; done

echo ">> Import dans $STAGING (langs=$LANGS, xmx=$XMX, threads=$THREADS)..."
rm -rf "$STAGING"; mkdir -p "$STAGING"
zstd --stdout -d "${DUMPS[@]}" \
  | "$JAVA" --enable-native-access=ALL-UNNAMED -Xmx"$XMX" \
      -jar "$JAR" import -import-file - -data-dir "$STAGING" -languages "$LANGS" -j "$THREADS"

echo ">> Bascule atomique..."
[ -d "$DATA/photon_data" ] && mv "$DATA/photon_data" "$DATA/photon_data.old.$$"
mv "$STAGING/photon_data" "$DATA/photon_data"
rmdir "$STAGING" 2>/dev/null || true
rm -rf "$DATA"/photon_data.old.* 2>/dev/null || true
echo ">> Base prête : $DATA/photon_data"
