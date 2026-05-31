#!/bin/bash

################################################################################
# Automated VPS Deployment Script for Image Reconstruction App
# Usage: ./deploy-to-vps.sh [your-domain.com] [your-email@example.com]
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run as root. Use a regular user with sudo privileges."
    exit 1
fi

# Parse arguments
DOMAIN=${1:-}
EMAIL=${2:-}

if [ -z "$DOMAIN" ]; then
    print_error "Usage: ./deploy-to-vps.sh [your-domain.com] [your-email@example.com]"
    echo ""
    echo "Example: ./deploy-to-vps.sh example.com admin@example.com"
    exit 1
fi

if [ -z "$EMAIL" ]; then
    print_error "Email is required for SSL certificate"
    print_error "Usage: ./deploy-to-vps.sh [your-domain.com] [your-email@example.com]"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Image Reconstruction App - Automated VPS Deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_info "Domain: $DOMAIN"
print_info "Email: $EMAIL"
echo ""

################################################################################
# Check if application is already running
################################################################################
print_info "Checking if application is already running..."

if command -v docker-compose &> /dev/null && [ -f "docker-compose.yml" ]; then
    if docker-compose ps 2>/dev/null | grep -q "Up"; then
        print_error "Application is already running!"
        echo ""
        print_info "Current status:"
        docker-compose ps
        echo ""
        print_warning "Please stop the application first using: scripts/stop.sh"
        print_warning "Or use restart script to update: scripts/restart.sh"
        exit 1
    fi
fi

print_success "No running application detected, proceeding with deployment..."
echo ""

################################################################################
# Step 1: Update system
################################################################################
print_info "[1/11] Updating system packages..."
sudo apt update -qq && sudo apt upgrade -y -qq
print_success "System updated"
echo ""

################################################################################
# Step 2: Install Docker
################################################################################
print_info "[2/11] Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh > /dev/null
    sudo usermod -aG docker $USER
    rm get-docker.sh
    print_success "Docker installed"
else
    print_success "Docker already installed ($(docker --version))"
fi
echo ""

################################################################################
# Step 3: Install Docker Compose
################################################################################
print_info "[3/11] Installing Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    sudo curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose installed"
else
    print_success "Docker Compose already installed ($(docker-compose --version))"
fi
echo ""

################################################################################
# Step 4: Create data directories
################################################################################
print_info "[4/11] Creating data directories..."
mkdir -p backend/data/uploads
mkdir -p backend/data/outputs
chmod 755 backend/data/uploads backend/data/outputs
print_success "Data directories created"
echo ""

################################################################################
# Step 5: Check model files
################################################################################
print_info "[5/11] Checking model files..."
MODEL_FOUND=false
if [ -f "backend/model/REAL-ESRGAN.pth" ] && [ -f "backend/model/ConvNext_REAL-ESRGAN.pth" ]; then
    MODEL_FOUND=true
    print_success "Model files found"
else
    print_warning "Model files not found!"
    print_warning "Please upload these files to backend/model/:"
    echo "  - REAL-ESRGAN.pth"
    echo "  - ConvNext_REAL-ESRGAN.pth"
    echo ""
    read -p "Continue without model files? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Deployment cancelled. Please upload model files first."
        exit 1
    fi
fi
echo ""

################################################################################
# Step 6: Configure firewall
################################################################################
print_info "[6/11] Configuring firewall..."
sudo ufw --force enable > /dev/null 2>&1
sudo ufw allow 22/tcp > /dev/null 2>&1
sudo ufw allow 80/tcp > /dev/null 2>&1
sudo ufw allow 443/tcp > /dev/null 2>&1
print_success "Firewall configured (ports 22, 80, 443 open)"
echo ""

################################################################################
# Step 7: Update config.json
################################################################################
print_info "[7/11] Updating config.json..."
if [ -f "config.json" ]; then
    # Backup original config
    cp config.json config.json.backup

    # Update backend_url using sed (cross-platform compatible)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s|\"backend_url\": \".*\"|\"backend_url\": \"https://$DOMAIN\"|g" config.json
    else
        # Linux
        sed -i "s|\"backend_url\": \".*\"|\"backend_url\": \"https://$DOMAIN\"|g" config.json
    fi
    print_success "config.json updated (backup: config.json.backup)"
else
    print_error "config.json not found"
    exit 1
fi
echo ""

################################################################################
# Step 8: Install Certbot and generate SSL certificate
################################################################################
print_info "[8/11] Setting up SSL certificate..."

# Stop any running containers to free up port 80
docker-compose down 2>/dev/null || true

# Install Certbot
if ! command -v certbot &> /dev/null; then
    print_info "Installing Certbot..."
    sudo apt install certbot -y -qq
fi

# Generate certificate
print_info "Generating SSL certificate (this may take a minute)..."
sudo certbot certonly --standalone \
    -d "$DOMAIN" \
    -d "www.$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring \
    2>&1 | grep -v "Saving debug log"

if [ $? -eq 0 ]; then
    print_success "SSL certificate generated successfully"
else
    print_error "Failed to generate SSL certificate"
    print_warning "Make sure your domain DNS is pointing to this server"
    exit 1
fi
echo ""

################################################################################
# Step 9: Configure Nginx with SSL
################################################################################
print_info "[9/11] Configuring Nginx with SSL for $DOMAIN..."

# Use the committed docker/nginx.conf as the source of truth and only template
# the domain into it in place. We intentionally do NOT overwrite the whole file,
# so any committed hardening (security headers, rate limiting, etc.) is preserved
# across deploys instead of being discarded.
if [ ! -f "docker/nginx.conf" ]; then
    print_error "docker/nginx.conf not found in repository"
    exit 1
fi

if [ "$DOMAIN" != "pixup.id" ]; then
    sed -i "s/pixup\.id/$DOMAIN/g" docker/nginx.conf
fi

print_success "Nginx configuration templated for $DOMAIN"
echo ""

################################################################################
# Step 10: Update docker-compose.yml and start services
################################################################################
print_info "[10/11] Building and starting Docker services..."

# Use the committed docker-compose.yml as-is rather than regenerating it, so
# fixes committed to the repo (e.g. the healthcheck) are not silently reverted.
if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml not found in repository"
    exit 1
fi

# Build and start services
print_info "Cleaning Docker cache..."
docker builder prune -f > /dev/null 2>&1

print_info "Building Docker images (this may take several minutes)..."
docker-compose build --no-cache --quiet

print_info "Starting services..."
docker-compose up -d

print_success "Services started"
echo ""

################################################################################
# Step 11: Setup SSL auto-renewal
################################################################################
print_info "[11/11] Setting up SSL auto-renewal..."

# Get the current working directory
CURRENT_DIR=$(pwd)

# Create renewal hook script
sudo mkdir -p /etc/letsencrypt/renewal-hooks/post
sudo tee /etc/letsencrypt/renewal-hooks/post/restart-nginx.sh > /dev/null << EOF
#!/bin/bash
cd $CURRENT_DIR
docker-compose restart frontend
EOF

sudo chmod +x /etc/letsencrypt/renewal-hooks/post/restart-nginx.sh

print_success "SSL auto-renewal configured"
echo ""

################################################################################
# Final checks
################################################################################
print_info "Running final checks..."
sleep 10

# Check if containers are running
if docker-compose ps | grep -q "Up"; then
    print_success "Containers are running"
else
    print_error "Some containers failed to start"
    print_info "Check logs with: docker-compose logs"
    exit 1
fi

# Check backend health
print_info "Checking backend health..."
MAX_RETRIES=6
RETRY=0
while [ $RETRY -lt $MAX_RETRIES ]; do
    if curl -f http://localhost:8000/api/health > /dev/null 2>&1; then
        print_success "Backend is healthy"
        break
    else
        RETRY=$((RETRY+1))
        if [ $RETRY -lt $MAX_RETRIES ]; then
            print_info "Waiting for backend to start... ($RETRY/$MAX_RETRIES)"
            sleep 5
        else
            print_warning "Backend health check timed out"
            print_info "Check logs with: docker-compose logs backend"
        fi
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Your application is now live at:"
echo ""
echo -e "  🌐 Frontend:    \033]8;;https://$DOMAIN\033\\https://$DOMAIN\033]8;;\033\\"
echo -e "  🔧 Backend API: \033]8;;https://$DOMAIN/api/\033\\https://$DOMAIN/api/\033]8;;\033\\"
echo -e "  📚 API Docs:    \033]8;;https://$DOMAIN/docs\033\\https://$DOMAIN/docs\033]8;;\033\\"
echo -e "  ❤️  Health:      \033]8;;https://$DOMAIN/api/health\033\\https://$DOMAIN/api/health\033]8;;\033\\"
echo ""
echo -e "${GREEN}(Click links above to open in browser)${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Useful Commands:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  View logs:          docker-compose logs -f"
echo "  Restart services:   docker-compose restart"
echo "  Stop services:      docker-compose down"
echo "  Update app:         git pull && docker-compose up -d --build"
echo "  Check status:       docker-compose ps"
echo "  Test SSL renewal:   sudo certbot renew --dry-run"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "SSL certificate will auto-renew automatically"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$MODEL_FOUND" = false ]; then
    print_warning "REMINDER: Model files were not found during deployment"
    print_warning "Upload them to backend/model/ and restart: docker-compose restart backend"
    echo ""
fi
