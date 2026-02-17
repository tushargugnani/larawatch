# LaraWatch

**Lightweight security monitor for Laravel servers** — detects webshells, unauthorized SSH keys, cron tampering, exposed services, .env changes, and more. Alerts via Telegram and Email.

Pure Bash. Zero dependencies beyond standard Linux tools. Works on Forge, Ploi, RunCloud, cPanel, Coolify, bare metal, or any custom setup.

## Quick Start

```bash
git clone https://github.com/tushargugnani/larawatch.git ~/.larawatch && ~/.larawatch/install.sh
```

The installer will:
1. Auto-discover all Laravel sites on your server
2. Create security baselines
3. Walk you through notification setup (Telegram/Email) — or skip for later
4. Install a cron job to scan every 5 minutes
5. Optionally run your first scan

You can also configure notifications anytime after install:

```bash
larawatch config --telegram-token "BOT_TOKEN" --telegram-chat "CHAT_ID"
larawatch test   # verify it works
```

## What It Monitors

| Check | Scope | Severity |
|-------|-------|----------|
| PHP File Integrity | Per-site | CRITICAL (new), WARNING (modified) |
| .env Integrity | Per-site | CRITICAL (changed/missing) |
| Webshell Scan | Per-site | CRITICAL (any match) |
| SSH Keys | System | CRITICAL (new key) |
| Cron Jobs | System | CRITICAL (new entry) |
| Listening Ports | System | CRITICAL (new port) |
| Suspicious Processes | System | CRITICAL (miners, reverse shells) |
| Service Exposure | System | CRITICAL (Redis/Memcached on 0.0.0.0) |
| User Accounts | System | CRITICAL (new user/sudo member) |
| Nginx Config | System | WARNING (modified) |
| Log Anomalies | System | WARNING (.env probes, 5xx spikes) |

## How It Works

### Smart Site Discovery

LaraWatch finds Laravel projects by looking for `artisan` + `composer.json` containing `laravel/framework`. No folder conventions assumed.

| Server Management | Typical Path | Detection |
|-------------------|-------------|-----------|
| Laravel Forge | `/home/forge/site.com/current/` | Finds artisan, detects symlink |
| Ploi | `/home/ploi/site.com/` | Finds artisan directly |
| RunCloud | `/home/runcloud/webapps/app/` | Finds artisan directly |
| cPanel | `/home/user/public_html/` | Finds artisan directly |
| Coolify | `/data/coolify/applications/xxx/` | Finds artisan directly |
| Bare metal | `/var/www/site/` | Finds artisan directly |
| Envoyer | `/home/user/site/current/` | Finds artisan, detects symlink |

### Baseline Comparison

On first run (`larawatch init`), LaraWatch captures the known-good state of your server. On each scan, it compares the current state against baselines and alerts on any deviation.

## CLI Reference

```
larawatch              # Run all checks (same as 'scan')
larawatch scan         # Run all checks
larawatch init         # First-time setup (interactive)
larawatch update       # Refresh all baselines
larawatch update --site mysite.com     # Update one site
larawatch update --check php_integrity # Update one check
larawatch status       # Dashboard
larawatch test         # Send test notification
larawatch config       # Configure settings (see below)
larawatch add-site /path/to/laravel    # Add site manually
larawatch remove-site mysite.com       # Remove site
larawatch install-cron                 # Set up cron job
larawatch uninstall-cron               # Remove cron job
larawatch version      # Show version
larawatch help         # Show usage
```

## Notifications

The interactive setup during `larawatch init` will walk you through configuring notifications. You can also configure them manually:

### Telegram

During `larawatch init`, just paste your bot token — LaraWatch will automatically detect your chat ID when you send a message to the bot. No need to manually look up chat IDs.

To configure manually:

```bash
larawatch config --telegram-token "123456:ABC-DEF" --telegram-chat "-1001234567890"
larawatch test  # send a test message
```

### Email (SMTP)

```bash
larawatch config \
  --email-to "you@example.com" \
  --email-smtp "smtp.example.com" \
  --email-smtp-port 587 \
  --email-smtp-user "user" \
  --email-smtp-pass "pass"
larawatch test  # send a test email
```

### Email (sendmail)

If `sendmail` or `mail` is available, just set the recipient:

```bash
larawatch config --email-to "you@example.com"
```

## After Deployments

For Forge/Envoyer (symlink deploys), add to your deploy script:

```bash
larawatch update --site $FORGE_SITE_NAME 2>/dev/null || true
```

For git pull / direct deploys:

```bash
larawatch update --site mysite.com
```

Or update all baselines:

```bash
larawatch update
```

## Configuration

All settings in `config/larawatch.conf`. Key options:

```bash
SCAN_DIRS="/home"           # Directories to scan
SCAN_DEPTH=4                # Max depth
CHECK_PHP_INTEGRITY="true"  # Toggle individual checks
NOTIFY_COOLDOWN=3600        # Alert dedup window (seconds)
NOTIFY_MIN_SEVERITY="WARNING"  # CRITICAL, WARNING, or INFO
```

## Requirements

- Bash 4.0+
- Standard Linux tools: `curl`, `sha256sum`, `ss`, `find`, `grep`
- No root required (but some checks benefit from it)

## Uninstall

```bash
~/.larawatch/uninstall.sh
```

## License

MIT
