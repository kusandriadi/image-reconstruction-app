#!/bin/bash

################################################################################
# Stop Script - Stop all running Docker services
# Usage: ./stop.sh
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}→ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Run from the repo root regardless of where this script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Stop Image Reconstruction Application"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Detect Docker Compose command (v2 plugin preferred, fall back to v1)
COMPOSE=""
if docker compose version &> /dev/null; then
    COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE="docker-compose"
else
    print_error "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)"
    exit 1
fi

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml not found. Are you in the correct directory?"
    exit 1
fi

################################################################################
# Check if application is running
################################################################################
print_info "Checking application status..."

if ! $COMPOSE ps | grep -q "Up"; then
    print_warning "Application is not running"
    echo ""
    print_info "Current status:"
    $COMPOSE ps
    echo ""
    print_info "Nothing to stop. Application is already stopped."
    exit 0
fi

print_success "Application is currently running"
echo ""

################################################################################
# Show current status
################################################################################
print_info "Current running containers:"
$COMPOSE ps
echo ""

################################################################################
# Stop services
################################################################################
print_info "Stopping all services..."

$COMPOSE down

print_success "All services stopped successfully"
echo ""

# Stop the combined log collector (systemd service and/or background nohup)
if systemctl list-unit-files 2>/dev/null | grep -q "image-reconstruction-logs.service"; then
    sudo systemctl stop image-reconstruction-logs.service 2>/dev/null || true
    print_info "Log collector (systemd) stopped"
fi
if [ -f logs/.collector.pid ]; then
    kill "$(cat logs/.collector.pid 2>/dev/null)" 2>/dev/null || true
    rm -f logs/.collector.pid
    print_info "Log collector (background) stopped"
fi
echo ""

################################################################################
# Verify
################################################################################
print_info "Verifying shutdown..."
sleep 2

if $COMPOSE ps | grep -q "Up"; then
    print_warning "Some containers are still running"
    $COMPOSE ps
else
    print_success "All containers stopped"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "APPLICATION STOPPED SUCCESSFULLY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "To start the application again, run:"
echo "  • Production (with SSL):  scripts/deploy-production.sh [domain] [email]"
echo "  • Local (HTTP):           scripts/deploy-local.sh"
echo "  • Update & restart:       scripts/restart.sh"
echo ""
