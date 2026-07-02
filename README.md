# Photon geocoder: DEX

**Photon 1.2.0** geocoder (Europe + Brazil + Argentina), deployed with **Ansible** on a
3-VM cluster behind an Nginx load balancer. The index is built on the **leader** from
the GraphHopper JSON dumps, then distributed to the other nodes over rsync.

## Architecture

```
                        Nginx (:80, SRVLH-GEO-A1)
                          upstream photon :2322
               ┌─────────────────┼─────────────────┐
        SRVLH-GEO-A1       SRVLH-GEO-A2       SRVLH-GEO-A3
          (leader)           (follower)         (follower)
        builds the index  ◄── rsync photon_data ──►
        from the dumps
```

Ansible roles:

- **photon** (every node): Java 21, service user, jar, `photon.service` unit.
  - *Leader* (first host of the `photon` group): downloads the dumps, builds the index
    through `photon-index-build.service` (detached oneshot: integrity check → import →
    atomic swap), writes a `.build-id` marker inside the index.
  - *Followers*: compare their `.build-id` with the leader's; if it differs or is
    missing, the index is pushed over rsync (dedicated key generated on the leader)
    and swapped in.
- **lb**: plain-HTTP Nginx on :80, upstream generated from the inventory's `photon`
  group (adding a node = edit the inventory + re-run).

The playbook describes the target state and converges idempotently: an up-to-date node
is left alone, a stale node is resynced, a fresh node is installed. `serial: 1` rolls
one node at a time, so the cluster keeps serving during a redeploy.

## Prerequisites

Linux VMs (Debian/Ubuntu or RHEL), `sudo`, **64 GB RAM on the leader** (the import
fails below that, see Sizing), ~80 GB free disk, SSD/NVMe. Only the leader reaches the
internet (through the pickup proxy, see `group_vars/all.yml`). Ansible ≥ 2.14 and the
`ansible.posix` collection on the machine running the play (VM1).

## Deployment

From **VM1** (SRVLH-GEO-A1, Delinea access), inside `tmux` — the first index build
(~1-3 h) happens during the play:

```bash
export https_proxy=http://proxy-prod.paris.pickup.local:3128

# fetch the repo as a plain tarball (no git, no .git on the VM)
curl -L -o /tmp/pg.tgz https://github.com/akramnoui/photon-geocoder/archive/refs/heads/main.tar.gz
rm -rf ~/photon-geocoder
tar xzf /tmp/pg.tgz -C ~ && mv ~/photon-geocoder-main ~/photon-geocoder && rm /tmp/pg.tgz

cd ~/photon-geocoder/ansible
tmux new -s photon
ansible-playbook playbook.yml --ask-become-pass
```

Updating the deployment = re-run the same `curl` + `tar` block (it wipes and replaces
`~/photon-geocoder`, so the VM copy always matches `main`), then re-run the playbook.

The play: leader (index build if missing, wait for completion) → followers one at a
time (index rsync if stale) → servers started and checked on :2322 → Nginx LB.

```bash
curl 'http://SRVLH-GEO-A1/api?q=Paris&limit=1'        # through the LB
curl 'http://127.0.0.1:2322/api?q=Paris&limit=1'      # a node directly
```

## Parameters — `ansible/roles/photon/defaults/main.yml`

| Variable | Default | Purpose |
|---|---|---|
| `photon_import_heap` | `24g` | import heap (above ~RAM/2 → swap) |
| `photon_import_threads` | `2` | indexing threads |
| `photon_languages` | `en,fr,es,pt,de,it` | indexed languages |
| `photon_server_heap` | `4g` | server heap |
| `photon_listen_ip` / `_port` | `0.0.0.0` / `2322` | listen address (reachable from the LB) |
| `photon_jar_checksum` | `""` | jar integrity, e.g. `sha256:…` (empty = no check) |
| `photon_proxy` | pickup proxy (`group_vars/all.yml`) | outbound proxy (jar everywhere, dumps on the leader) |
| `photon_force` | `false` | refresh the dumps and rebuild the index on the leader |
| `force_resync` | `false` | push the index to the followers again |
| `cleanup_legacy` | `false` (`group_vars/all.yml`) | purge leftovers from the old playbooks |

One-off override: `ansible-playbook playbook.yml -e photon_import_heap=16g`.

## Operations

| Action | Command |
|---|---|
| Rebuild the index and redistribute it | `ansible-playbook playbook.yml -e photon_force=true` |
| Resync a suspicious follower | `ansible-playbook playbook.yml -e force_resync=true` |
| Build status (leader) | `systemctl status photon-index-build` (`active (exited)` = done) |
| Build / server logs | `journalctl -u photon-index-build` / `journalctl -u photon` |
| Start / stop a server | `systemctl start\|stop\|restart photon` |
| LB health | `curl http://127.0.0.1/nginx_status` (from VM1) |
| Smoke test | `curl '…/api?q=Buenos+Aires&limit=1'` · `/reverse?lat=-34.6&lon=-58.4` · `/status` |

A rebuild updates the `.build-id` marker of the leader's index; the next playbook run
detects the difference and pushes the index to the followers on its own. A play
relaunched while a build is running **joins** the build in progress instead of
restarting it from scratch.

## Coexistence with the old deployments

The VMs still carry the deployments from the legacy repo (`~/photon-deploy` on VM1).
The new playbook **converges on its own** to the functional state, because both
generations use the same anchor points:

- same `photon.service` unit: the template replaces it, `daemon-reload` + restart;
- followers: no `.build-id` in the new layout → the old service is stopped, the index
  received over rsync, the new service started;
- same `nginx.conf` and `conf.d/photon.conf`: the legacy HTTPS config is replaced by
  the HTTP-only one (the :443 disappears, intended);
- same rsync key `/root/.ssh/photon_rsync_ed25519` and same authorized user: reused
  as-is.

What does not converge: the legacy **orphaned data** (`/data/photon`: archives and
extracts, tens of GB; the `/opt/photon/photon_data` symlink; `/var/log/photon`;
the self-signed certificate). The play reports them and only deletes them on demand:
`-e cleanup_legacy=true`. While they are there, rolling back to legacy stays possible;
once purged, it is not.

Two precautions outside the playbook:

- **Freeze the old repo**: archive or delete `~/photon-deploy` on VM1. An
  `ansible-playbook deploy_photon.yml` run out of habit would clobber the new unit.
- **Follower disk space**: the new index lives under `/opt/photon/data` (the old
  layout kept heavy data on `/data`). Check `df -h /opt` on A2/A3 before the first
  run; purging the legacy data frees `/data`, not `/opt`.

## Sizing

Europe+BR+AR ≈ 40-60 M documents. With 24 GB the import **systematically fails around
3.3 M docs** (heap too large → swap → bulk timeouts; or without swap, throughput
collapsing to ~500 docs/s for lack of page cache during the merges). The official
Photon README recommends **64 GB** on the importing node. Followers import nothing:
serving the index only needs `photon_server_heap` + page cache.

## Edge cases

- **Leader VM without internet**: pre-stage the jar and the 3 `*.jsonl.zst` in
  `/opt/photon/data/dumps/` before the play (the `get_url` tasks become idempotent).
- **Interrupted download**: delete the partial file and re-run; the script's
  `zstd -t` check protects the import from a truncated dump.
- **Interrupted rsync**: re-run the play; `--partial` resumes where it left off.
- **The import is not resumable**: any rebuild starts from scratch.
- **Index built before the marker was introduced**: the play writes a `.build-id`
  on the leader's index on first pass, then distributes normally.

## Import method

The JSON dumps are concatenated and piped into `photon import` (the importer ignores
duplicate headers). Reference: [nominatim.org, 13/08/2025](https://nominatim.org/2025/08/13/photon-exports-renewed.html).
`-1.0-` dumps (format of the 1.2.0 jar). `data/` is gitignored.
