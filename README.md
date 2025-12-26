# Automation Scripts

Additional automation scripts for Linux system administration.

## Scripts

### auto_update.sh

Automated system update with safety checks and rollback support.

**Features:**
- Pre-update checks (disk space, network, running services)
- Package snapshot before update for rollback
- Multiple update modes: safe, full, security-only
- Automatic cleanup of unused packages
- Reboot detection and optional auto-reboot
- Telegram notifications
- Comprehensive logging

**Usage:**
```bash
./auto_update.sh                    # Safe update
./auto_update.sh -t full            # Full dist-upgrade
./auto_update.sh -t security        # Security updates only
./auto_update.sh -c                 # Check pending updates
./auto_update.sh -n                 # Dry run (simulate)
./auto_update.sh -t full -r         # Full update + auto-reboot
```

---

### log_cleanup.sh

Log rotation and cleanup utility with compression and archiving.

**Features:**
- Delete old log files
- Compress logs older than N days
- Truncate oversized active logs (with tail backup)
- Clean systemd journal
- Clean Docker container logs
- Clean package manager cache
- Clean temp files
- Configurable thresholds
- Telegram alerts

**Usage:**
```bash
./log_cleanup.sh                    # Basic cleanup
./log_cleanup.sh -A                 # Full cleanup (all tasks)
./log_cleanup.sh -j -D              # Logs + journal + Docker
./log_cleanup.sh -d /opt/app/logs   # Add custom directory
./log_cleanup.sh -a 14 -s 50        # 14 days max, 50MB max size
```

---

### ssl_manager.sh

SSL/TLS certificate manager for Let's Encrypt.

**Features:**
- List all certificates with expiry status
- Request new certificates
- Automatic renewal with service reload
- Certificate health checks with alerts
- Test SSL connection
- Revoke certificates
- Auto-install renewal hooks
- Cron job setup for monitoring
- Telegram notifications

**Usage:**
```bash
./ssl_manager.sh list                           # List all certs
./ssl_manager.sh check                          # Check & alert
./ssl_manager.sh request example.com            # New certificate
./ssl_manager.sh request example.com "www.example.com"  # With SANs
./ssl_manager.sh renew                          # Renew all
./ssl_manager.sh renew --force                  # Force renewal
./ssl_manager.sh test example.com               # Test SSL
./ssl_manager.sh install-hook                   # Install hooks
./ssl_manager.sh setup-cron                     # Setup monitoring
```

---

## Configuration

All scripts support Telegram notifications. Set these variables:
```bash
TELEGRAM_BOT_TOKEN="your_bot_token"
TELEGRAM_CHAT_ID="your_chat_id"
```

## Installation

```bash
chmod +x *.sh
sudo cp *.sh /usr/local/bin/
```

## Cron Examples

```bash
# Daily system update at 3 AM
0 3 * * * /usr/local/bin/auto_update.sh -t security

# Weekly full cleanup
0 4 * * 0 /usr/local/bin/log_cleanup.sh -A

# SSL check daily at 6 AM
0 6 * * * /usr/local/bin/ssl_manager.sh check
```

## Author

Mikhail Miasnikou — System Administrator / DevOps Engineer

## License

MIT
