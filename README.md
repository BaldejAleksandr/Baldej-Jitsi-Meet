# Jitsi Meet in Docker via Ansible

**English** | [Русский](README.ru.md)

Deploys [Jitsi Meet](https://jitsi.org/) from the official
[docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet) to a single server and adds what the standard
setup lacks:

- **file sharing in chat** — a "Files" tab with drag and drop; other participants see and download the files;
  no JWT needed, upload for all participants or moderators only;
- **automatic cleanup** of chat files and conference recordings (Jibri) by age and total size;
- **per-feature config**: core settings in `vars.yml`, each feature in its own file under `plugins/`.

## Requirements

- A Linux server with Docker and Docker Compose v2, reachable over SSH (tested on Ubuntu);
- a domain and an HTTPS reverse proxy in front of Jitsi (for example, [Nginx Proxy Manager](https://nginxproxymanager.com/)):
  Jitsi listens for HTTP on `jitsi_http_port` (8000 by default), the proxy forwards `https://<domain>` → `http://<server>:8000`;
- UDP port 10000 open for media (JVB);
- on your machine: Python 3.10+, `openssl`.

## Quick start

```bash
git clone https://github.com/BaldejAleksandr/Baldej-Jitsi-Meet.git && cd Baldej-Jitsi-Meet

# Ansible and collections inside the project directory
python3 -m venv .venv
.venv/bin/pip install 'ansible-core>=2.17,<2.19'
.venv/bin/ansible-galaxy collection install -r requirements.yml -p ./collections
source .venv/bin/activate

# Your server and domain
cp inventory/hosts.yml.example inventory/hosts.yml                                  # IP, user, SSH key
cp inventory/group_vars/jitsi/site.yml.example inventory/group_vars/jitsi/site.yml  # jitsi_public_url

# Service passwords: a vault key + random passwords, encrypted right away
openssl rand -base64 32 > .vault_pass && chmod 600 .vault_pass
for k in jicofo_auth jvb_auth jigasi_xmpp jigasi_transcriber jibri_recorder jibri_xmpp; do
  echo "vault_jitsi_${k}_password: $(openssl rand -hex 16)"
done > inventory/group_vars/jitsi/vault.yml
ansible-vault encrypt inventory/group_vars/jitsi/vault.yml

# Check and deploy
ansible-playbook playbooks/deploy.yml --check --diff
ansible-playbook playbooks/deploy.yml --diff
```

`.vault_pass` is the only key to `vault.yml`: keep a copy in a password manager, the passwords cannot be
decrypted without it. Ansible reads the vault password from this file automatically (see `ansible.cfg`).

## Layout

```text
ansible.cfg                       Ansible settings: inventory, roles, collections, vault password file
requirements.yml                  collections: community.docker, ansible.posix
playbooks/deploy.yml              install and update
inventory/
├── hosts.yml(.example)           the server (hosts.yml is not in git)
└── group_vars/jitsi/             Ansible reads every .yml here, subdirectories included
    ├── vars.yml                  core: Jitsi version, ports, password references
    ├── site.yml(.example)        Jitsi URL (site.yml is not in git)
    ├── vault.yml(.example)       service passwords, ansible-vault (vault.yml is not in git)
    └── plugins/
        ├── recordings.yml        conference recording and recordings cleanup
        └── file_sharing.yml      file sharing in chat
roles/
├── jitsi/                        docker-jitsi-meet: release, .env, compose, recordings cleanup
└── jitsi_file_sharing/           file sharing service and its integration with Jitsi
docs/                             operations notes (in Russian)
```

Set each variable in one file only: if it is repeated, the file read later wins silently.
Resulting values: `ansible-inventory --host <host name> --yaml`.

On the server:

| Path | Contents |
|---|---|
| `/opt/jitsi-meet/releases/<version>`, `/opt/jitsi-meet/current` | docker-jitsi-meet release files and a symlink to the active one |
| `/opt/jitsi-meet-cfg` | Jitsi container configs and data |
| `/opt/jitsi-meet-cfg/storage/jibri/recordings` | conference recordings |
| `/opt/jitsi-file-sharing` | file sharing service: sources, keys, `uploads/` |

Compose projects: `jitsi` and `jitsi-file-sharing`.

## Configuration

### Core — `vars.yml` and `site.yml`

| Variable | Default | Purpose |
|---|---|---|
| `jitsi_public_url` | — (required, in `site.yml`) | the URL users open in the browser |
| `jitsi_version` | `stable-11248-2` | [docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet/releases) tag |
| `jitsi_http_port` / `jitsi_https_port` | `8000` / `8443` | web container ports |
| `jitsi_advertise_ips` | `ansible_host` | public IP for media (JVB) |
| `jitsi_tz` | `UTC` | container time zone |
| `jitsi_enable_auth` | `false` | require login to create rooms |
| `jitsi_extra_env` | `{}` | any variable from the release's `env.example` |

```yaml
jitsi_extra_env:
  ENABLE_LOBBY: 1
  JIBRI_RECORDING_RESOLUTION: 1920x1080
```

Updating Jitsi: change `jitsi_version` and run `deploy.yml`.

### Recordings — `plugins/recordings.yml`

```yaml
jitsi_enable_recording: true
jitsi_recordings_retention_days: 30       # how many days to keep a recording
jitsi_recordings_max_total_size_gb: 15    # total size; the oldest recordings above it are deleted
jitsi_recordings_cleanup_minute: "0"      # cleanup schedule, cron fields
jitsi_recordings_cleanup_hour: "*/4"
```

Cleanup is done by `/usr/local/sbin/jitsi-recordings-cleanup` from cron. It never touches a recording in progress:
recordings changed within the last 10 minutes are skipped. Log: `journalctl -t jitsi-recordings-cleanup`.

Size estimate with default Jibri settings (720p, 30 fps, H.264 CRF 25):
from ~2 GB (mostly static picture) to ~15 GB (active screen sharing) per 8 hours.

### File sharing — `plugins/file_sharing.yml`

```yaml
jitsi_file_sharing_enabled: true          # false — the role removes the service and hides the tab
jitsi_file_sharing_upload_for_all: true   # false — moderators only
jitsi_file_sharing_max_file_size_mb: 10
jitsi_file_sharing_max_total_size_gb: 5   # before an upload, the service deletes the oldest files above the limit
jitsi_file_sharing_retention_hours: 24
jitsi_file_sharing_cleanup_minute: "*/10" # schedule of age-based cleanup, cron fields
jitsi_file_sharing_cleanup_hour: "*"
jitsi_file_sharing_allowed_extensions:    # extensions without the dot
  - pdf
  - xlsx
  - ods
```

How it works:

- storage is the official example [jitsi-meet-file-sharing-service](https://github.com/jitsi/jitsi-meet-file-sharing-service)
  pinned to a commit (`jitsi_file_sharing_service_version`). The image is built on the server;
  before the build, `roles/jitsi_file_sharing/files/patch.sh` applies changes: file size limit and allowed extensions
  from variables, a total size limit, and reverse proxy awareness for rate limiting;
- Prosody: `conf.d/file-sharing.cfg.lua` (short-lived tokens, permissions, the `filesharing` component), modules via
  `XMPP_MODULES` / `XMPP_MUC_MODULES` in `.env` — do not set them in `jitsi_extra_env`;
  the `mod_file_sharing_everyone.lua` module grants upload permission to non-moderator participants;
- web: `nginx-custom/file-sharing.conf` proxies `/file-service/` to the service, a `config.fileSharing` block in `custom-config.js`.

Security: the file type is derived from an allowed extension; executables (ELF, PE, Mach-O) are rejected
by content; files are served as downloads (`Content-Disposition: attachment`), not opened in the browser;
the download link is signed and valid for 1 hour. There is no antivirus scanning — keep the extension list short.

Limitations: the room's file list is kept in the service's memory and is lost when it restarts
(files on disk are removed by cleanup); any participant allowed to upload can delete a file.

## Handy commands

- `ansible-playbook playbooks/deploy.yml --check --diff` — preview changes without applying them;
- `ansible-vault edit inventory/group_vars/jitsi/vault.yml` — edit passwords;
- `ansible-config validate -t all` — check `ansible.cfg` for typos;
- [docs/filesystems-df.md](docs/filesystems-df.md) — reading `df -h` on a Docker host (in Russian).

## Third-party components

None of them are copied into this repository — everything is downloaded during deployment:

- [docker-jitsi-meet](https://github.com/jitsi/docker-jitsi-meet) and the Jitsi images — Apache-2.0;
- [jitsi-meet-file-sharing-service](https://github.com/jitsi/jitsi-meet-file-sharing-service) — Apache-2.0,
  built with the changes from `patch.sh`;
- Ansible collections `community.docker` and `ansible.posix` — GPL-3.0.

## License

[MIT](LICENSE)
