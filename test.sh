#!/usr/bin/env bash
# LaraWatch test runner - builds and runs in Docker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="larawatch-test"

echo "Building test image..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

case "${1:-shell}" in
    shell)
        echo "Dropping into test container..."
        echo "  Run: larawatch init    (discover sites, create baselines)"
        echo "  Then: larawatch scan   (run all checks)"
        echo ""
        docker run --rm -it "$IMAGE_NAME"
        ;;
    scan)
        echo "Running scan..."
        docker run --rm "$IMAGE_NAME" -c '
            # Register the test site and create baselines
            echo "/home/forge/myapp|/home/forge/myapp|" > /opt/larawatch/state/sites.list
            larawatch update
            echo ""
            echo "=== Running scan ==="
            larawatch scan
        '
        ;;
    php-integrity)
        echo "Testing php_integrity tiered classification..."
        docker run --rm "$IMAGE_NAME" -c '
            set -euo pipefail
            SITE="/home/forge/myapp"
            PASS=0
            FAIL=0

            check() {
                local description="$1" expected="$2" file_path="$3"
                # Run scan, capture findings
                local output
                output=$(larawatch scan 2>&1)
                if echo "$output" | grep -q "$expected.*${file_path}"; then
                    echo "  PASS: ${description}"
                    PASS=$((PASS + 1))
                else
                    echo "  FAIL: ${description}"
                    echo "    Expected: ${expected} ... ${file_path}"
                    echo "    Got:"
                    echo "$output" | grep "${file_path}" || echo "    (not found in output)"
                    FAIL=$((FAIL + 1))
                fi
            }

            # Step 1: Create baseline
            echo "=== Creating baseline ==="
            echo "${SITE}|${SITE}|" > /opt/larawatch/state/sites.list
            larawatch update > /dev/null 2>&1

            # ---- Test 1: Clean migration → INFO ----
            echo ""
            echo "=== Test 1: Clean migration file ==="
            cat > "${SITE}/database/migrations/2026_02_18_120000_add_posts_table.php" << '\''PHP'\''
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
class AddPostsTable extends Migration {
    public function up() { Schema::create("posts", function (Blueprint $t) { $t->id(); $t->string("title"); }); }
    public function down() { Schema::dropIfExists("posts"); }
}
PHP
            check "Clean migration → INFO" "INFO.*expected path" "add_posts_table.php"

            # ---- Test 2: Malicious migration → CRITICAL ----
            echo ""
            echo "=== Test 2: Malicious migration file ==="
            cat > "${SITE}/database/migrations/2026_02_18_120001_evil_migration.php" << '\''PHP'\''
<?php
eval(base64_decode($_POST["cmd"]));
PHP
            larawatch update > /dev/null 2>&1  # reset baseline to only have this new file
            # Actually we want both files to be "new" relative to original baseline
            # Re-create original baseline without these test files
            rm -f "${SITE}/database/migrations/2026_02_18_120000_add_posts_table.php"
            rm -f "${SITE}/database/migrations/2026_02_18_120001_evil_migration.php"
            larawatch update > /dev/null 2>&1
            # Now add them back
            cat > "${SITE}/database/migrations/2026_02_18_120000_add_posts_table.php" << '\''PHP'\''
<?php
use Illuminate\Database\Migrations\Migration;
class AddPostsTable extends Migration {
    public function up() { Schema::create("posts", function ($t) { $t->id(); }); }
    public function down() { Schema::dropIfExists("posts"); }
}
PHP
            cat > "${SITE}/database/migrations/2026_02_18_120001_evil_migration.php" << '\''PHP'\''
<?php
eval(base64_decode($_POST["cmd"]));
PHP
            check "Malicious migration → CRITICAL" "CRITICAL.*suspicious content" "evil_migration.php"

            # ---- Test 3: Clean controller → WARNING ----
            echo ""
            echo "=== Test 3: Clean new controller ==="
            cat > "${SITE}/app/Http/Controllers/PostController.php" << '\''PHP'\''
<?php
namespace App\Http\Controllers;
class PostController extends Controller {
    public function index() { return view("posts.index"); }
}
PHP
            check "Clean controller → WARNING" "WARNING.*New PHP file" "PostController.php"

            # ---- Test 4: Malicious controller → CRITICAL ----
            echo ""
            echo "=== Test 4: Malicious controller ==="
            cat > "${SITE}/app/Http/Controllers/DebugController.php" << '\''PHP'\''
<?php
namespace App\Http\Controllers;
class DebugController {
    public function run() { eval($_POST["x"]); }
}
PHP
            check "Malicious controller → CRITICAL" "CRITICAL.*suspicious content" "DebugController.php"

            # ---- Test 5: New file in public/ → always CRITICAL ----
            echo ""
            echo "=== Test 5: New file in public/ ==="
            cat > "${SITE}/public/info.php" << '\''PHP'\''
<?php phpinfo();
PHP
            check "New file in public/ → CRITICAL" "CRITICAL.*New PHP file" "public/info.php"

            # ---- Test 6: New file in storage/ → always CRITICAL ----
            echo ""
            echo "=== Test 6: New file in storage/ ==="
            cat > "${SITE}/storage/shell.php" << '\''PHP'\''
<?php echo "hello";
PHP
            check "New file in storage/ → CRITICAL" "CRITICAL.*New PHP file" "storage/shell.php"

            # ---- Summary ----
            echo ""
            echo "================================"
            echo "Results: ${PASS} passed, ${FAIL} failed"
            echo "================================"
            [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
        '
        ;;
    *)
        echo "Usage: ./test.sh [shell|scan|php-integrity]"
        echo "  shell          - Interactive shell in test container (default)"
        echo "  scan           - Run init + scan and exit"
        echo "  php-integrity  - Test php_integrity tiered severity classification"
        exit 1
        ;;
esac
