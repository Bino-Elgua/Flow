#!/bin/bash

# Flow Local Development Environment Launcher
# This script sets up and launches the Flow platform for local development

set -e  # Exit on any error

# Configuration
COMPOSE_FILE="docker/docker-compose.yml"
ENV_FILE="docker/.env"
PROJECT_NAME="flow"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed. Please install Docker Desktop."
        exit 1
    fi
    
    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose is not installed. Please install Docker Compose."
        exit 1
    fi
    
    # Check if Docker is running
    if ! docker info &> /dev/null; then
        error "Docker is not running. Please start Docker Desktop."
        exit 1
    fi
    
    success "Prerequisites check passed"
}

# Setup environment file
setup_environment() {
    log "Setting up environment configuration..."
    
    if [[ ! -f "$ENV_FILE" ]]; then
        log "Creating environment file from template..."
        cp config/.env.example "$ENV_FILE"
        
        # Generate random passwords for local development
        POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        N8N_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        
        # Update environment file with local settings
        sed -i.bak \
            -e "s/🔑SECURE_DB_PASSWORD🔑/$POSTGRES_PASSWORD/g" \
            -e "s/🔑ADMIN_PASSWORD🔑/$N8N_PASSWORD/g" \
            -e "s/🔑ADMIN_USERNAME🔑/admin/g" \
            -e "s/https:/http:/g" \
            -e "s/n8n.example.com/localhost:5678/g" \
            "$ENV_FILE"
        
        # Remove backup file
        rm "${ENV_FILE}.bak"
        
        success "Environment file created with local configuration"
        log "n8n Admin Credentials:"
        log "  Username: admin"
        log "  Password: $N8N_PASSWORD"
        log "  (These credentials are also saved in $ENV_FILE)"
    else
        log "Environment file already exists"
    fi
}

# Create necessary directories
create_directories() {
    log "Creating necessary directories..."
    
    # Create volume directories with proper permissions
    mkdir -p volumes/postgres-data
    mkdir -p volumes/redis-data
    mkdir -p volumes/n8n-data
    mkdir -p volumes/nginx-logs
    
    # Set permissions for containers
    chmod 755 volumes/postgres-data
    chmod 755 volumes/redis-data
    chmod 755 volumes/n8n-data
    chmod 755 volumes/nginx-logs
    
    success "Directories created"
}

# Pull latest images
pull_images() {
    log "Pulling latest Docker images..."
    
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" pull
    
    success "Images pulled"
}

# Start services
start_services() {
    log "Starting Flow services..."
    
    # Start all services in detached mode
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d
    
    success "Services started"
}

# Wait for services to be healthy
wait_for_services() {
    log "Waiting for services to be healthy..."
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" ps | grep -q "healthy"; then
            break
        fi
        
        attempt=$((attempt + 1))
        log "Attempt $attempt/$max_attempts - Waiting for services..."
        sleep 10
    done
    
    if [[ $attempt -eq $max_attempts ]]; then
        warning "Services may not be fully healthy yet. Check logs with: $0 logs"
    else
        success "Services are healthy"
    fi
}

# Check service status
check_status() {
    log "Checking service status..."
    
    echo ""
    echo "=== Service Status ==="
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" ps
    
    echo ""
    echo "=== Service Health ==="
    
    # Check n8n
    if curl -f http://localhost:5678/healthz &> /dev/null; then
        success "n8n is healthy (http://localhost:5678)"
    else
        warning "n8n is not responding"
    fi
    
    # Check if ports are accessible
    if nc -z localhost 5678 2>/dev/null; then
        success "n8n port (5678) is accessible"
    else
        warning "n8n port (5678) is not accessible"
    fi
    
    if nc -z localhost 5432 2>/dev/null; then
        success "PostgreSQL port (5432) is accessible"
    else
        warning "PostgreSQL port (5432) is not accessible"
    fi
    
    if nc -z localhost 6379 2>/dev/null; then
        success "Redis port (6379) is accessible"
    else
        warning "Redis port (6379) is not accessible"
    fi
}

# Show logs
show_logs() {
    local service=$1
    
    if [[ -n "$service" ]]; then
        log "Showing logs for $service..."
        docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" logs -f "$service"
    else
        log "Showing logs for all services..."
        docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" logs -f
    fi
}

# Stop services
stop_services() {
    log "Stopping Flow services..."
    
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
    
    success "Services stopped"
}

# Restart services
restart_services() {
    log "Restarting Flow services..."
    
    stop_services
    start_services
    wait_for_services
    
    success "Services restarted"
}

# Clean up everything
cleanup() {
    log "Cleaning up Flow environment..."
    
    # Stop and remove containers, networks, volumes
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down -v --remove-orphans
    
    # Remove generated directories
    rm -rf volumes/
    
    # Remove environment file
    rm -f "$ENV_FILE"
    
    success "Environment cleaned up"
}

# Update services
update_services() {
    log "Updating Flow services..."
    
    # Pull latest images
    pull_images
    
    # Recreate containers with new images
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d --force-recreate
    
    # Wait for services
    wait_for_services
    
    success "Services updated"
}

# Execute command in service container
exec_command() {
    local service=$1
    shift
    local command="$*"
    
    if [[ -z "$service" ]]; then
        error "Service name required"
        exit 1
    fi
    
    log "Executing command in $service: $command"
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec "$service" $command
}

# Import workflow
import_workflow() {
    local workflow_file=$1
    
    if [[ -z "$workflow_file" ]]; then
        error "Workflow file required"
        exit 1
    fi
    
    if [[ ! -f "$workflow_file" ]]; then
        error "Workflow file not found: $workflow_file"
        exit 1
    fi
    
    log "Importing workflow from $workflow_file..."
    
    # Copy workflow file to n8n container and import
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec -T n8n sh -c "
        cat > /tmp/workflow.json && 
        n8n import:workflow --input=/tmp/workflow.json
    " < "$workflow_file"
    
    success "Workflow imported"
}

# Backup data
backup_data() {
    local backup_dir="backups/$(date +%Y%m%d_%H%M%S)"
    
    log "Creating backup in $backup_dir..."
    
    mkdir -p "$backup_dir"
    
    # Backup database
    docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec -T postgres pg_dump -U n8n n8n > "$backup_dir/database.sql"
    
    # Backup n8n data
    docker cp "${PROJECT_NAME}_n8n_1:/home/node/.n8n" "$backup_dir/n8n-data" 2>/dev/null || true
    
    # Backup configurations
    cp -r config/ "$backup_dir/"
    cp "$ENV_FILE" "$backup_dir/" 2>/dev/null || true
    
    success "Backup created in $backup_dir"
}

# Restore data
restore_data() {
    local backup_dir=$1
    
    if [[ -z "$backup_dir" ]]; then
        error "Backup directory required"
        exit 1
    fi
    
    if [[ ! -d "$backup_dir" ]]; then
        error "Backup directory not found: $backup_dir"
        exit 1
    fi
    
    log "Restoring from backup $backup_dir..."
    
    # Stop services
    stop_services
    
    # Restore database
    if [[ -f "$backup_dir/database.sql" ]]; then
        start_services
        sleep 30  # Wait for database to be ready
        docker-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec -T postgres psql -U n8n -d n8n < "$backup_dir/database.sql"
        stop_services
    fi
    
    # Restore n8n data
    if [[ -d "$backup_dir/n8n-data" ]]; then
        rm -rf volumes/n8n-data/*
        cp -r "$backup_dir/n8n-data/"* volumes/n8n-data/ 2>/dev/null || true
    fi
    
    # Restore environment
    if [[ -f "$backup_dir/.env" ]]; then
        cp "$backup_dir/.env" "$ENV_FILE"
    fi
    
    # Start services
    start_services
    wait_for_services
    
    success "Data restored from $backup_dir"
}

# Print usage
usage() {
    echo "Flow Local Development Environment Launcher"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  start                 Start the development environment"
    echo "  stop                  Stop all services"
    echo "  restart               Restart all services"
    echo "  status                Show service status"
    echo "  logs [service]        Show logs (all services or specific service)"
    echo "  update                Update services to latest versions"
    echo "  cleanup               Remove all containers, networks, and volumes"
    echo "  exec <service> <cmd>  Execute command in service container"
    echo "  import <file>         Import workflow from JSON file"
    echo "  backup                Create backup of data and configurations"
    echo "  restore <dir>         Restore from backup directory"
    echo "  help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 start              # Start development environment"
    echo "  $0 logs n8n           # Show n8n logs"
    echo "  $0 exec postgres psql -U n8n -d n8n  # Connect to database"
    echo "  $0 import workflows/verifi.json       # Import workflow"
    echo ""
    echo "Access Points:"
    echo "  n8n Interface:        http://localhost:5678"
    echo "  PostgreSQL:           localhost:5432"
    echo "  Redis:                localhost:6379"
}

# Main function
main() {
    local command=${1:-start}
    
    case "$command" in
        start)
            check_prerequisites
            setup_environment
            create_directories
            pull_images
            start_services
            wait_for_services
            check_status
            echo ""
            success "Flow development environment is ready!"
            log "Access n8n at: http://localhost:5678"
            log "Check status with: $0 status"
            log "View logs with: $0 logs"
            ;;
        stop)
            stop_services
            ;;
        restart)
            restart_services
            check_status
            ;;
        status)
            check_status
            ;;
        logs)
            show_logs "$2"
            ;;
        update)
            update_services
            check_status
            ;;
        cleanup)
            cleanup
            ;;
        exec)
            shift
            exec_command "$@"
            ;;
        import)
            import_workflow "$2"
            ;;
        backup)
            backup_data
            ;;
        restore)
            restore_data "$2"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"