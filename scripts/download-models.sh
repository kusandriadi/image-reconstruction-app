#!/bin/bash

################################################################################
# Model Download Script
#
# Downloads the Real-ESRGAN model weights from this repo's GitHub Release
# (tag: models-v1) into backend/model/. The release assets are public and
# directly downloadable, so no authentication is required.
#
# Usage: ./scripts/download-models.sh   (runnable from anywhere)
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${BLUE}→ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Resolve repo root from this script's location so cwd does not matter
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODEL_DIR="$REPO_ROOT/backend/model"

# GitHub Release base URL and expected files
RELEASE_BASE="https://github.com/kusandriadi/image-reconstruction-app/releases/download/models-v1"
EXPECTED_FILES=(
    "ConvNext_REAL-ESRGAN.pth"
    "REAL-ESRGAN.pth"
)

# Minimum plausible size (bytes) to consider a download valid (guards against
# saving an HTML error page instead of the model).
MIN_SIZE=1000000

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Download Model Files from GitHub Release (models-v1)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

################################################################################
# Pick a downloader
################################################################################
if command -v curl &> /dev/null; then
    DOWNLOADER="curl"
elif command -v wget &> /dev/null; then
    DOWNLOADER="wget"
else
    print_error "Neither curl nor wget is installed"
    print_info "Install with: sudo apt install curl -y"
    exit 1
fi
print_success "Using $DOWNLOADER"

mkdir -p "$MODEL_DIR"
print_info "Target directory: $MODEL_DIR"
echo ""

# Return the size of a file in bytes (Linux or macOS), or 0 if missing
file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

# Download a single file with up to 3 attempts (resuming where possible)
download_file() {
    local file="$1"
    local url="$RELEASE_BASE/$file"
    local out="$MODEL_DIR/$file"

    # Skip if a valid copy already exists
    if [ -f "$out" ] && [ "$(file_size "$out")" -ge "$MIN_SIZE" ]; then
        print_success "$file already present ($(file_size "$out") bytes), skipping"
        return 0
    fi

    local attempt
    for attempt in 1 2 3; do
        print_info "Downloading $file (attempt $attempt/3)..."
        if [ "$DOWNLOADER" = "curl" ]; then
            curl -fL --retry 3 -C - -o "$out" "$url" && true
        else
            wget -c -O "$out" "$url" && true
        fi

        if [ -f "$out" ] && [ "$(file_size "$out")" -ge "$MIN_SIZE" ]; then
            print_success "$file downloaded ($(file_size "$out") bytes)"
            return 0
        fi
        print_warning "$file download incomplete, retrying..."
    done

    print_error "Failed to download $file after 3 attempts"
    return 1
}

################################################################################
# Download all expected files
################################################################################
FAILED=()
for file in "${EXPECTED_FILES[@]}"; do
    if ! download_file "$file"; then
        FAILED+=("$file")
    fi
    echo ""
done

################################################################################
# Report
################################################################################
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "ALL MODEL FILES DOWNLOADED SUCCESSFULLY!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ls -lh "$MODEL_DIR"/*.pth
else
    print_error "Some files failed to download: ${FAILED[*]}"
    print_info "Release page: https://github.com/kusandriadi/image-reconstruction-app/releases/tag/models-v1"
    exit 1
fi
