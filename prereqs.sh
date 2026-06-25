#!/usr/bin/env bash
# Vérifie l'environnement (RAM, disque, Java 21, zstd, curl, jq) et dit quoi installer.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib-common.sh

echo "=== OS ===";   uname -srm
echo "=== RAM ===";  echo "  $(total_ram_gb) GB   (recommandé >= 48-64 GB pour Europe+BR+AR)"
echo "=== CPU ===";  echo "  $(ncpu) vCPU"
echo "=== Disque ($PWD) ==="; df -h "$PWD" | tail -1; echo "  (besoin ~80 GB libres : 13.5 dumps + ~50 index + staging)"

echo "=== Java 21+ ==="
if J=$(find_java); then echo "  OK: $J"; "$J" -version 2>&1 | head -1 | sed 's/^/  /'
else
  cat <<'EOF'
  ABSENT. Installe un JDK 21 :
    Debian/Ubuntu  : sudo apt-get update && sudo apt-get install -y openjdk-21-jdk-headless
    RHEL/Alma/Rocky: sudo dnf install -y java-21-openjdk-headless
  (ou pose un JDK ailleurs et exporte PHOTON_JAVA=/chemin/bin/java)
EOF
fi

echo "=== zstd ==="
if command -v zstd >/dev/null 2>&1; then echo "  OK: $(zstd --version 2>&1 | head -1)"
else echo "  ABSENT -> Debian: sudo apt-get install -y zstd | RHEL: sudo dnf install -y zstd"; fi

echo "=== curl / jq ==="
command -v curl >/dev/null 2>&1 && echo "  curl OK" || echo "  curl ABSENT -> sudo apt-get install -y curl"
command -v jq   >/dev/null 2>&1 && echo "  jq OK"   || echo "  jq ABSENT (requis par smoke-test.sh) -> sudo apt-get install -y jq"

echo
echo "Quand tout est OK : ./download.sh  (ou transférer les dumps) puis ./import.sh dans tmux."
