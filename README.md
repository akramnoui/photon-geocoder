# Photon geocoder — Dossier d'exploitation

Géocodeur **Photon 1.2.0** (Europe + Brésil + Argentine), déployé par **Ansible** sur une VM,
index construit en local depuis les dumps JSON GraphHopper.

## Architecture

```
Ansible (rôle photon)            VM
  ├─ paquets (Java 21, zstd)     /opt/photon/
  ├─ utilisateur de service        ├─ photon-1.2.0.jar
  ├─ jar + dumps (get_url)         ├─ photon-build-index.sh   (généré)
  └─ units systemd                 └─ data/{dumps,photon_data}
        ├─ photon-index-build.service  (oneshot)  intégrité → import → bascule
        └─ photon.service              (serveur)  API :2322
```

L'unique reliquat de bash est `photon-build-index.sh` (~20 lignes, généré par le rôle) :
contrôle d'intégrité, concaténation des dumps dans `import`, bascule atomique de l'index.

## Pré-requis

VM Linux (Debian/Ubuntu ou RHEL), `sudo`, **64 Go RAM**, ~80 Go disque libre, SSD/NVMe,
accès internet (ou proxy, ou dumps pré-stagés). Ansible ≥ 2.14 sur le poste qui lance le play.

## Déploiement

Depuis la VM (accès Delinea), dans `tmux` — le téléchargement (~13.5 Go) se fait pendant le play :

```bash
git clone git@github.com:akramnoui/photon-geocoder.git && cd photon-geocoder/ansible
tmux new -s photon
ansible-playbook playbook.yml --ask-become-pass
```

Le play installe, télécharge, puis lance la construction de l'index en **service détaché**
(qui survit à la coupure de session). Ensuite :

```bash
journalctl -u photon-index-build -f          # suivre la construction (~1-3 h)
sudo systemctl enable --now photon           # démarrer le serveur une fois l'index prêt
curl 'http://127.0.0.1:2322/api?q=Paris&limit=1'
```

## Paramètres — `ansible/roles/photon/defaults/main.yml`

| Variable | Défaut | Rôle |
|---|---|---|
| `photon_import_heap` | `24g` | heap de l'import (au-delà de ~RAM/2 → swap) |
| `photon_import_threads` | `2` | threads d'indexation |
| `photon_languages` | `en,fr,es,pt,de,it` | langues indexées |
| `photon_server_heap` | `4g` | heap du serveur |
| `photon_listen_ip` / `_port` | `127.0.0.1` / `2322` | écoute |
| `photon_proxy` | `""` | proxy sortant |
| `photon_min_ram_gb` | `48` | refus en dessous (`-e photon_force=true` pour forcer) |

Surcharge ponctuelle : `ansible-playbook playbook.yml -e photon_import_heap=16g`.

## Exploitation

| Action | Commande |
|---|---|
| Statut construction | `systemctl status photon-index-build` (`active (exited)` = terminé) |
| Logs construction / serveur | `journalctl -u photon-index-build` / `journalctl -u photon` |
| Démarrer / arrêter le serveur | `systemctl start\|stop\|restart photon` |
| Reconstruire l'index | `sudo systemctl start photon-index-build` (réécrase) |
| Tester | `curl '…/api?q=Buenos+Aires&limit=1'` · `/reverse?lat=-34.6&lon=-58.4` · `/status` |

Accès depuis un poste : `ssh -L 2322:127.0.0.1:2322 <vm>` via le bastion, puis `curl localhost:2322`.

## Dimensionnement

Europe+BR+AR ≈ 40-60 M documents. Sur 24 Go l'import **échoue systématiquement vers 3,3 M docs**
(heap trop gros → swap → timeout des bulks ; ou sans swap, débit qui s'effondre à ~500 docs/s
faute de page cache pour les merges). Le README officiel Photon recommande **64 Go**. La RAM est
le seul levier ; le rôle refuse de démarrer sous 48 Go.

## Cas particuliers

- **Proxy** : `-e photon_proxy=http://proxy:3128`.
- **VM sans internet** : pré-stager le jar et les 3 `*.jsonl.zst` dans `/opt/photon/data/dumps/`
  avant le play (les tâches `get_url` deviennent idempotentes), ou copier depuis un dépôt interne.
- **Téléchargement interrompu** : supprimer le fichier partiel et relancer ; le contrôle
  `zstd -t` du script protège l'import d'un dump tronqué.
- **L'import n'est pas reprenable** : toute reconstruction repart de zéro.

## Méthode d'import

Concaténation des dumps JSON pipée dans `photon import` (l'importeur ignore les en-têtes en
double). Référence : [nominatim.org, 13/08/2025](https://nominatim.org/2025/08/13/photon-exports-renewed.html).
Dumps `-1.0-` (format du jar 1.2.0). `data/` est gitignored.
