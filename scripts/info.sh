#!/bin/bash

################################################################################
# Info Script - Show application status and resource usage
# Usage: scripts/info.sh
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

print_header() {
    echo -e "${CYAN}$1${NC}"
}

# Run from the repo root regardless of where this script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Application Status & Resource Usage"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

################################################################################
# Detect Docker Compose command (v2 plugin preferred, fall back to v1)
################################################################################
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
    print_error "docker-compose.yml not found"
    print_info "Run this script from the project root directory"
    exit 1
fi

################################################################################
# Application Status
################################################################################
print_header "📊 APPLICATION STATUS"
echo ""

BACKEND_RUNNING=false
FRONTEND_RUNNING=false

# Check if containers are running
if $COMPOSE ps | grep -q "backend.*Up"; then
    BACKEND_RUNNING=true
    print_success "Backend: Running"
else
    print_error "Backend: Not running"
fi

if $COMPOSE ps | grep -q "frontend.*Up"; then
    FRONTEND_RUNNING=true
    print_success "Frontend: Running"
else
    print_error "Frontend: Not running"
fi

echo ""

if [ "$BACKEND_RUNNING" = false ] && [ "$FRONTEND_RUNNING" = false ]; then
    print_warning "Application is not running"
    echo ""
    print_info "Start with: scripts/deploy-production.sh [domain] [email]  (or scripts/deploy-local.sh)"
    exit 0
fi

################################################################################
# Uptime
################################################################################
print_header "⏱️  UPTIME"
echo ""

if [ "$BACKEND_RUNNING" = true ]; then
    BACKEND_UPTIME=$($COMPOSE ps backend | grep Up | awk '{for(i=1;i<=NF;i++) if($i=="Up") print $(i+1), $(i+2)}')
    echo "Backend:  $BACKEND_UPTIME"
fi

if [ "$FRONTEND_RUNNING" = true ]; then
    FRONTEND_UPTIME=$($COMPOSE ps frontend | grep Up | awk '{for(i=1;i<=NF;i++) if($i=="Up") print $(i+1), $(i+2)}')
    echo "Frontend: $FRONTEND_UPTIME"
fi

echo ""

################################################################################
# Resource Usage
################################################################################
print_header "💻 RESOURCE USAGE"
echo ""

# Get container stats (CPU, Memory)
STATS=$(docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep -E "backend|frontend")

if [ -n "$STATS" ]; then
    echo "$STATS" | while read line; do
        if echo "$line" | grep -q "NAME"; then
            printf "%-30s %-12s %-20s\n" "Container" "CPU" "Memory"
            echo "───────────────────────────────────────────────────────────────"
        else
            CONTAINER=$(echo "$line" | awk '{print $1}')
            CPU=$(echo "$line" | awk '{print $2}')
            MEMORY=$(echo "$line" | awk '{print $3, $4, $5, $6}')

            # Convert memory to MB
            MEMORY_MB=$(echo "$line" | awk '{
                mem=$3
                if (mem ~ /GiB/) {
                    gsub(/GiB/, "", mem)
                    printf "%.0f MB", mem * 1024
                } else if (mem ~ /MiB/) {
                    gsub(/MiB/, "", mem)
                    printf "%.0f MB", mem
                } else {
                    print mem
                }
            }')

            printf "%-30s %-12s %-20s\n" "$CONTAINER" "$CPU" "$MEMORY_MB"
        fi
    done
else
    print_warning "Could not retrieve container stats"
fi

echo ""

################################################################################
# Storage Usage
################################################################################
print_header "💾 STORAGE USAGE"
echo ""

# Data directories
if [ -d "backend/data/uploads" ]; then
    UPLOADS_SIZE=$(du -sh backend/data/uploads 2>/dev/null | cut -f1)
    echo "Uploads:  $UPLOADS_SIZE"
fi

if [ -d "backend/data/outputs" ]; then
    OUTPUTS_SIZE=$(du -sh backend/data/outputs 2>/dev/null | cut -f1)
    echo "Outputs:  $OUTPUTS_SIZE"
fi

if [ -d "backend/model" ]; then
    MODELS_SIZE=$(du -sh backend/model 2>/dev/null | cut -f1)
    echo "Models:   $MODELS_SIZE"
fi

# Docker images size
if command -v docker &> /dev/null; then
    IMAGES_SIZE=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "image-reconstruction|nginx" | xargs docker images --format "{{.Size}}" | awk '{sum+=$1} END {printf "%.2f GB", sum}')
    if [ -n "$IMAGES_SIZE" ]; then
        echo "Images:   $IMAGES_SIZE"
    fi
fi

# Total data directory size
TOTAL_DATA_SIZE=$(du -sh backend/data 2>/dev/null | cut -f1)
echo ""
echo "Total data: $TOTAL_DATA_SIZE"

echo ""

################################################################################
# Network Ports
################################################################################
print_header "🌐 NETWORK"
echo ""

if [ "$FRONTEND_RUNNING" = true ]; then
    FRONTEND_PORT=$($COMPOSE port frontend 80 2>/dev/null | cut -d: -f2)
    if [ -n "$FRONTEND_PORT" ]; then
        echo "Frontend: http://localhost:$FRONTEND_PORT"
    fi

    FRONTEND_SSL_PORT=$($COMPOSE port frontend 443 2>/dev/null | cut -d: -f2)
    if [ -n "$FRONTEND_SSL_PORT" ]; then
        echo "HTTPS:    https://localhost:$FRONTEND_SSL_PORT"
    fi
fi

if [ "$BACKEND_RUNNING" = true ]; then
    BACKEND_PORT=$($COMPOSE port backend 8000 2>/dev/null | cut -d: -f2)
    if [ -n "$BACKEND_PORT" ]; then
        echo "Backend:  http://localhost:$BACKEND_PORT"
    fi
fi

echo ""

################################################################################
# Health Check
################################################################################
print_header "🏥 HEALTH CHECK"
echo ""

if [ "$BACKEND_RUNNING" = true ]; then
    HEALTH=$(curl -s http://localhost:8000/api/health 2>/dev/null)
    if [ $? -eq 0 ]; then
        STATUS=$(echo "$HEALTH" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        MODEL_LOADED=$(echo "$HEALTH" | grep -o '"model_loaded":[^,}]*' | cut -d: -f2)
        DEVICE=$(echo "$HEALTH" | grep -o '"device":"[^"]*"' | cut -d'"' -f4)

        if [ "$STATUS" = "ok" ]; then
            print_success "Backend health: OK"
        else
            print_warning "Backend health: $STATUS"
        fi

        echo "Model loaded: $MODEL_LOADED"
        echo "Device: $DEVICE"
    else
        print_error "Backend health check failed"
    fi
else
    print_warning "Backend not running"
fi

echo ""

################################################################################
# Recent Logs (last 5 lines)
################################################################################
print_header "📝 RECENT ACTIVITY (Last 5 lines)"
echo ""

if [ "$BACKEND_RUNNING" = true ]; then
    echo "Backend logs:"
    $COMPOSE logs --tail=5 backend 2>/dev/null | sed 's/^/  /'
    echo ""
fi

################################################################################
# Summary
################################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$BACKEND_RUNNING" = true ] && [ "$FRONTEND_RUNNING" = true ]; then
    print_success "Application is running normally"
else
    print_warning "Some services are not running"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_info "Useful commands:"
echo "  • View logs:     scripts/logs.sh"
echo "  • Restart:       scripts/restart.sh"
echo "  • Stop:          scripts/stop.sh"
echo "  • Refresh info:  scripts/info.sh"
echo ""
