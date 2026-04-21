# Native (non-Docker) installation from Git

This guide is for **advanced operators** who want Coolify checked out with **git** and run as a **normal Linux stack** (PHP-FPM + web server + Postgres + Redis + workers). It is **not** the path Coolify ships for production: the supported installer is Docker-based (`curl … | bash` using [scripts/install.sh](scripts/install.sh)). Native installs are **your responsibility** to secure, upgrade, and tune.

**Stack expectations (from this repo):**

- PHP **8.4+** ([composer.json](composer.json) `require.php`)
- **PostgreSQL** (15+ is typical; match what you run in production)
- **Redis** 7+
- **Node.js** for building assets (CI uses **Node 24** in [docker/production/Dockerfile](docker/production/Dockerfile); LTS 22+ usually works—prefer matching CI if builds fail)
- A **reverse proxy** (Nginx, Caddy, etc.) terminating TLS and forwarding to PHP
- **Soketi** (or compatible Pusher server) for realtime / Livewire broadcasting
- **Supervisor** (or systemd) for queue workers, **Laravel Horizon**, and the scheduler

---

## 1. Server packages (Debian / Ubuntu example)

Adjust names for your distribution (Fedora/RHEL use `dnf`, PHP package prefixes differ).

```bash
sudo apt update
sudo apt install -y git curl unzip acl \
  postgresql redis-server \
  nginx \
  supervisor \
  # PHP 8.4: use your distro’s packages or https://launchpad.net/~ondrej/+archive/ubuntu/php
  php8.4-fpm php8.4-cli php8.4-common php8.4-pgsql php8.4-redis php8.4-mbstring \
  php8.4-xml php8.4-curl php8.4-zip php8.4-intl php8.4-bcmath php8.4-gd php8.4-readline
```

Install **Composer** ([getcomposer.org](https://getcomposer.org/download/)) and **Node** (e.g. [NodeSource](https://github.com/nodesource/distributions) or `nvm`).

Create DB user and database:

```bash
sudo -u postgres psql -c "CREATE USER coolify WITH PASSWORD 'change-me';"
sudo -u postgres psql -c "CREATE DATABASE coolify OWNER coolify;"
```

Configure **Redis** with a password if exposed; set `REDIS_PASSWORD` in `.env` accordingly.

---

## 2. Clone the application

```bash
sudo mkdir -p /var/www
sudo git clone https://github.com/coollabsio/coolify.git /var/www/coolify
cd /var/www/coolify
sudo git checkout next   # or the branch you intend to run; upstream uses `next` for PRs (see CONTRIBUTING.md)
```

Run the app as a dedicated user (example `www-data`):

```bash
sudo chown -R www-data:www-data /var/www/coolify
sudo -u www-data git config --global --add safe.directory /var/www/coolify
```

---

## 3. Environment file

```bash
sudo -u www-data cp .env.development.example .env
# For production-like settings, merge in what you need from .env.production (secrets, APP_KEY, etc.)
sudo -u www-data nano .env
```

Set at minimum:

| Variable | Example |
|----------|---------|
| `APP_ENV` | `production` |
| `APP_KEY` | output of `php artisan key:generate --show` |
| `APP_URL` | `https://coolify.example.com` |
| `DB_*` | host, port, database, user, password |
| `REDIS_*` | host, password, port |
| `PUSHER_*` / `PUSHER_BACKEND_*` | match your Soketi host/port (browser vs server; see comments in [.env.development.example](.env.development.example)) |

---

## 4. Install PHP and JavaScript dependencies

```bash
cd /var/www/coolify
sudo -u www-data composer install --no-dev --optimize-autoloader --no-interaction
sudo -u www-data npm ci
sudo -u www-data npm run build
```

Development install uses `composer install` with dev dependencies; production should use `--no-dev` unless you are debugging.

---

## 5. Laravel bootstrap

```bash
cd /var/www/coolify
sudo -u www-data php artisan storage:link || true
sudo -u www-data php artisan migrate --force
# Optional first user / seeding depends on your branch; see database/seeders and docs.
sudo -u www-data php artisan config:cache
sudo -u www-data php artisan route:cache
sudo -u www-data php artisan view:cache
```

Ensure permissions:

```bash
sudo chown -R www-data:www-data storage bootstrap/cache
sudo chmod -R ug+rwx storage bootstrap/cache
```

---

## 6. Web server → PHP-FPM

Point the **document root** at `public/` (standard Laravel).

**Nginx** (minimal illustration—replace socket path and `server_name`):

```nginx
server {
    listen 80;
    server_name coolify.example.com;
    root /var/www/coolify/public;

    index index.php;
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }
}
```

Put TLS in front (Let’s Encrypt, Caddy automatic HTTPS, etc.). For **WebSockets** (Soketi), the proxy must allow **upgrade** headers on the paths your deployment uses (often port 6001 on a separate host or subdomain).

---

## 7. Soketi (realtime)

Coolify expects a **Pusher-compatible** websocket server. Options:

1. Run the **same Soketi image** as a tiny sidecar (still Docker—only the app is native), or  
2. Install Soketi globally: `npm install -g @soketi/soketi` and run it under **systemd** with env vars matching `PUSHER_APP_*` in `.env`.

Without Soketi, the UI will warn that realtime is unavailable.

---

## 8. Queue, Horizon, and scheduler (Supervisor examples)

Run **Horizon** (Redis queues) and **schedule:work** (or cron calling `schedule:run` every minute).

`/etc/supervisor/conf.d/coolify-horizon.conf`:

```ini
[program:coolify-horizon]
process_name=%(program_name)s
command=php /var/www/coolify/artisan horizon
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/www/coolify/storage/logs/horizon.log
stopwaitsecs=3600
```

Cron (alternative to long-running `schedule:work`):

```cron
* * * * * www-data cd /var/www/coolify && php artisan schedule:run >> /dev/null 2>&1
```

Then:

```bash
sudo supervisorctl reread && sudo supervisorctl update && sudo supervisorctl start coolify-horizon
```

---

## 9. Updates via Git

```bash
cd /var/www/coolify
sudo -u www-data git pull
sudo -u www-data composer install --no-dev --optimize-autoloader --no-interaction
sudo -u www-data npm ci && sudo -u www-data npm run build
sudo -u www-data php artisan migrate --force
sudo -u www-data php artisan optimize
sudo supervisorctl restart coolify-horizon
```

---

## 10. What you are not getting vs Docker install

- No **automatic** Traefik/proxy stack from Coolify’s installer—you wire routing yourself.  
- No bundled **testing-host** / helper images unless you add them.  
- **SSH keys, Docker socket access, and remote server** features still assume the OS user running PHP has the right privileges—mirror what the official image grants (`www-data` or a dedicated `coolify` user).  
- **Support**: upstream troubleshooting assumes the **Docker** layout; native issues are harder to reproduce.

For most users, prefer **[official installation](https://coolify.io/docs/installation)**. Use this document when you deliberately need a **from-source, bare-metal** layout.
