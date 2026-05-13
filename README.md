# Wordpress-Install-Setup-Script
A comprehensive Bash script to install a a running instance of Wordpress and all required software.

# WordPress One-Click Setup Script (Debian/Ubuntu)

A clean, minimal, and production-ready bash script to deploy a fresh WordPress site with dedicated Nginx configuration in under 5 minutes.

This is designed to take a fresh server or VM from empty to running WordPress with minimal effort. This will install all necessary software to run WordPress and nothing more. It sets sane defaults for PHP and MariaDB that are typical of most installations, secures the MariaDB install, uses a strong DB password, and is transparent during the process. It doesn't touch any other system files outside of it's scope.

If you're unsure about this script, have your favorite AI look it over and ask it it's dangerous in any way.

* Snap install for Certbot will not run on a non-Ubuntu OS.

---

## Features

- **Fully automated** WordPress + Nginx + MariaDB + PHP 8.3 setup
- Dedicated per-site Nginx config (no polluting default site)
- Secure random database password
- Optimized PHP settings (64M upload, 256M memory, etc.)
- Proper file permissions
- Optional Certbot (Let's Encrypt) installation via Snap
- Safe to re-run (idempotent)
- Clean, readable output with color-coded logging

---

## Requirements

- Debian Linux or Ubuntu 24.04 (or newer)
- Root or sudo access
- Fresh server (recommended)

---

## Quick Install & Run

```bash
# 1. Download the script (Clone this repo)
$ git clone https://github.com/mattlaxton/Wordpress-Install-Setup-Script.git

# 2. Make executable
$ cd Wordpress-Install-Setup-Script
$ chmod +x setup-wp-1.x.sh

# 3. Run it
$ sudo ./setup-wp-v1.x.sh
or
$ sudo bash setup-wp-v1.x.sh
```
### What the Script Does

1. Installs required packages (Nginx, MariaDB, PHP 8.3 + extensions)
2. Set your wordpress directory under /var/www/ (you decide)
3. Secures MariaDB and creates wordpress database + wp_user
4. Downloads and extracts latest WordPress
5. Creates secure wp-config.php with strong salts
6. Sets correct ownership (www-data) and permissions
7. Creates a dedicated Nginx site config
8. Restarts services
9. Shows final credentials and next steps

### Example Output Summary
```
WordPress Location : /var/www/html
Access URL         : http://your-domain-or-ip
Nginx Config       : /etc/nginx/sites-available/your-domain.conf
Database           : wordpress
DB User            : wp_user
DB Password        : XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```
### Recommended Next Steps

After running the script:

1. Open the site in browser to complete WordPress installation
2. (Optional) Enable HTTPS on Ubuntu:
```
sudo certbot --nginx -d yourdomain.com
```
Thats it...simple.

License
MIT License — Free to use, modify, and deploy on as many servers as you want.
