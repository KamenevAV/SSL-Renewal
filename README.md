# SSL Renewal Toolkit

Centralized SSL/TLS certificate automation for one **main server** and multiple **node servers**.

- Main server issues and renews certificates with Certbot + Cloudflare DNS challenge.
- Node servers receive renewed certificates over SSH and use them in Nginx.
- Nodes do **not** renew locally.

This repository keeps the existing Bash workflow and improves safety, docs, and installation UX.

---

## One-line install

> Security note: Review `bootstrap.sh` before running remote shell commands: [https://github.com/indie-master/SSL-Renewal/blob/main/bootstrap.sh](https://github.com/indie-master/SSL-Renewal/blob/main/bootstrap.sh)

### Main server

Using `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/indie-master/SSL-Renewal/main/bootstrap.sh | sudo bash -s -- https://github.com/indie-master/SSL-Renewal.git main
```

Using `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/indie-master/SSL-Renewal/main/bootstrap.sh | sudo bash -s -- https://github.com/indie-master/SSL-Renewal.git main
```

### Node server

Using `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/indie-master/SSL-Renewal/main/bootstrap.sh | sudo bash -s -- https://github.com/indie-master/SSL-Renewal.git node
```

Using `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/indie-master/SSL-Renewal/main/bootstrap.sh | sudo bash -s -- https://github.com/indie-master/SSL-Renewal.git node
```


## After install: what to do next

### Main server

1. Check paths:
   ```bash
   ssl-renewal paths
   ```
2. Configure:
   ```bash
   ssl-renewal edit-config
   ```
3. Add Cloudflare token:
   ```bash
   nano /root/.secrets/certbot/cloudflare.ini
   chmod 600 /root/.secrets/certbot/cloudflare.ini
   ```
4. Add nodes:
   ```bash
   nano /etc/ssl-renewal/nodes.txt
   ```
5. Check:
   ```bash
   ssl-renewal doctor
   ```
6. Issue certificate:
   ```bash
   ssl-renewal issue
   ```
7. Deploy:
   ```bash
   ssl-renewal deploy
   ```
8. Dry-run:
   ```bash
   ssl-renewal dry-run
   ```

### Node server

- Run the installer as `node`.
- Ensure nginx uses the certificate paths managed by main:
  ```nginx
  ssl_certificate     /etc/letsencrypt/live/<PRIMARY_DOMAIN>/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/<PRIMARY_DOMAIN>/privkey.pem;
  ```
- Test and reload nginx:
  ```bash
  nginx -t && systemctl reload nginx
  ```

## Architecture

```text
                           +----------------------+
                           |   Cloudflare DNS     |
                           |  API Token (main)    |
                           +----------+-----------+
                                      |
                                      | dns-01 challenge
                                      v
+----------------------+      +----------------------+      +----------------------+
| Main server          | SSH  | Node 1               | ...  | Node N               |
| - certbot issue      +----->| - receives cert      |      | - receives cert      |
| - renew hook deploy  |      | - nginx -t && reload |      | - nginx -t && reload |
| - optional telegram  |      | - local renew off    |      | - local renew off    |
+----------+-----------+      +----------------------+      +----------------------+
           |
           v
 /etc/letsencrypt/renewal-hooks/deploy/ssl-renewal-deploy.sh
 triggers deploy-certs.sh after successful renewals
```

---

## Repository layout

- `install.sh` — interactive installer for `main` and `node`
- `scripts/ssl-renewal` — CLI entrypoint
- `scripts/lib.sh` — shared helpers and validations
- `scripts/deploy-certs.sh` — sync certs to nodes and reload Nginx safely
- `scripts/node-prep.sh` — disable local renewal on nodes
- `scripts/node-nginx-patch.sh` — preview/apply nginx cert path rewrites
- `scripts/disable-renew-on-nodes.sh` — remote renewal disable from main
- `scripts/telegram-notify.sh` — optional Telegram notification sender
- `smoke-test.sh` — shell syntax smoke checks

---

## Prerequisites

- Ubuntu/Debian (apt-based)
- Root access
- Nginx on nodes
- SSH connectivity from main to nodes
- Cloudflare-managed DNS for every zone included in the certificate

Installed automatically by `install.sh`:

- `curl`, `openssh-client`, `openssh-server`, `rsync`, `jq`, `snapd`
- `certbot` (snap)
- `certbot-dns-cloudflare` plugin

---

## GitHub-first bootstrap

### Option A: clone + install (recommended)

```bash
git clone https://github.com/indie-master/SSL-Renewal.git ssl-renewal
cd ssl-renewal
chmod +x install.sh
sudo ./install.sh main
```

### Option B: short bootstrap (review before running)

```bash
# Prefer the one-line install commands above for remote bootstrap installs.
```

> Security note: Always review scripts before executing bootstrap one-liners.


### Option C: helper bootstrap script

```bash
chmod +x bootstrap.sh
./bootstrap.sh https://github.com/indie-master/SSL-Renewal.git main
```

---

## Installation

## 1) Main server install

```bash
sudo ./install.sh main
```

Installer flow:

1. Installs dependencies
2. Installs Certbot + Cloudflare plugin
3. Collects:
   - primary domain (example: `example.com`)
   - optional extra primary domains (example: `example.net,example.org`)
   - DNS propagation wait seconds
   - target cert path for nodes
   - optional regional wildcard prefixes (example: `region1,region2`)
4. Cloudflare token onboarding (immediate or deferred)
5. Node list entry (`user@host` per line)
6. Optional SSH key bootstrap with `ssh-copy-id`
7. Optional Telegram setup
8. Installs deploy hook in `/etc/letsencrypt/renewal-hooks/deploy/`
9. Optionally issues certificate and deploys to nodes

## 2) Node install

```bash
sudo ./install.sh node
```

Installer flow:

1. Writes node role config
2. Prepares cert target path
3. Disables local certbot timers/hooks
4. Optionally patches nginx certificate paths

---

## Cloudflare API Token

Required minimum permissions for every zone used by `PRIMARY_DOMAIN` and `EXTRA_DOMAINS_CSV`:

- `Zone -> DNS -> Edit`
- `Zone -> Zone -> Read`

All domains in the certificate must be hosted in Cloudflare or otherwise accessible through the same Cloudflare API token. For example, a certificate covering `example.com`, `example.net`, and `example.org` requires token access to all three zones.

Token file location on main:

```bash
/root/.secrets/certbot/cloudflare.ini
```

Required permissions:

```bash
chmod 600 /root/.secrets/certbot/cloudflare.ini
```

### Flow A: token provided during install

Choose **yes** when installer asks `Add Cloudflare API Token now?`. If `/root/.secrets/certbot/cloudflare.ini` already contains a real token, the installer keeps it unchanged and prints `Existing Cloudflare credentials found, keeping them.`. Replacing an existing real token requires explicit confirmation and creates a timestamped backup such as `/root/.secrets/certbot/cloudflare.ini.bak.YYYYMMDD-HHMMSS` before writing the new token.

### Flow B: token added after install

Choose **no** during install; a placeholder file will be created only when credentials do not already exist. Existing real credentials are preserved.

Then set token later:

```bash
sudo nano /root/.secrets/certbot/cloudflare.ini
# dns_cloudflare_api_token = <REAL_TOKEN>

ssl-renewal cloudflare-help
ssl-renewal doctor
ssl-renewal issue
```

---

## Multi-domain wildcard certificates

SSL Renewal keeps `PRIMARY_DOMAIN` as the certificate name and default domain for backward compatibility. You can add more primary domains with `EXTRA_DOMAINS_CSV`.

For every domain in `PRIMARY_DOMAIN` plus `EXTRA_DOMAINS_CSV`, `ssl-renewal issue` requests:

- the base domain, such as `example.com`
- the direct wildcard, such as `*.example.com`
- every regional wildcard from `REGION_WILDCARDS_CSV`, such as `*.de.example.com`

Example `/etc/ssl-renewal/config.env` values:

```bash
PRIMARY_DOMAIN="example.com"
EXTRA_DOMAINS_CSV="example.net,example.org"
REGION_WILDCARDS_CSV="de,sk,us,msk"
```

The certificate remains named after `PRIMARY_DOMAIN` (`--cert-name example.com`), while the SAN list also includes `example.net` and `example.org` with their wildcard and regional wildcard names. CSV values are trimmed, empty values are ignored, and duplicate `-d` entries are avoided. Empty `EXTRA_DOMAINS_CSV` keeps the original single-domain behavior. The Cloudflare token must have access to every DNS zone used by these domains.

---

## SSH onboarding for nodes

Installer behavior on main:

- Generates `/root/.ssh/id_ed25519` if missing
- Optionally runs `ssh-copy-id` for each node
- If automatic deployment fails (e.g., password auth disabled), installer:
  - prints the public key
  - prints manual `authorized_keys` instructions
  - continues without crashing

Manual method:

```bash
# On main
cat /root/.ssh/id_ed25519.pub

# On each node (as target user)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<PASTE_PUBLIC_KEY_HERE>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

---

## CLI usage

```bash
ssl-renewal help
ssl-renewal doctor
ssl-renewal status
ssl-renewal start
ssl-renewal stop
ssl-renewal restart
ssl-renewal reload
ssl-renewal enable
ssl-renewal disable
ssl-renewal issue
ssl-renewal dry-run
ssl-renewal deploy
ssl-renewal notify-test
ssl-renewal edit-config
ssl-renewal paths
ssl-renewal patch-nginx
ssl-renewal patch-nginx --apply
ssl-renewal disable-node-renew
ssl-renewal cloudflare-help
ssl-renewal cleanup-legacy-hooks
```

---

## Operational workflow

1. Issue/renew cert on main (`ssl-renewal issue`)
2. Certbot deploy hook triggers `deploy-certs.sh` after renewals
3. Main copies `fullchain.pem` + `privkey.pem` to nodes
4. Node validates `nginx -t` before reload
5. Optional Telegram message sent with success/failure summary

### Safe deployment behavior

Certificate deployment is serialized with `flock`, uses bounded SSH/SCP calls,
and retries transient failures. Each node receives the candidate files in a
private staging directory. Before activation the node verifies:

- the certificate is parseable and is valid for at least 24 more hours;
- the certificate covers `PRIMARY_DOMAIN`;
- the certificate public key matches `privkey.pem`.

The current pair is copied to `TARGET_DIR/.ssl-renewal-backups/` before the
candidate is installed. If `nginx -t` or the reload fails, the previous pair is
restored and Nginx is reloaded with it. Backups are intentionally retained for
manual recovery.

The following optional values in `/etc/ssl-renewal/config.env` tune deployment:

```bash
SSH_CONNECT_TIMEOUT="10"
SSH_COMMAND_TIMEOUT="60"
DEPLOY_RETRIES="3"
DEPLOY_RETRY_DELAY="5"
MIN_CERT_VALIDITY_SECONDS="86400"
DEPLOY_LOCK_FILE="/run/lock/ssl-renewal-deploy.lock"
```

---

## First-run checklist

1. `ssl-renewal doctor`
2. `ssl-renewal status`
3. `ssl-renewal dry-run`
4. `ssl-renewal deploy`
5. Validate Nginx on nodes

---

## Troubleshooting

See `docs/TROUBLESHOOTING.md`.

---

## Security notes

- Keep Cloudflare token only on main server.
- Keep `config.env` and Cloudflare credentials at mode `600`.
- Prefer dedicated SSH deploy user with limited rights where possible.
- Do not commit secrets or real infrastructure names to Git.

---

## Upgrade / rollback / uninstall

See `docs/OPERATIONS.md`.

