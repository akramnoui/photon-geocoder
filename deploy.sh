#!/usr/bin/env bash
# ============================================================================
# Photon geocoder — déploiement MONO-VM, index Europe + Brésil + Argentine
# construit à partir des dumps JSON officiels GraphHopper. UN SEUL fichier.
#
# Usage :   ./deploy.sh [all|deps|fetch|import|serve|test|status]
#   all     deps + fetch + import   (puis lancer 'serve' à part)
#   deps    installe java 21 + zstd + curl + jq   (apt/dnf, sudo)
#   fetch   télécharge le jar + les 3 dumps (~13.5 Go, reprise auto, proxy via HTTPS_PROXY)
#   import  contrôle d'intégrité + import (concat naïve) + bascule atomique
#   serve   démarre le serveur (premier plan ; mettre dans tmux)
#   test    requête les 7 villes test (FR/DE/IT/ES/PT/BR/AR)
#   status  état (RAM, java, jar, dumps, index)
#
# VM via Delinea : la session peut couper -> TOUJOURS dans tmux :
#   tmux new -s photon ;  ./deploy.sh all ;  ./deploy.sh serve     (Ctrl-b d pour détacher)
#
# Pré-requis : Linux (apt/dnf) + sudo, ~64 Go RAM, ~80 Go disque libre, SSD/NVMe.
# /!\ 24 Go = INSUFFISANT pour toute l'Europe (swap puis crawl ~500 docs/s). Vise 64 Go.
#
# Réglages (variables d'env) : PHOTON_XMX  PHOTON_THREADS  PHOTON_LANGS  PHOTON_JAVA
#   PHOTON_LISTEN_IP  PHOTON_LISTEN_PORT  HTTPS_PROXY/HTTP_PROXY  PHOTON_FORCE=1
# ============================================================================
set -euo pipefail

PHOTON_HOME="${PHOTON_HOME:-$(cd "$(dirname "$0")" && pwd)}"
DATA="$PHOTON_HOME/data"; DUMPS="$DATA/dumps"
VERSION="${PHOTON_VERSION:-1.2.0}"
JAR="$DATA/photon-$VERSION.jar"
JAR_URL="https://github.com/komoot/photon/releases/download/$VERSION/photon-$VERSION.jar"
DUMP_BASE="https://download1.graphhopper.com/public"
DUMP_URLS=(
  "$DUMP_BASE/europe/photon-dump-europe-1.0-latest.jsonl.zst"
  "$DUMP_BASE/south-america/brazil/photon-dump-brazil-1.0-latest.jsonl.zst"
  "$DUMP_BASE/south-america/argentina/photon-dump-argentina-1.0-latest.jsonl.zst"
)
LANGS="${PHOTON_LANGS:-en,fr,es,pt,de,it}"
THREADS="${PHOTON_THREADS:-2}"
LISTEN_IP="${PHOTON_LISTEN_IP:-127.0.0.1}"
LISTEN_PORT="${PHOTON_LISTEN_PORT:-2322}"
SERVE_HEAP="${PHOTON_SERVE_XMX:-4g}"

log(){ printf '\033[1;34m>>\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31mERREUR:\033[0m %s\n' "$*" >&2; exit 1; }

ram_gb(){ if [ -r /proc/meminfo ]; then awk '/^MemTotal:/{printf "%d",$2/1048576}' /proc/meminfo; else echo $(( $(sysctl -n hw.memsize)/1073741824 )); fi; }
ncpu(){ command -v nproc >/dev/null 2>&1 && nproc || sysctl -n hw.ncpu; }
_fsize(){ stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }

# heap par défaut : ~40% RAM, plancher 8g, plafond 24g (évite le swap, garde du page cache pour les merges)
default_heap(){ local r h; r=$(ram_gb); h=$(( r*4/10 )); ((h<8))&&h=8; ((h>24))&&h=24; echo "${h}g"; }
HEAP="${PHOTON_XMX:-$(default_heap)}"

find_java(){
  local j v
  for j in "${PHOTON_JAVA:-}" "${JAVA_HOME:+$JAVA_HOME/bin/java}" "$(command -v java 2>/dev/null||true)" \
           /usr/lib/jvm/*/bin/java /opt/homebrew/opt/openjdk@21/bin/java; do
    [ -n "$j" ] && [ -x "$j" ] || continue
    v=$("$j" -version 2>&1 | head -1 | grep -oE '[0-9]+' | head -1) || continue
    [ -n "$v" ] && [ "$v" -ge 21 ] && { echo "$j"; return 0; }
  done
  return 1
}

dl(){ # dl <url> <out> : saute si déjà complet, sinon télécharge avec reprise
  local url="$1" out="$2" rsize
  rsize=$(curl -fsIL "$url" 2>/dev/null | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print v}')
  if [ -f "$out" ] && [ -n "$rsize" ] && [ "$(_fsize "$out")" = "$rsize" ]; then
    log "  déjà complet : $(basename "$out") ($(du -h "$out"|cut -f1))"; return 0
  fi
  curl -fL -C - --retry 5 --retry-delay 5 -S -s -o "$out" "$url"
  log "  OK : $(basename "$out") ($(du -h "$out"|cut -f1))"
}

deps(){
  log "Installation des dépendances (java 21, zstd, curl, jq)..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y openjdk-21-jdk-headless zstd curl jq
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y java-21-openjdk-headless zstd curl jq
  else
    die "Ni apt ni dnf — installe manuellement : Java 21, zstd, curl, jq."
  fi
  find_java >/dev/null || die "Java 21 introuvable après installation."
  log "Dépendances OK ($(find_java))."
}

fetch(){
  mkdir -p "$DUMPS"
  log "Téléchargement jar + dumps (proxy via HTTPS_PROXY/HTTP_PROXY si défini)..."
  dl "$JAR_URL" "$JAR"
  for u in "${DUMP_URLS[@]}"; do dl "$u" "$DUMPS/$(basename "$u")"; done
  log "Téléchargement terminé."
}

import(){
  local java; java=$(find_java) || die "Java 21 introuvable (lance : ./deploy.sh deps)."
  [ -f "$JAR" ] || die "Jar absent (lance : ./deploy.sh fetch)."
  shopt -s nullglob; local dumps=("$DUMPS"/*.jsonl.zst)
  [ "${#dumps[@]}" -gt 0 ] || die "Aucun dump dans $DUMPS (lance : ./deploy.sh fetch)."

  local r; r=$(ram_gb)
  log "Machine : RAM=${r}G  vCPU=$(ncpu)  ->  heap=$HEAP  threads=$THREADS  langs=$LANGS"
  if [ "$r" -lt 40 ] && [ -z "${PHOTON_FORCE:-}" ]; then
    die "RAM ${r}G < 40G : l'import Europe va swapper/crawler. Vise 64G, ou PHOTON_FORCE=1 pour forcer."
  fi

  log "Contrôle d'intégrité (zstd -t)..."
  for f in "${dumps[@]}"; do printf '   %-50s ' "$(basename "$f")"; zstd -t "$f" && echo OK; done

  log "Import (concaténation naïve des dumps -> staging) — peut durer 1-3 h..."
  rm -rf "$DATA/staging"; mkdir -p "$DATA/staging"
  local t0=$SECONDS
  zstd --stdout -d "${dumps[@]}" \
    | "$java" --enable-native-access=ALL-UNNAMED -Xmx"$HEAP" \
        -jar "$JAR" import -import-file - -data-dir "$DATA/staging" -languages "$LANGS" -j "$THREADS"

  log "Bascule atomique..."
  [ -d "$DATA/photon_data" ] && mv "$DATA/photon_data" "$DATA/photon_data.old.$$"
  mv "$DATA/staging/photon_data" "$DATA/photon_data"
  rm -rf "$DATA/staging" "$DATA"/photon_data.old.* 2>/dev/null || true
  log "Index prêt en $((SECONDS-t0))s : $DATA/photon_data   ->   ./deploy.sh serve"
}

serve(){
  local java; java=$(find_java) || die "Java 21 introuvable."
  [ -d "$DATA/photon_data" ] || die "Pas d'index (lance : ./deploy.sh import)."
  log "Serveur sur http://$LISTEN_IP:$LISTEN_PORT  (Ctrl-C pour arrêter ; Ctrl-b d pour détacher tmux)"
  exec "$java" --enable-native-access=ALL-UNNAMED -Xmx"$SERVE_HEAP" \
    -jar "$JAR" serve -data-dir "$DATA" -listen-ip "$LISTEN_IP" -listen-port "$LISTEN_PORT"
}

test_(){
  local hp="${1:-$LISTEN_IP:$LISTEN_PORT}" c
  curl -fs "http://$hp/status" >/dev/null 2>&1 || die "Serveur injoignable sur $hp (lancé ?)."
  echo "Photon @ $hp"
  for c in "France:Paris" "Allemagne:Berlin" "Italie:Roma" "Espagne:Madrid" "Portugal:Lisboa" "Brésil:São Paulo" "Argentine:Buenos Aires"; do
    printf '  %-12s ' "${c%%:*}"
    curl -s "http://$hp/api?q=$(printf %s "${c#*:}" | jq -sRr @uri)&limit=1" \
      | jq -r '.features[0] | if . then "\(.properties.name) — \(.properties.country) (\(.properties.countrycode))" else "AUCUN RÉSULTAT" end'
  done
}

status(){
  echo "PHOTON_HOME : $PHOTON_HOME"
  echo "RAM/CPU     : $(ram_gb)G / $(ncpu) vCPU   (heap import = $HEAP)"
  echo "java 21     : $(find_java || echo INTROUVABLE)"
  echo "jar         : $([ -f "$JAR" ] && echo présent || echo ABSENT)"
  echo "dumps       : $(ls "$DUMPS"/*.jsonl.zst 2>/dev/null | wc -l | tr -d ' ')/3"
  echo "index       : $([ -d "$DATA/photon_data" ] && du -sh "$DATA/photon_data" | cut -f1 || echo ABSENT)"
}

case "${1:-all}" in
  deps)   deps ;;
  fetch)  fetch ;;
  import) import ;;
  serve)  serve ;;
  test)   shift; test_ "$@" ;;
  status) status ;;
  all)    deps; fetch; import; log "Build terminé. Démarre le serveur : ./deploy.sh serve  (puis ./deploy.sh test)" ;;
  *)      echo "Usage: $0 [all|deps|fetch|import|serve|test|status]"; exit 1 ;;
esac
