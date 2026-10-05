# Wordpress-Install-Setup-Script

A bash script to install WordPress with Nginx, MariaDB, and the distribution's default PHP on Debian and Ubuntu.

It can start from an empty server or add another site next to ones that are already there. Each site gets its own directory, Nginx config, database, and database user, all named from the domain. It asks before installing packages, changing PHP limits that are no longer the distribution defaults, removing the default Nginx site, or replacing an existing directory.

Certbot is optional. Both Debian and Ubuntu install `certbot` and `python3-certbot-nginx` from apt. On Ubuntu, if those packages are missing because universe is disabled, the script asks before enabling it. At the end, if snapd is installed, the script lists any installed snaps and asks the user if snap should be removed.

---

## Features

- WordPress, Nginx, MariaDB, and the distribution's default PHP
- One Nginx config per domain (`example.com.conf`)
- Database and user derived from the domain (`example_com`)
- Refuses to create that database or user when they already exist, unless this site's `wp-config.php` already uses them
- Shows the default Nginx site and `/var/www/html` and asks before removing them
- PHP upload, post, and memory limits raised only when they are still at the distribution defaults, otherwise asks
- Optional Certbot from apt on Debian and Ubuntu, with an offer to enable Ubuntu universe when that is required
- Re-run keeps the existing `wp-config.php` password and asks before replacing site files

---

## Requirements

- Debian, or Ubuntu 24.04 or newer
- Root or sudo access

---

## Run

```bash
git clone https://github.com/mattlaxton/Wordpress-Install-Setup-Script.git
cd Wordpress-Install-Setup-Script
chmod +x setup-wp-v1.0.sh
sudo ./setup-wp-v1.0.sh
```

### What it does

1. Asks for the domain and the directory under `/var/www/` (default is the domain)
2. Lists packages that are not already installed and waits for approval
3. Sets PHP limits, or shows the current values and asks when they were already changed
4. Asks before replacing an existing directory, then shows the default Nginx site and asks whether to remove it and `/var/www/html`
5. Writes the new Nginx site, runs `nginx -t`, and reloads only when the test passes
6. Connects to MariaDB (asks for the root password when socket login does not work) and creates this site's database and user after checking they are free
7. Downloads WordPress, writes `wp-config.php`, and sets `www-data` ownership
8. Prints the database password and the Certbot command when Certbot was installed

### Example summary

```
WordPress Location : /var/www/example.com
Access URL         : http://example.com
Nginx Config       : /etc/nginx/sites-available/example.com.conf
Database           : example_com
DB User            : example_com
DB Password        : XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

### Next steps

1. Open the site and finish the WordPress installer.
2. If you installed Certbot:

```bash
sudo certbot --nginx -d example.com
```

License
MIT License — Free to use, modify, and deploy on as many servers as you want.
