#!/usr/bin/env bash
# Démarre le serveur Photon. Par défaut écoute 127.0.0.1:2322 (tester en local sur la VM,
# ou via tunnel SSH). Pour exposer sur le réseau: PHOTON_LISTEN_IP=0.0.0.0 (attention sécurité).
set -euo pipefail
cd "$(dirname "$0")"
. ./lib-common.sh

DATA="$PWD/data"
JAVA="$(find_java)" || { echo "Java 21+ introuvable. Lance ./prereqs.sh." >&2; exit 1; }
XMX="${PHOTON_SERVE_XMX:-4g}"
IP="${PHOTON_LISTEN_IP:-127.0.0.1}"
PORT="${PHOTON_LISTEN_PORT:-2322}"

[ -d "$DATA/photon_data" ] || { echo "Pas de base ($DATA/photon_data). Lance ./import.sh." >&2; exit 1; }
echo ">> Photon serve sur http://$IP:$PORT  (heap=$XMX)"
exec "$JAVA" --enable-native-access=ALL-UNNAMED -Xmx"$XMX" \
  -jar "$DATA/photon-1.2.0.jar" serve -data-dir "$DATA" -listen-ip "$IP" -listen-port "$PORT"
