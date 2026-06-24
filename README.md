# photon-geocoder

Géocodeur **Photon 1.2.0** (basé OpenSearch embarqué) tournant en local, indexé depuis
les **dumps JSON** officiels GraphHopper. Périmètre de ce déploiement : **Europe + Brésil + Argentine**.

## Prérequis (déjà présents sur ce poste)

- **Java 21** : `/opt/homebrew/opt/openjdk@21/bin/java` (`brew install openjdk@21`)
- **zstd** : `brew install zstd`
- ~70 GB de disque libre (dumps ~13.5 GB + index ~40–55 GB)

## Démarrage

```bash
./download.sh   # télécharge les 3 dumps (~13.5 GB, reprise auto si coupé)
./import.sh     # vérifie l'intégrité + importe (méthode officielle : concat naïve)
./serve.sh      # démarre le serveur sur http://localhost:2322
```

Ou tout enchaîner (download + import) en une fois : `./build.sh`.

## Endpoint

Serveur : **`http://localhost:2322`**

| Usage | Exemple |
|-------|---------|
| Recherche (forward) | `http://localhost:2322/api?q=Buenos+Aires&limit=3` |
| Recherche filtrée pays | `http://localhost:2322/api?q=Paris&osm_tag=place&limit=3` |
| Géocodage inverse | `http://localhost:2322/reverse?lat=-34.6037&lon=-58.3816` |
| Statut | `http://localhost:2322/status` |

Helper : `./query.sh "São Paulo"`

## Méthode d'import (la bonne, 2025+)

La méthode **recommandée par l'éditeur** (S. Hoffmann/lonvia, [article 13/08/2025](https://nominatim.org/2025/08/13/photon-exports-renewed.html))
pour couvrir plusieurs régions = **concaténer les dumps JSON** et les piper dans `import`.
L'importeur ignore les en-têtes en double (un simple `WARN`). Pas besoin de Nominatim.

```bash
zstd --stdout -d data/dumps/*.jsonl.zst | java -jar photon.jar import -import-file - ...
```

`import.sh` ajoute deux garde-fous d'exploitation : contrôle d'intégrité `zstd -t` avant
de lancer (un `.zst` corrompu = des heures perdues) et **bascule atomique** (import dans
`data/staging/`, puis remplacement de `data/photon_data` seulement en cas de succès — car
relancer `import` écrase la base existante).

## Ajouter / changer de pays

Déposer d'autres `photon-dump-<zone>-1.0-latest.jsonl.zst` dans `data/dumps/`
(catalogue : `https://download1.graphhopper.com/public/<continent>/<pays>/`) puis relancer `./import.sh`.
Utiliser les dumps **`-1.0-`** (format lu par le jar 1.2.0).

## Arborescence

```
photon-geocoder/
├── download.sh   import.sh   serve.sh   build.sh   query.sh
└── data/                     # ignoré par git (volumineux)
    ├── photon-1.2.0.jar
    ├── dumps/*.jsonl.zst
    └── photon_data/          # l'index OpenSearch
```
