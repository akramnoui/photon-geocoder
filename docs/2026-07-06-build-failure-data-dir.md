# Incident build du 2026-07-06 et migration du data dir vers /data

## Symptôme

Le build d'index (`photon-index-build.service`) sur SRVLH-GEO-A1 échoue après
environ 2 h de wall (17 h 34 de CPU) :

```
Caused by: java.lang.RuntimeException: 10000 failed items in bulk
zstd: error 70 : Write error : cannot write block : Broken pipe
photon-index-build.service: Failed with result 'exit-code'.
```

Et dans le journal, la cause racine :

```
disk usage exceeded flood-stage watermark, index has read-only-allow-delete block
```

## Cause racine

Le playbook plaçait tout le data tree (dumps, staging, index servi) sous
`/opt/photon/data`, donc sur le FS racine (64 GB, pas de montage séparé pour
`/opt`). Pendant le build : 14 GB de dumps + 38 GB de staging ont porté `/` à
plus de 95 % d'occupation. L'OpenSearch embarqué de Photon passe alors l'index
en lecture seule (flood-stage watermark) : le bulk d'insertion échoue en bloc,
l'import crashe, et le `zstd` amont prend un broken pipe (conséquence, pas
cause).

Le staging complet d'un index Europe + BR + AR se situe autour de 120-150 GB :
la racine de 64 GB ne pouvait structurellement jamais le contenir, même vide.
Le volume prévu pour cela est le LV `/data` (200 GB), qui n'hébergeait que les
restes du déploiement legacy (`/data/photon` : 126 GB d'index + 35 GB
d'archives).

## Changements dans le repo

| Fichier | Changement |
|---|---|
| `roles/photon/defaults/main.yml` | Nouvelle variable `photon_data_dir` (défaut : `{{ photon_app_dir }}/data`, inchangé pour un environnement générique) et `photon_build_min_free_gb: 150`. |
| `group_vars/all.yml` | Override environnement : `photon_data_dir: /data/photon-geocoder`. Chemin distinct de `/data/photon` (legacy) pour que `cleanup_legacy=true` reste sans danger. |
| `roles/photon/templates/photon-build-index.sh.j2` | `data_dir` pointe sur `photon_data_dir`. |
| `roles/photon/templates/photon.service.j2` | `ConditionPathExists` et `-data-dir` pointent sur `photon_data_dir`. |
| `roles/photon/tasks/main.yml` | L'arborescence est créée sur `photon_data_dir`. |
| `roles/photon/tasks/build.yml` | Chemins sur `photon_data_dir` ; migration des dumps déjà téléchargés depuis l'ancien emplacement (évite 14 GB de re-téléchargement via le proxy) ; garde-fou d'espace disque avant de lancer le build (assert : au moins `photon_build_min_free_gb` libres sur le volume de `photon_data_dir`, sinon échec immédiat plutôt que crash après des heures d'import) ; fenêtre d'attente du build portée de 4 h à 8 h (240 x 120 s), l'ancien build est mort à 2 h de wall avec seulement ~30 % du staging écrit ; téléchargement des dumps gaté sur la présence du fichier (voir ci-dessous). |
| `roles/photon/tasks/sync.yml` | Tous les chemins followers (marker, réception rsync, swap) sur `photon_data_dir`. |
| `roles/photon/tasks/cleanup.yml` | Suppression automatique de l'ancien data tree `/opt/photon/data` quand `photon_data_dir` a été déplacé (les dumps ont été migrés avant, le staging résiduel est mort). |
| `README.md` | Sections « disk space » et « pre-stage dumps » mises à jour. |

## Déroulé sur les VMs (downtime accepté)

Pré-nettoyage manuel sur A1 (le play exige 150 GB libres sur `/data`, qui n'en
a que 38 tant que le legacy est là) :

```bash
systemctl list-units | grep -i photon          # repérer le service qui sert encore l'index legacy
sudo systemctl stop photon.service             # downtime accepté
sudo systemctl stop photon-index-build.service
sudo rm -rf /data/photon                       # index legacy 126 GB + archives 35 GB
df -h /data                                    # attendu : ~198 GB libres
```

Puis, depuis le repo mis à jour sur A1 :

```bash
ansible-playbook -i inventory.ini playbook.yml
```

Ce que fait le play : création de `/data/photon-geocoder`, migration des 14 GB
de dumps depuis `/opt/photon/data/dumps` (pas de re-téléchargement), contrôle
d'espace, build sur `/data` (la racine ne bouge plus), bascule du service,
sync vers A2/A3, puis purge de l'ancien `/opt/photon/data`.

Surveillance pendant le build :

```bash
watch -n 60 'df -h / /data'
journalctl -u photon-index-build.service -f
```

## Points d'attention

- **Followers A2/A3** : vérifier `df -h /data` avant le premier run (le play
  est `serial: 1`, leader d'abord). L'index reçu par rsync ira aussi sur
  `/data/photon-geocoder` : il faut ~130 GB libres par follower.
- **Rebuilds futurs (`-e photon_force=true`)** : le script conserve l'index
  servi jusqu'au swap final. Pic disque : dumps (~14 GB) + staging (~130 GB) +
  index courant (~130 GB), soit ~270 GB pour un LV de 200 GB. Le garde-fou
  fera échouer le play immédiatement. Deux issues : supprimer l'index servi
  avant le rebuild (downtime), ou agrandir `lv_data` d'environ 100 GB
  (`lvextend -r`), ce qui est la solution pérenne pour des rebuilds sans
  interruption.
- **`cleanup_legacy=true`** : purge `/data/photon` (legacy). Sans objet si le
  pré-nettoyage manuel ci-dessus a été fait ; reste sans danger pour
  `/data/photon-geocoder`.

## Téléchargement des dumps : figé sur la présence du fichier

`get_url` avec `force: false` n'est **pas** un simple « skip si le fichier
existe » : quand le fichier est présent, il fait une requête conditionnelle
`If-Modified-Since` basée sur la mtime locale. Comme graphhopper publie des
dumps « latest » (URL fixe, contenu qui change), dès que graphhopper republie
une version plus récente le serveur répond 200 et le dump de 14 GB est
re-téléchargé, alors même que le fichier est déjà là. Observé le 2026-07-09 :
un run non-`force` a re-tiré l'europe parce que la version publiée était plus
récente que celle du 6 juillet.

Le task est désormais gaté : le download ne s'exécute que si le fichier est
**absent** du dossier `dumps`, ou si `photon_force=true`. Conséquences :

- run normal, dumps présents : **aucun accès réseau**, on builde sur les dumps
  locaux, quelle que soit la version publiée entre-temps ;
- run avec `-e photon_force=true` : rafraîchit volontairement les dumps
  (`force: true` sur get_url force le remplacement), puis rebuild ;
- premier run ou dump manquant : téléchargement normal.

Pour rafraîchir un seul dump ponctuellement sans `photon_force` global :
supprimer le fichier concerné dans `{{ photon_data_dir }}/dumps/` avant le run,
le task le re-téléchargera car absent.
