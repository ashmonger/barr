# barr

Ansible playbook that installs and fully wires the *arr media automation stack on a Debian server. A single `ansible-playbook` run takes a fresh Debian 13 (Trixie) machine to a complete, interconnected media server with reverse proxy, monitoring, and a test VM harness.

## What gets installed

| Service | Port | Purpose |
|---------|------|---------|
| [Prowlarr](https://prowlarr.com) | 9696 | Indexer manager — syncs to all arr apps |
| [Sonarr](https://sonarr.tv) | 8989 | TV series automation |
| [Radarr](https://radarr.video) | 7878 | Movie automation |
| [Lidarr](https://lidarr.audio) | 8686 | Music automation |
| [Bazarr](https://www.bazarr.media) | 6767 | Subtitle automation |
| [qBittorrent](https://www.qbittorrent.org) | 8080 | Download client |
| [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) | 8191 | Cloudflare bypass for Prowlarr |
| [Unpackerr](https://unpackerr.zip) | — | Extracts completed downloads |
| [Recyclarr](https://recyclarr.dev) | — | Syncs TRaSH Guides quality profiles |
| [Decluttarr](https://github.com/ManiMatter/decluttarr) | — | Removes stalled/failed queue items |
| [Jellyseerr](https://github.com/Fallenbagel/jellyseerr) | 5055 | Media request management |
| [Homarr](https://homarr.dev) | 7575 | Dashboard |
| [Caddy](https://caddyserver.com) | 80/443 | Reverse proxy with automatic TLS |

All services run as dedicated system users under systemd, with shared access to media directories via a common `media` group.

## Prerequisites

- Debian 13 (Trixie) target host
- Ansible 2.14+ on the control machine
- SSH access to the target with a sudo-capable user

No external Ansible collections are required — the playbook uses only `ansible.builtin.*` modules.

## Quick start

**1. Clone and configure**

```bash
git clone https://github.com/youruser/barr.git
cd barr
```

Edit `group_vars/all.yml`:

```yaml
caddy_domain: "home.example.com"   # your domain
caddy_tls: internal                # or "auto" for Let's Encrypt

arr_media_root: /data/media        # adjust to your mount point
arr_downloads_root: /data/downloads
```

Edit `inventory.ini` with your server details:

```ini
[arr_servers]
mediaserver ansible_host=192.168.1.100 ansible_user=debian
```

**2. Run the playbook**

```bash
ansible-playbook -i inventory.ini install.yml
```

The playbook is fully idempotent — re-running it is safe and will only apply changes.

## Configuration reference

All variables live in `group_vars/all.yml`. Key sections:

### Media paths

```yaml
arr_media_root: /data/media
arr_media_movies: "{{ arr_media_root }}/movies"
arr_media_tv: "{{ arr_media_root }}/tv"
arr_media_music: "{{ arr_media_root }}/music"

arr_downloads_root: /data/downloads
arr_downloads_complete: "{{ arr_downloads_root }}/complete"
arr_downloads_incomplete: "{{ arr_downloads_root }}/incomplete"
```

### GitHub API rate limiting

The playbook queries the GitHub Releases API to resolve current download URLs. If you hit the unauthenticated rate limit (60 req/h), provide a token:

```yaml
github_token: ghp_xxxxxxxxxxxx
```

### Caddy TLS

```yaml
caddy_domain: "home.example.com"
caddy_tls: internal   # self-signed cert for LAN — no ports 80/443 required
# caddy_tls: auto     # Let's Encrypt — requires ports 80 and 443 reachable
```

Caddy exposes each service on a subdomain:

| URL | Service |
|-----|---------|
| `home.example.com` | Homarr dashboard |
| `requests.home.example.com` | Jellyseerr |
| `prowlarr.home.example.com` | Prowlarr |
| `sonarr.home.example.com` | Sonarr |
| `radarr.home.example.com` | Radarr |
| `lidarr.home.example.com` | Lidarr |
| `bazarr.home.example.com` | Bazarr |
| `qbit.home.example.com` | qBittorrent |

### Healthchecks.io monitoring

Each service has a corresponding entry in `healthchecks_services`. Fill in the `ping_url` from your healthchecks.io dashboard to enable heartbeat monitoring:

```yaml
healthchecks_services:
  - name: sonarr
    systemd_unit: sonarr
    ping_url: "https://hc-ping.com/your-uuid-here"
  # ...
```

A systemd timer fires every `healthchecks_ping_interval_minutes` (default 5) minutes. It pings the URL on success, or appends `/fail` if the service is down. Discord (and any other) alerts are configured on the healthchecks.io side — no further Ansible config needed.

## How service wiring works

After all services are installed, the `arr_configure` role handles all inter-service configuration automatically:

1. **Waits** for every Servarr and Bazarr API to become responsive
2. **Reads API keys** from each app's `config.xml` (slurped from the remote host)
3. **Registers Sonarr/Radarr/Lidarr in Prowlarr** via the `/api/v1/applications` endpoint, so all indexers sync automatically
4. **Registers FlareSolverr** as a proxy in Prowlarr
5. **Adds qBittorrent** as the download client in each arr app, with per-app download categories (`tv-sonarr`, `radarr`, `lidarr`)
6. **Configures Bazarr** connections to Sonarr and Radarr, and installs webhooks so arr apps notify Bazarr on import
7. **Writes Unpackerr config** with all arr app endpoints and API keys, then starts the service
8. **Writes Recyclarr config** with Sonarr/Radarr endpoints and API keys, runs an initial TRaSH Guides sync, then arms the daily timer
9. **Writes Decluttarr config** with all app credentials, then starts the service

Services that need API keys (Unpackerr, Recyclarr, Decluttarr) are installed and enabled during their own role but only **started** by `arr_configure`, ensuring they never launch with a blank config.

## Role overview

```
roles/
├── common/          # libicu, libssl, media group, managed directories
├── nodejs/          # Node.js 20 via NodeSource apt repo + yarn
├── servarr/         # Generic role for .NET arr apps (loop over servarr_apps)
├── bazarr/          # Python venv install
├── qbittorrent/     # apt install + LocalHostAuth=false config
├── flaresolverr/    # Binary + chromium
├── unpackerr/       # Binary, deferred start
├── recyclarr/       # Binary + daily timer, deferred start
├── decluttarr/      # Python venv, deferred start
├── jellyseerr/      # Node.js, npm build on first install
├── homarr/          # Node.js, yarn build on first install
├── caddy/           # apt install + Caddyfile template
├── arr_configure/   # API wiring (see above)
└── healthchecks/    # Per-service ping scripts + systemd timers
```

The `servarr` role is called in a loop over `servarr_apps` defined in `group_vars/all.yml`. Each app entry specifies its name, port, install/data dirs, GitHub repo, and asset filename pattern. The role queries the GitHub Releases API at runtime to always fetch the current version.

## Test VM

`barr-vm.sh` boots a local Debian 12 QEMU VM and runs the full playbook inside it — useful for testing before deploying to a real machine.

```bash
# Full setup (download image → boot → copy playbook → install Ansible)
./barr-vm.sh

# Run the playbook inside the VM
./barr-vm.sh run

# Other commands
./barr-vm.sh start   # boot a previously prepared VM
./barr-vm.sh stop    # graceful ACPI shutdown
./barr-vm.sh ssh     # interactive shell into the VM
./barr-vm.sh status  # show running state
./barr-vm.sh clean   # delete all VM artefacts (.vm/)
```

The script downloads the official Debian 12 Genericcloud image, creates an overlay qcow2 disk (40 GB by default), generates a cloud-init seed ISO with a `deploy` user (passwordless sudo, SSH key), and starts QEMU with KVM/HVF/TCG acceleration auto-detected. SSH is forwarded to `localhost:2222`.

Override defaults via environment variables:

```bash
VM_RAM=8192 VM_CPUS=4 SSH_PORT=2223 ./barr-vm.sh
```

**Dependencies:** `qemu-system-x86_64`, `qemu-img`, `ssh`, `curl`, `rsync`, and one of `cloud-localds` / `genisoimage` / `mkisofs` / `xorriso`.

## Directory layout

```
barr/
├── install.yml              # Main playbook
├── inventory.ini            # Remote host inventory
├── inventory_local.ini      # Localhost inventory (for use inside the VM)
├── group_vars/
│   └── all.yml              # All configuration variables
├── roles/
│   └── <role>/
│       ├── tasks/
│       ├── templates/
│       ├── handlers/
│       └── vars/            # (common only)
└── barr-vm.sh               # QEMU test VM helper
```
