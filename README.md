# photon-geocoder

Déploiement **mono-VM** d'un géocodeur **Photon 1.2.0** (OpenSearch embarqué), index
**Europe + Brésil + Argentine** construit à partir des **dumps JSON** GraphHopper.

**Un seul fichier** : [`deploy.sh`](deploy.sh).

## Usage (sur la VM, via Delinea)

La session Delinea peut couper → tout dans **tmux** (l'import dure 1-3 h et **ne reprend pas**) :

```bash
tmux new -s photon
./deploy.sh all        # deps (java21/zstd/jq) + fetch (~13.5 Go) + import (1-3 h)
./deploy.sh serve      # serveur sur http://127.0.0.1:2322   (Ctrl-b d pour détacher tmux)
./deploy.sh test       # valide Paris/Berlin/Roma/Madrid/Lisboa/São Paulo/Buenos Aires
```

Sous-commandes : `deps | fetch | import | serve | test | status` (cf. en-tête de `deploy.sh`).

Réglages par variables d'env : `PHOTON_XMX` (heap, défaut ≈40 % RAM plafonné 24g),
`PHOTON_THREADS` (2), `PHOTON_LANGS` (`en,fr,es,pt,de,it`), `PHOTON_JAVA`,
`PHOTON_LISTEN_IP/PORT`, `HTTPS_PROXY` (proxy d'entreprise), `PHOTON_FORCE=1`.

## Pré-requis VM

Linux (apt/dnf) + sudo · **64 Go RAM** · ~80 Go disque libre · SSD/NVMe · accès internet
(ou proxy ; sinon copier les dumps dans `data/dumps/` à la main).

## Pourquoi 64 Go (et pas 24)

Europe+BR+AR ≈ 40-60 M docs. Testé sur 24 Go : **échec systématique vers 3,3 M docs** —
soit crash `SocketTimeoutException` (heap trop gros → **swap** → les merges OpenSearch
dépassent les 30 s), soit, sans swap, **effondrement du débit à ~500 docs/s** (pas assez de
page cache pour les merges) → ~15 h projetées. Le README officiel Photon recommande **64 Go**
et « ne jamais swapper ». La RAM est le seul vrai levier ; ni le heap ni les threads ne
déplacent ce mur. `deploy.sh` refuse de démarrer sous 40 Go (sauf `PHOTON_FORCE=1`).

## Méthode d'import (officielle)

Concaténer les dumps JSON et les piper dans `import` ; l'importeur ignore les en-têtes en
double (`WARN` inoffensif). Source : [nominatim.org, 13/08/2025](https://nominatim.org/2025/08/13/photon-exports-renewed.html).
Pas de Nominatim, pas de fusion d'index. `deploy.sh` ajoute intégrité (`zstd -t`) + bascule
atomique (l'`import` **écrase** la base existante et **n'est pas reprenable**).

Dumps utilisés (format `-1.0-`, lu par le jar 1.2.0) :
`europe`, `south-america/brazil`, `south-america/argentina` sous
`https://download1.graphhopper.com/public/`.

## Endpoint

`http://127.0.0.1:2322` — `/api?q=Buenos+Aires&limit=3` · `/reverse?lat=-34.6&lon=-58.4` · `/status`.
Depuis ton poste : tunnel `ssh -L 2322:127.0.0.1:2322 …` via le bastion Delinea.

`data/` (jar, dumps, index) est gitignored.
