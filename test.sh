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
    *)
        echo "Usage: ./test.sh [shell|scan]"
        echo "  shell  - Interactive shell in test container (default)"
        echo "  scan   - Run init + scan and exit"
        exit 1
        ;;
esac
