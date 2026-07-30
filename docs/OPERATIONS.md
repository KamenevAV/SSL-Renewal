# Operations, Upgrade, Rollback

## Normal operations

- Issue/renew now: `ssl-renewal issue`
- Test renewal flow: `ssl-renewal dry-run`
- Push current certs: `ssl-renewal deploy`
- Health check: `ssl-renewal doctor`

## Add a domain after install

1. Edit `/etc/ssl-renewal/config.env`.
2. Add the new domain to `EXTRA_DOMAINS_CSV`. For example:

   ```bash
   PRIMARY_DOMAIN="example.com"
   EXTRA_DOMAINS_CSV="example.net,example.org"
   ```

3. Ensure the Cloudflare token has `Zone -> DNS -> Edit` and `Zone -> Zone -> Read` access to every zone in `PRIMARY_DOMAIN` and `EXTRA_DOMAINS_CSV`.
4. Issue the expanded certificate:

   ```bash
   ssl-renewal issue
   ```

5. If dry-run fails with `NXDOMAIN` for newly added wildcard domains, increase `DNS_PROPAGATION_SECONDS` to `180` or `300`. Existing Certbot renewal files may also need `dns_cloudflare_propagation_seconds = 180`; this is usually Cloudflare/Let's Encrypt secondary DNS validation timing.
6. Deploy the updated certificate to nodes:

   ```bash
   ssl-renewal deploy
   ```


## Disable old `/opt/certs-sync` hooks safely

Use the built-in helper on the main server:

```bash
ssl-renewal cleanup-legacy-hooks
```

The helper does not delete legacy files without a backup. It:

- backs up `/opt/certs-sync` to `/root/old-certs-sync-backup/certs-sync.TIMESTAMP` when it exists
- moves old hooks under `/etc/letsencrypt/renewal-hooks` that reference `/opt/certs-sync` or `certs-sync` into that backup
- renames `/opt/certs-sync` to `/opt/certs-sync.disabled.TIMESTAMP`
- leaves `/etc/letsencrypt/renewal-hooks/deploy/ssl-renewal-deploy.sh` intact

## Disable local renewals on nodes

From main:

```bash
ssl-renewal disable-node-renew
```

On a specific node:

```bash
/opt/ssl-renewal/node-prep.sh --disable-renew-only
```

## Upgrade process

1. Pull latest repository state.
2. Re-run installer on main and nodes as needed.
3. Validate using `doctor`, `status`, and `dry-run`.

## Rollback

- Keep backup of `/etc/ssl-renewal/config.env` before upgrades.
- For nginx path patch rollbacks, use backups from:
  - `/root/nginx-ssl-renewal-backup-<timestamp>/`
- Restore previous scripts in `/opt/ssl-renewal/` from backup or version control.

## Uninstall (manual)

1. Remove CLI symlink: `/usr/local/bin/ssl-renewal`
2. Remove app files: `/opt/ssl-renewal`
3. Remove config: `/etc/ssl-renewal`
4. Optionally remove certbot deploy hook:
   `/etc/letsencrypt/renewal-hooks/deploy/ssl-renewal-deploy.sh`
# Deployment recovery

Every successful activation attempt first saves the previous node certificate
pair below:

```text
<TARGET_DIR>/.ssl-renewal-backups/<timestamp>-<pid>/
```

Failed Nginx validation or reload triggers an automatic rollback. If manual
recovery is ever needed, copy both `fullchain.pem` and `privkey.pem` from the
same backup directory to `TARGET_DIR`, then run:

```bash
nginx -t && systemctl reload nginx
```

Do not mix a certificate from one backup with a private key from another.

