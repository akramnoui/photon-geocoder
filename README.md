# Photon geocoder : DEX

Géocodeur **Photon 1.2.0** (Europe + Brésil + Argentine), déployé avec **Ansible** sur un
cluster de 3 VM derrière un load balancer Nginx. L'index est construit sur le **leader**
depuis les dumps JSON GraphHopper, puis distribué aux autres nœuds par rsync.

## Architecture

```
                        Nginx (:80, SRVLH-GEO-A1)
                          upstream photon :2322
               ┌─────────────────┼─────────────────┐
        SRVLH-GEO-A1       SRVLH-GEO-A2       SRVLH-GEO-A3
          (leader)           (follower)         (follower)
        construit l'index ◄── rsync photon_data ──►
        depuis les dumps
```

Rôles Ansible :

- **photon** (tous les nœuds) : Java 21, utilisateur de service, jar, unit `photon.service`.
  - *Leader* (premier hôte du groupe `photon`) : télécharge les dumps, construit l'index
    via `photon-index-build.service` (oneshot détaché : contrôle d'intégrité → import →
    bascule atomique), écrit un marqueur `.build-id` dans l'index.
  - *Followers* : comparent leur `.build-id` à celui du leader ; s'il diffère ou manque,
    l'index est poussé par rsync (clé dédiée générée sur le leader) puis basculé.
- **lb** : Nginx en HTTP simple sur :80, upstream généré depuis le groupe `photon`
  de l'inventaire (ajouter un nœud = éditer l'inventaire + relancer).

Le playbook décrit l'état cible et converge de façon idempotente : un nœud à jour
n'est pas touché, un nœud en retard est resynchronisé, un nœud neuf est installé.
`serial: 1` déroule un nœud à la fois, le cluster continue de servir pendant un
redéploiement.

## Logique de déploiement

Chaque build écrit un timestamp `.build-id` dans l'index. Les décisions de
synchronisation se basent sur ce fichier.

- Leader : construit l'index s'il est absent, ou si `-e photon_force=true`. Le build
  tourne en unit systemd détachée et le play l'attend. Si un build est déjà en cours,
  le play l'attend au lieu d'en relancer un.
- Followers : si leur `.build-id` diffère de celui du leader (ou manque), le play
  arrête photon, rsync l'index depuis le leader, le bascule et redémarre.
- Après une reconstruction, le leader a un nouveau `.build-id`, donc le run suivant
  resynchronise tous les followers automatiquement.
- Chaque nœud doit répondre sur :2322 avant que le play passe au suivant.

Relancer le playbook sur un cluster à jour ne change rien.

## Pré-requis

VM Linux (Debian/Ubuntu ou RHEL), `sudo`, **64 Go de RAM sur le leader** (l'import
échoue en dessous, voir Dimensionnement), ~80 Go de disque libre, SSD/NVMe. Seul le
leader sort sur internet (via le proxy pickup, voir `group_vars/all.yml`). Sur la
machine qui lance le play (VM1) : Ansible ≥ 2.14 et la collection `ansible.posix` :
avec ansible-core 2.14 (paquet RHEL), l'épingler :
`ansible-galaxy collection install 'ansible.posix:1.5.4'`
(la ligne 2.x de la collection exige un core plus récent).

## Déploiement

Depuis la **VM1** (SRVLH-GEO-A1, accès Delinea), dans `tmux` : la première
construction d'index (~1-3 h) se déroule pendant le play :

```bash
export https_proxy=http://proxy-prod.paris.pickup.local:3128

# récupérer le repo en simple tarball (pas de git, pas de .git sur la VM)
curl -L -o /tmp/pg.tgz https://github.com/akramnoui/photon-geocoder/archive/refs/heads/main.tar.gz
rm -rf ~/photon-geocoder
tar xzf /tmp/pg.tgz -C ~ && mv ~/photon-geocoder-main ~/photon-geocoder && rm /tmp/pg.tgz

cd ~/photon-geocoder/ansible
tmux new -s photon
ansible-playbook playbook.yml --ask-become-pass
```

Mettre à jour le déploiement = rejouer le même bloc `curl` + `tar` (il écrase et
remplace `~/photon-geocoder`, la copie VM correspond donc toujours à `main`), puis
relancer le playbook.

Le play : leader (build de l'index si absent, attente de la fin) → followers un par
un (rsync de l'index si en retard) → serveurs démarrés et vérifiés sur :2322 → LB Nginx.

```bash
curl 'http://SRVLH-GEO-A1/api?q=Paris&limit=1'        # via le LB
curl 'http://127.0.0.1:2322/api?q=Paris&limit=1'      # un nœud en direct
```

## Paramètres : `ansible/roles/photon/defaults/main.yml`

| Variable | Défaut | Rôle |
|---|---|---|
| `photon_import_heap` | `24g` | heap de l'import (au-delà de ~RAM/2 → swap) |
| `photon_import_threads` | `2` | threads d'indexation |
| `photon_languages` | `en,fr,es,pt,de,it` | langues indexées |
| `photon_server_heap` | `4g` | heap du serveur |
| `photon_listen_ip` / `_port` | `0.0.0.0` / `2322` | écoute (joignable par le LB) |
| `photon_jar_checksum` | `""` | intégrité du jar, ex. `sha256:…` (vide = pas de contrôle) |
| `photon_proxy` | proxy pickup (`group_vars/all.yml`) | proxy sortant (jar partout, dumps sur le leader) |
| `photon_force` | `false` | rafraîchit les dumps et reconstruit l'index sur le leader |
| `force_resync` | `false` | repousse l'index vers les followers |
| `cleanup_legacy` | `false` (`group_vars/all.yml`) | purge les restes des anciens playbooks |

Surcharge ponctuelle : `ansible-playbook playbook.yml -e photon_import_heap=16g`.

## Exploitation

| Action | Commande |
|---|---|
| Reconstruire l'index et le redistribuer | `ansible-playbook playbook.yml -e photon_force=true` |
| Resynchroniser un follower douteux | `ansible-playbook playbook.yml -e force_resync=true` |
| Statut du build (leader) | `systemctl status photon-index-build` (`active (exited)` = terminé) |
| Logs build / serveur | `journalctl -u photon-index-build` / `journalctl -u photon` |
| Démarrer / arrêter un serveur | `systemctl start\|stop\|restart photon` |
| Santé du LB | `curl http://127.0.0.1/nginx_status` (depuis la VM1) |
| Tester | `curl '…/api?q=Buenos+Aires&limit=1'` · `/reverse?lat=-34.6&lon=-58.4` · `/status` |

Une reconstruction met à jour le marqueur `.build-id` de l'index du leader ; le run
suivant du playbook détecte l'écart et pousse l'index vers les followers tout seul.
Un play relancé pendant qu'un build tourne **rejoint** le build en cours au lieu de
le relancer de zéro.

## Cohabitation avec les anciens déploiements

Les VM portent encore les déploiements du repo legacy (`~/photon-deploy` sur la VM1).
Le nouveau playbook **converge tout seul** vers l'état fonctionnel, parce que les deux
générations utilisent les mêmes points d'ancrage :

- même unit `photon.service` : le template la remplace, `daemon-reload` + restart ;
- followers : pas de `.build-id` dans le nouveau layout → l'ancien service est arrêté,
  l'index reçu par rsync, le nouveau service démarré ;
- mêmes `nginx.conf` et `conf.d/photon.conf` : la conf HTTPS legacy est remplacée par
  la conf HTTP pure (le :443 disparaît, voulu) ;
- même clé rsync `/root/.ssh/photon_rsync_ed25519` et même utilisateur autorisé :
  réutilisés tels quels.

Ce qui ne converge pas : les **données orphelines** legacy (`/data/photon` : archives
et extracts, des dizaines de Go ; le symlink `/opt/photon/photon_data` ;
`/var/log/photon` ; le certificat auto-signé). Le play les signale et ne les supprime
que sur demande : `-e cleanup_legacy=true`. Tant qu'elles sont là, le retour arrière
vers le legacy reste possible ; une fois purgées, non.

Deux précautions hors playbook :

- **Geler l'ancien repo** : archiver ou supprimer `~/photon-deploy` sur la VM1. Un
  `ansible-playbook deploy_photon.yml` lancé par habitude écraserait la nouvelle unit.
- **Espace disque** : dumps, staging et index servi vivent sous `photon_data_dir`
  (`/data/photon-geocoder` dans cet environnement, sur le LV `/data` de 200 Go). Le
  FS racine ne doit jamais les héberger : les 64 Go de `/` ne peuvent pas absorber un
  build, et l'OpenSearch embarqué passe l'index en lecture seule au-delà du seuil de
  95 % (flood stage ; build du 06/07/2026, mort après 17 h de CPU). Le play refuse de
  lancer un build avec moins de `photon_build_min_free_gb` libres sur le volume data.

## Dimensionnement

Europe+BR+AR ≈ 40-60 M de documents. Avec 24 Go, l'import **échoue systématiquement
vers 3,3 M de docs** (heap trop gros → swap → timeout des bulks ; ou sans swap, débit
qui s'effondre à ~500 docs/s faute de page cache pour les merges). Le README officiel
de Photon recommande **64 Go** sur le nœud qui importe. Les followers n'importent
rien : servir l'index ne demande que `photon_server_heap` + du page cache.

## Cas particuliers

- **VM leader sans internet** : pré-stager le jar et les 3 `*.jsonl.zst` dans
  `{{ photon_data_dir }}/dumps/` avant le play (les tâches `get_url` deviennent
  idempotentes).
- **Téléchargement interrompu** : supprimer le fichier partiel et relancer ; le
  contrôle `zstd -t` du script protège l'import d'un dump tronqué.
- **rsync interrompu** : relancer le play ; `--partial` reprend où il en était.
- **L'import n'est pas reprenable** : toute reconstruction repart de zéro.
- **Index construit avant l'introduction du marqueur** : le play pose un `.build-id`
  sur l'index du leader au premier passage, puis distribue normalement.

## Méthode d'import

Les dumps JSON sont concaténés et pipés dans `photon import` (l'importeur ignore les
en-têtes en double). Référence : [nominatim.org, 13/08/2025](https://nominatim.org/2025/08/13/photon-exports-renewed.html).
Dumps `-1.0-` (format du jar 1.2.0). `data/` est gitignored.
