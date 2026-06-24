#!/usr/bin/env bash
# Démarre le serveur Photon sur http://localhost:2322
set -euo pipefail
cd "$(dirname "$0")"

JAVA="/opt/homebrew/opt/openjdk@21/bin/java"
DATA="$PWD/data"
XMX="${PHOTON_XMX:-4g}"

[ -d "$DATA/photon_data" ] || { echo "Pas de base — lance ./import.sh d'abord." >&2; exit 1; }
exec "$JAVA" --enable-native-access=ALL-UNNAMED -Xmx"$XMX" \
  -jar "$DATA/photon-1.2.0.jar" serve -data-dir "$DATA"
