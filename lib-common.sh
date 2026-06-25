#!/usr/bin/env bash
# Helpers partagés (Linux + macOS). À sourcer : . "$(dirname "$0")/lib-common.sh"

# Trouve un binaire Java >= 21. Priorité: $PHOTON_JAVA, $JAVA_HOME, PATH, emplacements connus.
find_java() {
  local cands=() j v
  [ -n "${PHOTON_JAVA:-}" ] && cands+=("$PHOTON_JAVA")
  [ -n "${JAVA_HOME:-}" ]   && cands+=("$JAVA_HOME/bin/java")
  cands+=("$(command -v java 2>/dev/null || true)")
  for j in /usr/lib/jvm/*/bin/java \
           /opt/homebrew/opt/openjdk@21/bin/java \
           /usr/local/opt/openjdk@21/bin/java \
           /Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java; do
    cands+=("$j")
  done
  for j in "${cands[@]}"; do
    [ -n "$j" ] && [ -x "$j" ] || continue
    v=$("$j" -version 2>&1 | head -1 | grep -oE '[0-9]+' | head -1) || continue
    if [ -n "$v" ] && [ "$v" -ge 21 ]; then echo "$j"; return 0; fi
  done
  return 1
}

# RAM totale en Go (entier).
total_ram_gb() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo
  else
    echo $(( $(sysctl -n hw.memsize) / 1073741824 ))
  fi
}

ncpu() { if command -v nproc >/dev/null 2>&1; then nproc; else sysctl -n hw.ncpu; fi; }

# Heap par défaut: ~40% de la RAM, plancher 8g, plafond 24g.
# Plafond 24g => garde les "compressed oops" (<32g) et laisse beaucoup de page cache
# pour les merges OpenSearch (c'est le page cache qui évite le crawl observé sur 24 Go).
default_heap_g() {
  local ram h
  ram=$(total_ram_gb)
  h=$(( ram * 4 / 10 ))
  [ "$h" -lt 8 ]  && h=8
  [ "$h" -gt 24 ] && h=24
  echo "$h"
}
