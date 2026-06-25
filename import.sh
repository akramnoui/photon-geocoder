#!/usr/bin/env bash
# Construit la base Photon depuis TOUS les dumps de data/dumps/ (Europe + BR + AR).
# Méthode officielle (S. Hoffmann/lonvia, 2025-08) : concat naïve des dumps JSON -> import.
# L'importeur ignore les en-têtes en double (WARN inoffensif). + garde-fous: intégrité, bascule atomique.
#
# Réglages (env): PHOTON_XMX (défaut = ~40% RAM, max 24g)  PHOTON_THREADS (défaut 2)
#                 PHOTON_LANGS (défaut en,fr,es,pt,de,it)  PHOTON_JAVA (chemin java 21)
set -euo pipefail
cd "$(dirname "$0")"
. ./lib-common.sh

DATA="$PWD/data"; JAR="$DATA/photon-1.2.0.jar"; DUMPS_DIR="$DATA/dumps"; STAGING="$DATA/staging"
JAVA="$(find_java)" || { echo "Java 21+ introuvable. Lance ./prereqs.sh ou exporte PHOTON_JAVA=." >&2; exit 1; }
LANGS="${PHOTON_LANGS:-en,fr,es,pt,de,it}"
XMX="${PHOTON_XMX:-$(default_heap_g)g}"
THREADS="${PHOTON_THREADS:-2}"

[ -f "$JAR" ] || { echo "Jar absent ($JAR). Lance ./download.sh." >&2; exit 1; }
shopt -s nullglob
DUMPS=("$DUMPS_DIR"/*.jsonl.zst)
[ "${#DUMPS[@]}" -gt 0 ] || { echo "Aucun dump dans $DUMPS_DIR. Lance ./download.sh (ou copie-les)." >&2; exit 1; }

echo ">> Java   : $JAVA"
echo ">> Machine: RAM=$(total_ram_gb)G  vCPU=$(ncpu)  ->  heap=$XMX  threads=$THREADS  langs=$LANGS"
echo ">> Dumps (${#DUMPS[@]}):"; for f in "${DUMPS[@]}"; do echo "   - $(basename "$f")  $(du -h "$f" | cut -f1)"; done

echo ">> Contrôle d'intégrité (zstd -t)..."
for f in "${DUMPS[@]}"; do printf '   %-50s ' "$(basename "$f")"; zstd -t "$f" && echo OK; done

echo ">> Import vers $STAGING ..."
rm -rf "$STAGING"; mkdir -p "$STAGING"
SECONDS=0
zstd --stdout -d "${DUMPS[@]}" \
  | "$JAVA" --enable-native-access=ALL-UNNAMED -Xmx"$XMX" \
      -jar "$JAR" import -import-file - -data-dir "$STAGING" -languages "$LANGS" -j "$THREADS"

echo ">> Import OK en ${SECONDS}s. Bascule atomique..."
[ -d "$DATA/photon_data" ] && mv "$DATA/photon_data" "$DATA/photon_data.old.$$"
mv "$STAGING/photon_data" "$DATA/photon_data"
rmdir "$STAGING" 2>/dev/null || true
rm -rf "$DATA"/photon_data.old.* 2>/dev/null || true
echo ">> Base prête: $DATA/photon_data   ->  lance ./serve.sh"
