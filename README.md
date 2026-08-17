# SkylerNodes Professional Pterodactyl Installer

A SkylerNodes-branded menu installer for the official Pterodactyl Panel on Ubuntu 22.04/24.04.

## One-command launch

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alokgame2009-bot/skylernodes-installer/main/install.sh)
```

## Menu

```text
[1] Install Panel
    Fresh Pterodactyl Panel Installation

[2] User Management
    Create Admin / User Accounts

[3] Panel Update
    Update to a Pterodactyl Release

[4] Domain / SSL
    Configure Domain and SSL

[5] Uninstall Panel
    Remove Panel Data and Configuration

[6] phpMyAdmin
    Database Management
```

### Option 1
The installer automates the main Panel setup: PHP 8.3, MariaDB, Redis, Nginx, Composer, the latest official Panel release, database migrations/seeding, queue worker, cron scheduler, Nginx configuration, optional Let's Encrypt SSL, and the first admin account.

### Requirements
- Ubuntu 22.04 or Ubuntu 24.04
- Root access
- A domain pointing to the VPS if using a domain/SSL
- A fresh VPS is recommended for the first test

### Security notes
- Backups are stored under `/root/skylernodes-backups`.
- phpMyAdmin is exposed on port 8080 by option 6; for production, protect it with HTTPS and access controls.
- Option 5 intentionally does not delete the database automatically, reducing the chance of accidental data loss.

This project is independent and is not affiliated with Pterodactyl or Nobita Cloud.

  Installing PHP dependencies      [████████████████████████████] 100% ✓
  Running migrations               [████████████████████████████] 100% ✓
  Configuring Nginx                [████████████████████████████] 100% ✓
```

ANSI colors are used so Termius can render the branding according to its terminal theme.
