# HANDOVER — Photon geocoder (Europe + BR + AR), pour une autre instance de Claude

Lis ce fichier en entier avant d'agir. Il contient le quoi, le pourquoi, et les pièges déjà
rencontrés. But : éviter à la prochaine instance de refaire les erreurs des 5 dernières heures.

## 1. Mission

Déployer un géocodeur **Photon 1.2.0** local couvrant **Europe + Brésil + Argentine dans une
seule base**, indexé depuis les **dumps JSON** officiels GraphHopper. L'utilisateur veut
**tester l'import/indexation** (pas juste servir une base prête).

Tâche **indépendante** du repo principal AMS-PUDO (ne pas mélanger). Tout vit dans le repo
dédié `photon-geocoder`.

## 2. État actuel (au moment du handover)

- Repo dédié créé et committé : `~/repos/photon-geocoder` (sur le Mac de l'utilisateur).
- Scripts **portables Linux/macOS** + doc + ce handover : prêts.
- **Aucun process en cours** (tous les imports ont été arrêtés proprement).
- **Dumps déjà téléchargés sur le Mac** : `~/repos/photon-geocoder/data/dumps/` (**13 Go**) +
  `data/photon-1.2.0.jar` (91 Mo). `data/` est gitignored → à transférer séparément.
- **Décision prise** : l'import de toute l'Europe **échoue sur 24 Go** → on bascule sur une
  **VM 48-64 Go accessible via Delinea**. Le prochain run se fait là-bas (voir RUNBOOK-VM.md).

## 3. Photon en bref + la BONNE méthode

- Photon 1.2.0, **OpenSearch embarqué** (pas de DB externe à monter). **Java 21+ requis.**
- CLI à sous-commandes : `import`, `serve`, `dump-nominatim-db`, `update`. (L'ancien
  `-nominatim-import` n'existe plus en 1.x.)
- Serveur : `:2322`. Base sur disque dans `data/photon_data`.
- **Méthode officielle multi-régions (S. Hoffmann/lonvia, [13/08/2025](https://nominatim.org/2025/08/13/photon-exports-renewed.html)) :
  concaténer les dumps JSON et les piper dans `import`.**
  ```bash
  zstd --stdout -d data/dumps/*.jsonl.zst | java -jar photon.jar import -import-file - -languages ...
  ```
  L'importeur **ignore** les en-têtes `NominatimDumpFile` en double (juste un `WARN`). Vérifié.
  ⚠️ Les vieux fils GitHub #721/#751 disent "il faut Nominatim" — **périmés**, ignore-les.
- Format des dumps : NDJSON ; ligne 1 = `NominatimDumpFile` (en-tête), ligne 2 = `CountryInfo`
  (liste mondiale), lignes 3+ = `Place`. Dumps **`-1.0-`** = format lu par le jar 1.2.0.

## 4. Ce qu'on a appris en dur (NE PAS refaire)

1. **Pipeline validé** : Andorre + Malte (40 808 docs) importés et servis sans souci →
   la méthode concat marche, le problème de l'Europe est **uniquement une question d'échelle**.
2. **24 Go = insuffisant pour toute l'Europe.** 3 tentatives, **toutes mortes/bloquées au même
   point ~3,2-3,3 M docs** :
   - Run 1 (`-Xmx8g -j10`) et Run 2 (`-Xmx10g -j2`) : **crash `SocketTimeoutException 30000ms`**
     sur une bulk. Cause = **swap** (heap trop gros vs RAM dispo → page-out → un merge
     OpenSearch dépasse 30 s → la bulk timeout). Preuve run 2 : swap monté à 7,9 Go.
   - Run 3 (`-Xmx8g -j1`, swap ~0) : **pas de crash** mais le débit s'effondre 20 000 → ~500
     docs/s pendant les gros merges. Projeté ≈ **15 h** pour finir → pas tenable.
3. **Diagnostic** : le mur n'est ni le heap ni les threads (il ne bouge pas avec). C'est le
   **manque de RAM** : (a) si heap trop gros → swap → timeout ; (b) sinon → pas assez de page
   cache pour les merges de segments → crawl. Le README Photon le dit : **« 64 Go recommandés »**
   et **« make sure the system doesn't start swapping »**. 64 Go règle les deux.
4. **Pas de réglage CLI** pour le timeout 30 s ni la taille de bulk (10 000 docs, en dur). On ne
   peut pas contourner par la config → il faut juste **assez de RAM**.
5. **L'import n'est pas reprenable** : `import` **efface** toute base existante et repart de 0.
   D'où : (a) toujours dans **tmux** sur la VM ; (b) `import.sh` importe dans `staging` puis
   **bascule atomique** pour ne pas détruire une base valide en cas d'échec.

## 5. Inventaire du repo

```
photon-geocoder/
├── README.md           # vue d'ensemble + quick start
├── RUNBOOK-VM.md       # procédure pas-à-pas sur la VM (Delinea, tmux, proxy/transfert)
├── HANDOVER.md         # ce fichier
├── lib-common.sh       # helpers: find_java(21+), total_ram_gb, ncpu, default_heap_g
├── prereqs.sh          # contrôle env + commandes d'install
├── download.sh         # jar + 3 dumps (reprise, proxy HTTPS_PROXY)
├── import.sh           # intégrité zstd -t -> concat naïve -> import -> bascule atomique
├── serve.sh            # serveur 127.0.0.1:2322 (PHOTON_LISTEN_IP/PORT)
├── smoke-test.sh       # 7 villes (FR/DE/IT/ES/PT/BR/AR) + reverse
├── build.sh            # download + import enchaînés
└── data/               # GITIGNORED : jar, dumps/, photon_data/, *.log
```
Réglages communs (env) : `PHOTON_XMX`, `PHOTON_THREADS`, `PHOTON_LANGS`, `PHOTON_JAVA`,
`PHOTON_LISTEN_IP/PORT`. Défaut heap = ~40 % RAM plafonné 24 g (cf `lib-common.sh`).

## 6. Prochaines étapes (sur la VM)

Suivre **RUNBOOK-VM.md**. En résumé :
```bash
cd photon-geocoder && ./prereqs.sh
# dumps : ./download.sh (avec proxy) OU transférer data/dumps/ depuis le Mac
tmux new -s photon
./import.sh 2>&1 | tee data/import.log     # ~1-3 h sur 64 Go ; Ctrl-b d pour détacher
./serve.sh                                  # puis :
./smoke-test.sh
```

## 7. Décisions de l'utilisateur (à respecter)

- ✅ Veut **Europe + Brésil + Argentine COMPLETS, dans UNE base**, via **import** de dumps JSON.
- ❌ **Refuse** les dumps **par pays** (pas de découpage France/Espagne/etc.).
- ❌ **Refuse** la **base pré-construite** (`photon-db-*.tar.bz2`) — il veut tester l'import.
  (Pour info : `photon-db-europe-1.0-latest.tar.bz2` = 28,6 Go existe, mais écarté par l'user,
  et de toute façon non fusionnable avec BR/AR.)
- ➡️ Conséquence logique, déjà actée : **machine 48-64 Go** pour faire l'import.

## 8. Pièges à connaître

- **tmux obligatoire** sur la VM (sessions Delinea coupent → import non reprenable perdu).
- **Le swap doit rester ~0** pendant l'import (`free -h`). S'il monte → baisser `PHOTON_XMX`.
- Si re-crash `SocketTimeout` malgré 64 Go : `PHOTON_THREADS=1`, vérifier qu'on n'est pas sur
  disque lent (le README parle d'« erreurs cryptiques sur disque rotatif » → exiger SSD/NVMe).
- Disque : prévoir ~80 Go (13.5 dumps + ~50 index + staging + bascule).
- `Unknown document type 'NominatimDumpFile'. Ignored.` = **normal** (concat), pas une erreur.
- Ne pas committer `data/` (volumineux, déjà gitignored).

## 9. Commandes clés

```bash
./prereqs.sh                                   # contrôle env
HTTPS_PROXY=... ./download.sh                  # récup jar+dumps (ou transfert manuel)
PHOTON_XMX=24g PHOTON_THREADS=2 ./import.sh    # import (dans tmux)
./serve.sh                                     # serveur :2322
./smoke-test.sh                                # validation 3 régions
# état import : grep -oE 'Imported [0-9]+ documents \[[0-9.]+/second\]' data/import.log | tail
```
