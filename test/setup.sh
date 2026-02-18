#!/usr/bin/env bash
# Test environment setup - creates fixtures inside the Docker container
set -euo pipefail

echo "=== Setting up LaraWatch test environment ==="

# --- Create a fake Laravel project ---
SITE_DIR="/home/forge/myapp"
mkdir -p "${SITE_DIR}"/{app/Http/Controllers,app/Models,public,routes,resources/views,storage/framework/views,bootstrap/cache,vendor/laravel/framework,vendor/composer,database/migrations,database/seeders,database/factories,config}

# artisan file (required for site discovery)
cat > "${SITE_DIR}/artisan" << 'PHP'
#!/usr/bin/env php
<?php
// Laravel artisan stub for testing
PHP

# composer.json with laravel/framework (required for site discovery)
cat > "${SITE_DIR}/composer.json" << 'JSON'
{
    "name": "test/myapp",
    "require": {
        "laravel/framework": "^11.0"
    }
}
JSON

# .env file
cat > "${SITE_DIR}/.env" << 'ENV'
APP_NAME=TestApp
APP_ENV=production
APP_KEY=base64:testkey1234567890testkey12345678
APP_DEBUG=false
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_DATABASE=myapp
DB_USERNAME=forge
DB_PASSWORD=secret
ENV
chmod 640 "${SITE_DIR}/.env"

# Sample PHP files
cat > "${SITE_DIR}/app/Http/Controllers/HomeController.php" << 'PHP'
<?php
namespace App\Http\Controllers;

class HomeController extends Controller
{
    public function index()
    {
        return view('welcome');
    }
}
PHP

cat > "${SITE_DIR}/public/index.php" << 'PHP'
<?php
require __DIR__.'/../vendor/autoload.php';
$app = require_once __DIR__.'/../bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);
$response = $kernel->handle($request = Illuminate\Http\Request::capture());
$response->send();
PHP

cat > "${SITE_DIR}/routes/web.php" << 'PHP'
<?php
use Illuminate\Support\Facades\Route;
Route::get('/', [App\Http\Controllers\HomeController::class, 'index']);
PHP

cat > "${SITE_DIR}/resources/views/welcome.blade.php" << 'PHP'
<html><body><h1>Welcome</h1></body></html>
PHP

# vendor/composer/installed.json (for vendor integrity check)
cat > "${SITE_DIR}/vendor/composer/installed.json" << 'JSON'
{"packages":[{"name":"laravel/framework","version":"v11.0.0"}]}
JSON

# Config file
cat > "${SITE_DIR}/config/app.php" << 'PHP'
<?php
return ['name' => 'TestApp', 'env' => 'production'];
PHP

# Existing migration (part of baseline)
cat > "${SITE_DIR}/database/migrations/2024_01_01_000000_create_users_table.php" << 'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
class CreateUsersTable extends Migration {
    public function up() { Schema::create('users', function (Blueprint $table) { $table->id(); $table->string('name'); }); }
    public function down() { Schema::dropIfExists('users'); }
}
PHP

# --- Nginx config ---
mkdir -p /etc/nginx/sites-enabled
cat > /etc/nginx/sites-enabled/myapp.conf << 'NGINX'
server {
    listen 80;
    server_name myapp.test;
    root /home/forge/myapp/public;
    index index.php;
}
NGINX

# Nginx logs
mkdir -p /var/log/nginx
echo '192.168.1.1 - - [17/Feb/2026:10:00:00 +0000] "GET / HTTP/1.1" 200 1234' > /var/log/nginx/access.log
echo '2026/02/17 10:00:00 [error] some test error' > /var/log/nginx/error.log

# --- SSH keys ---
mkdir -p /root/.ssh
ssh-keygen -t ed25519 -f /root/.ssh/test_key -N "" -q 2>/dev/null || true
cat /root/.ssh/test_key.pub > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# --- Cron entry ---
echo "0 3 * * * /usr/bin/certbot renew --quiet" | crontab -

# --- LaraWatch config ---
LARAWATCH_DIR="/opt/larawatch"
mkdir -p "${LARAWATCH_DIR}/config" "${LARAWATCH_DIR}/state" "${LARAWATCH_DIR}/logs"
cat > "${LARAWATCH_DIR}/config/larawatch.conf" << 'CONF'
SCAN_DIRS="/home"
SCAN_DEPTH=5
EXCLUDE_SITES=""
MANUAL_SITES=""
CHECK_PHP_INTEGRITY="true"
CHECK_ENV_INTEGRITY="true"
CHECK_WEBSHELL="true"
CHECK_SSH_KEYS="true"
CHECK_CRON="true"
CHECK_PORTS="true"
CHECK_PROCESSES="true"
CHECK_SERVICE_EXPOSURE="true"
CHECK_USERS="true"
CHECK_NGINX="true"
CHECK_SHELL_PROFILES="true"
CHECK_TMPDIR="true"
CHECK_LOG_ANOMALIES="true"
CHECK_DISK="true"
CHECK_CPU="true"
CHECK_MEMORY="true"
NOTIFY_TELEGRAM="false"
NOTIFY_EMAIL="false"
NOTIFY_MIN_SEVERITY="INFO"
NOTIFY_COOLDOWN=3600
DISK_WARN_THRESHOLD=80
DISK_CRITICAL_THRESHOLD=90
CPU_WARN_THRESHOLD=90
CPU_CRITICAL_THRESHOLD=95
MEMORY_WARN_THRESHOLD=80
MEMORY_CRITICAL_THRESHOLD=90
CONF

# Symlink to PATH
mkdir -p /usr/local/bin
ln -sf "${LARAWATCH_DIR}/larawatch" /usr/local/bin/larawatch

echo "=== Test environment ready ==="
echo "Run: larawatch init   (to discover sites and create baselines)"
echo "Then: larawatch scan  (to run all checks)"
