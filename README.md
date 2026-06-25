# photon-geocoder

Géocodeur **Photon 1.2.0** (OpenSearch embarqué) construit en local depuis les **dumps JSON**
officiels GraphHopper. Périmètre : **Europe + Brésil + Argentine**, dans **une seule base**.

> ⚠️ **Échelle.** Europe complète + BR + AR ≈ **40-60 M documents**. L'import (indexation +
> merges OpenSearch) **exige beaucoup de RAM**. Testé : **24 Go = insuffisant** (swap puis
> crawl à ~500 docs/s, voir [HANDOVER.md](HANDOVER.md)). Cible recommandée : **VM 48-64 Go**.
> Pour le déroulé sur VM (accès Delinea), voir **[RUNBOOK-VM.md](RUNBOOK-VM.md)**.

## Scripts

| Script | Rôle |
|--------|------|
| `prereqs.sh`    | Vérifie RAM/disque/Java 21/zstd/jq et dit quoi installer |
| `download.sh`   | Télécharge le jar + les 3 dumps (~13.5 Go, reprise auto, proxy via `HTTPS_PROXY`) |
| `import.sh`     | Intégrité `zstd -t` → import (concat naïve) → bascule atomique |
| `serve.sh`      | Démarre le serveur (`127.0.0.1:2322` par défaut) |
| `smoke-test.sh` | Requête les 7 villes test (FR/DE/IT/ES/PT/BR/AR) + un reverse |

Tous portables Linux/macOS (détection Java 21, RAM, nproc). Réglages par variables d'env :
`PHOTON_XMX` (heap, défaut ≈40 % RAM plafonné 24g), `PHOTON_THREADS` (défaut 2),
`PHOTON_LANGS` (défaut `en,fr,es,pt,de,it`), `PHOTON_JAVA` (chemin java 21).

## Démarrage rapide

```bash
./prereqs.sh                 # 1. contrôle env (installe java21/zstd/jq si besoin)
./download.sh                # 2. jar + 3 dumps  (ou transférer les dumps, cf RUNBOOK)
./import.sh                  # 3. import (LANCER DANS tmux sur une VM : peut durer 1-3 h)
./serve.sh                   # 4. serveur
./smoke-test.sh              # 5. validation des 3 régions
```

## Endpoint

`http://127.0.0.1:2322`

| Usage | Exemple |
|-------|---------|
| Recherche | `/api?q=Buenos+Aires&limit=3` |
| Reverse   | `/reverse?lat=-34.6037&lon=-58.3816` |
| Statut    | `/status` |

## Méthode d'import (officielle, 2025+)

Concaténer les dumps JSON et les piper dans `import` ; l'importeur ignore les en-têtes en
double. Source : [nominatim.org, 13/08/2025](https://nominatim.org/2025/08/13/photon-exports-renewed.html).
Pas de Nominatim, pas de fusion d'index. `import.sh` ajoute intégrité + bascule atomique
(car relancer `import` **écrase** la base, et l'import **n'est pas reprenable**).

## Données (gitignored, dans `data/`)

`data/photon-1.2.0.jar` · `data/dumps/*.jsonl.zst` · `data/photon_data/` (index) · `data/*.log`
