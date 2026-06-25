# RUNBOOK — Déployer Photon (Europe + BR + AR) sur une VM via Delinea

Objectif : construire en local sur la VM une base Photon couvrant **Europe + Brésil + Argentine**
et exposer l'endpoint `:2322`. La VM est la cible parce que **24 Go (le Mac) ne suffisent pas** —
détails dans [HANDOVER.md](HANDOVER.md).

## 0. Spécs VM requises

| Ressource | Minimum | Confort |
|-----------|---------|---------|
| RAM       | 48 Go   | **64 Go** |
| Disque libre | 80 Go | 100 Go (13.5 dumps + ~50 index + staging) |
| vCPU      | 4       | 8 |
| OS        | Linux x86_64 (Ubuntu/Debian/RHEL) | SSD/NVMe fortement conseillé |
| Outils    | Java 21, zstd, curl, jq, git, tmux | |

## 1. Accès via Delinea → **RÈGLE D'OR : tmux**

Tu arrives sur la VM par une session SSH **courtée par Delinea** (Secret Server / Connection
Manager / Platform). Ces sessions ont un **timeout d'inactivité** et peuvent se couper.
👉 L'import dure **1 à 3 h** : il **DOIT** tourner dans `tmux` (ou `screen`/`nohup`), sinon une
coupure de session tue l'import (et il **repart de zéro**).

```bash
tmux new -s photon        # crée la session
#   ... lancer l'import ici ...
# détacher sans tuer : Ctrl-b puis d
tmux attach -t photon     # se rattacher plus tard (même après reconnexion Delinea)
```

## 2. Récupérer le repo + vérifier l'environnement

```bash
git clone <url-du-repo> photon-geocoder    # ou copier le dossier (sans data/)
cd photon-geocoder
./prereqs.sh                               # installe ce qui manque (java21, zstd, jq)
```

Installation des dépendances si `prereqs.sh` les signale absentes :
```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y openjdk-21-jdk-headless zstd curl jq git tmux
# RHEL/Alma/Rocky
sudo dnf install -y java-21-openjdk-headless zstd curl jq git tmux
```

## 3. Obtenir les dumps (~13.5 Go)

**Cas A — la VM a internet (direct ou proxy) :**
```bash
export HTTPS_PROXY=http://proxy.entreprise:3128   # si proxy ; sinon ignorer
export HTTP_PROXY=$HTTPS_PROXY
./download.sh
```

**Cas B — VM isolée (pas d'internet, fréquent en environnement Delinea) :**
Télécharger ailleurs (poste avec accès) puis transférer dans `data/dumps/` :
```
https://download1.graphhopper.com/public/europe/photon-dump-europe-1.0-latest.jsonl.zst
https://download1.graphhopper.com/public/south-america/brazil/photon-dump-brazil-1.0-latest.jsonl.zst
https://download1.graphhopper.com/public/south-america/argentina/photon-dump-argentina-1.0-latest.jsonl.zst
+ le jar : https://github.com/komoot/photon/releases/download/1.2.0/photon-1.2.0.jar  -> data/
```
Transfert via le canal de fichiers Delinea, `scp`, ou un bucket interne. Ces dumps existent
**déjà sur le Mac** : `~/repos/photon-geocoder/data/dumps/` (13 Go) + `data/photon-1.2.0.jar`.

`import.sh` lance `zstd -t` sur chaque dump avant de commencer : un transfert tronqué est
détecté immédiatement (et non après 2 h d'import).

## 4. Import (dans tmux)

```bash
tmux new -s photon
./import.sh 2>&1 | tee data/import.log
# Ctrl-b d pour détacher ; l'import continue.
```
Réglages auto pour la VM : sur 64 Go, heap = 24g, threads = 2, langues = `en,fr,es,pt,de,it`.
Pour ajuster :
```bash
PHOTON_XMX=20g PHOTON_THREADS=4 ./import.sh        # plus de débit si la VM est costaude
```

Surveillance (autre fenêtre) :
```bash
grep -oE 'Imported [0-9]+ documents \[[0-9.]+/second\]' data/import.log | tail -3
free -h ; cat /proc/meminfo | grep -i swap        # le swap doit rester ~0
```

## 5. Servir + tester

```bash
tmux new -s photon-serve
./serve.sh                       # http://127.0.0.1:2322  (Ctrl-b d pour détacher)
```
Smoke test **sur la VM** :
```bash
./smoke-test.sh                  # doit ressortir Paris/Berlin/Roma/Madrid/Lisboa/São Paulo/Buenos Aires
```

Tester **depuis ton poste** (si Delinea autorise le port-forward SSH) :
```bash
ssh -L 2322:127.0.0.1:2322 <user>@<vm>     # via le bastion Delinea
# puis sur ton poste :
curl 'http://localhost:2322/api?q=Paris&limit=2'
```
Sinon, exposer sur le réseau de la VM (⚠️ sécurité) : `PHOTON_LISTEN_IP=0.0.0.0 ./serve.sh`.

## 6. Dépannage (tiré des essais sur 24 Go)

| Symptôme | Cause | Action |
|----------|-------|--------|
| `SocketTimeoutException: 30000ms` sur bulk | **swap** : heap trop gros vs RAM libre → les merges traînent | baisser `PHOTON_XMX`, libérer de la RAM ; le swap doit rester ~0 |
| Débit s'effondre à ~500 docs/s et n'avance plus | pas assez de **page cache** pour les merges | + de RAM (c'est LE point : 64 Go le règle) ; `PHOTON_THREADS=1` |
| Import meurt à la coupure Delinea | pas dans tmux | relancer **dans tmux** (repart de 0, non reprenable) |
| `Unknown document type 'NominatimDumpFile'. Ignored.` | normal (en-têtes en double de la concat) | rien, c'est attendu |
| Java introuvable | JDK absent/non-21 | `./prereqs.sh`, ou `export PHOTON_JAVA=/chemin/bin/java` |

## 7. Temps attendus (VM 64 Go, SSD)

Download ~13.5 Go (selon bande passante) · intégrité quelques min · **import ~1-3 h** ·
serveur prêt < 1 min · smoke test immédiat.
