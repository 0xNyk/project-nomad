# Project N.O.M.A.D. Outage and Disaster Recovery Runbook

This runbook is for restoring a broken or unavailable Project N.O.M.A.D. host quickly and safely.

## 1) What to prepare before an outage

1. Keep periodic backups:
   - `sudo bash /opt/project-nomad/backup_nomad.sh --include-images`
2. Store backup archives off-host (external disk/NAS/another trusted machine).
3. Test restore regularly on a non-production host.
4. Keep this checklist handy and print a copy for offline use.

## 2) Severity levels

- Sev-1: Command Center unavailable and no backup host.
- Sev-2: One or more core services degraded (admin/mysql/redis unhealthy).
- Sev-3: Non-critical features degraded but Command Center usable.

For Sev-1 and Sev-2, execute Sections 3–6 immediately.

## 3) Fast triage commands

Run on the affected host:

```bash
sudo docker ps -a --filter "name=^nomad_" --format "table {{.Names}}\t{{.Status}}"
sudo docker compose -p project-nomad -f /opt/project-nomad/compose.yml ps
curl -f http://localhost:8080/api/health
```

If these fail due to missing files or unrecoverable container errors, perform full restore (Section 5).

## 4) Quick recovery (no full restore yet)

```bash
sudo bash /opt/project-nomad/stop_nomad.sh
sudo docker compose -p project-nomad -f /opt/project-nomad/compose.yml up -d --force-recreate
sudo bash /opt/project-nomad/verify_nomad_recovery.sh
```

If health still fails, continue to full restore.

## 5) Full restore from backup

1. Copy backup archive to target host.
2. Restore:

```bash
sudo bash /opt/project-nomad/restore_nomad.sh --backup /path/to/nomad-backup-YYYYMMDD_HHMMSS.tar.gz
```

3. Validate:

```bash
sudo bash /opt/project-nomad/verify_nomad_recovery.sh
```

4. Confirm UI is reachable:
   - `http://localhost:8080`
   - `http://<host-ip>:8080`

## 6) Post-restore validation checklist

- [ ] `curl -f http://localhost:8080/api/health` returns success
- [ ] `nomad_admin`, `nomad_mysql`, `nomad_redis` are running
- [ ] Expected documents/config in `/opt/project-nomad/storage`
- [ ] Command Center loads and key pages render
- [ ] Install/management actions are functional

## 7) Known high-risk points

- Loss of `/opt/project-nomad/compose.yml` (contains generated runtime secrets)
- Corrupted `/opt/project-nomad/mysql` data directory
- Docker daemon failure or disk exhaustion
- Registry/network outages preventing image pulls

Mitigation: use `backup_nomad.sh --include-images` to preserve local images for offline restore.

## 8) Suggested backup schedule

Daily (light):
```bash
sudo bash /opt/project-nomad/backup_nomad.sh
```

Weekly (full/offline-ready):
```bash
sudo bash /opt/project-nomad/backup_nomad.sh --include-images
```

After each update:
```bash
sudo bash /opt/project-nomad/backup_nomad.sh --include-images --name post-update-$(date +%Y%m%d_%H%M%S)
```

## 9) Recovery drill (quarterly)

1. Provision a test host.
2. Run restore from latest backup.
3. Run verification script.
4. Record:
   - Restore start/end timestamps
   - Issues encountered
   - Fixes applied
5. Update this runbook if gaps were found.
