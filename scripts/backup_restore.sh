#!/bin/bash

# Flow Backup and Restore Automation Script
# This script provides comprehensive backup and restore capabilities

set -e  # Exit on any error

# Configuration
BACKUP_BASE_DIR="${BACKUP_DIR:-./backups}"
S3_BUCKET="${S3_BACKUP_BUCKET:-}"
ENVIRONMENT="${ENVIRONMENT:-production}"
NAMESPACE="n8n"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

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
    
    # Check required tools
    local tools=("kubectl" "pg_dump" "pg_restore")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "$tool is not installed or not in PATH"
            exit 1
        fi
    done
    
    # Check kubectl access
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot access Kubernetes cluster"
        exit 1
    fi
    
    # Check if AWS CLI is available for S3 backups
    if [[ -n "$S3_BUCKET" ]] && ! command -v aws &> /dev/null; then
        error "AWS CLI required for S3 backups but not found"
        exit 1
    fi
    
    success "Prerequisites check passed"
}

# Create backup directory
create_backup_dir() {
    local backup_name=$1
    local backup_dir="$BACKUP_BASE_DIR/$backup_name"
    
    mkdir -p "$backup_dir"
    echo "$backup_dir"
}

# Database backup
backup_database() {
    local backup_dir=$1
    log "Backing up PostgreSQL database..."
    
    # Get database connection details from Kubernetes secrets
    local db_host=$(kubectl get service postgres-service -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
    local db_user="n8n"
    local db_name="n8n"
    
    # Create database backup using kubectl exec
    kubectl exec -n "$NAMESPACE" deployment/postgres -- pg_dump \
        -U "$db_user" \
        -d "$db_name" \
        --verbose \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges > "$backup_dir/database.sql"
    
    # Verify backup file
    if [[ -s "$backup_dir/database.sql" ]]; then
        success "Database backup completed: $(wc -l < "$backup_dir/database.sql") lines"
    else
        error "Database backup failed or is empty"
        return 1
    fi
}

# n8n workflows and data backup
backup_n8n_data() {
    local backup_dir=$1
    log "Backing up n8n workflows and data..."
    
    # Export workflows via n8n API
    local n8n_pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -n "$n8n_pod" ]]; then
        # Export workflows
        kubectl exec -n "$NAMESPACE" "$n8n_pod" -- sh -c "
            if command -v n8n &> /dev/null; then
                n8n export:workflow --all --output=/tmp/workflows.json 2>/dev/null || echo '[]' > /tmp/workflows.json
                cat /tmp/workflows.json
            else
                echo '[]'
            fi
        " > "$backup_dir/workflows.json"
        
        # Export credentials (names only, not actual credentials)
        kubectl exec -n "$NAMESPACE" "$n8n_pod" -- sh -c "
            if command -v n8n &> /dev/null; then
                n8n export:credentials --all --output=/tmp/credentials.json 2>/dev/null || echo '[]' > /tmp/credentials.json
                cat /tmp/credentials.json
            else
                echo '[]'
            fi
        " > "$backup_dir/credentials.json"
        
        # Copy n8n data directory
        kubectl cp "$NAMESPACE/$n8n_pod:/home/node/.n8n" "$backup_dir/n8n-data" 2>/dev/null || {
            warning "Could not copy n8n data directory"
        }
        
        success "n8n data backup completed"
    else
        warning "No n8n pod found, skipping n8n data backup"
    fi
}

# Kubernetes configuration backup
backup_k8s_config() {
    local backup_dir=$1
    log "Backing up Kubernetes configurations..."
    
    # Export all resources in the namespace
    kubectl get all,secrets,configmaps,pvc,ingress -n "$NAMESPACE" -o yaml > "$backup_dir/k8s-resources.yaml"
    
    # Export monitoring resources
    kubectl get all,secrets,configmaps,pvc -n monitoring -o yaml > "$backup_dir/k8s-monitoring.yaml" 2>/dev/null || {
        warning "Could not backup monitoring namespace"
    }
    
    success "Kubernetes configuration backup completed"
}

# Redis backup
backup_redis() {
    local backup_dir=$1
    log "Backing up Redis data..."
    
    # Create Redis backup
    local redis_pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -n "$redis_pod" ]]; then
        # Trigger Redis save
        kubectl exec -n "$NAMESPACE" "$redis_pod" -- redis-cli BGSAVE
        sleep 5  # Wait for background save to complete
        
        # Copy dump file
        kubectl cp "$NAMESPACE/$redis_pod:/data/dump.rdb" "$backup_dir/redis-dump.rdb" 2>/dev/null || {
            warning "Could not copy Redis dump file"
        }
        
        success "Redis backup completed"
    else
        warning "No Redis pod found, skipping Redis backup"
    fi
}

# Create metadata file
create_metadata() {
    local backup_dir=$1
    log "Creating backup metadata..."
    
    cat > "$backup_dir/metadata.json" <<EOF
{
    "backup_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "environment": "$ENVIRONMENT",
    "kubernetes_namespace": "$NAMESPACE",
    "backup_version": "1.0",
    "kubernetes_version": "$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')",
    "cluster_info": {
        "server": "$(kubectl cluster-info | head -1 | sed 's/.*https:\/\///' | sed 's/\x1b\[[0-9;]*m//g')"
    },
    "backup_components": [
        "postgresql_database",
        "n8n_workflows",
        "n8n_data",
        "kubernetes_configs",
        "redis_data"
    ]
}
EOF
    
    success "Metadata created"
}

# Compress backup
compress_backup() {
    local backup_dir=$1
    log "Compressing backup..."
    
    local backup_name=$(basename "$backup_dir")
    local compressed_file="$backup_dir.tar.gz"
    
    tar -czf "$compressed_file" -C "$(dirname "$backup_dir")" "$backup_name"
    
    if [[ -f "$compressed_file" ]]; then
        local size=$(du -h "$compressed_file" | cut -f1)
        success "Backup compressed: $compressed_file ($size)"
        
        # Remove uncompressed directory
        rm -rf "$backup_dir"
        
        echo "$compressed_file"
    else
        error "Backup compression failed"
        return 1
    fi
}

# Upload to S3
upload_to_s3() {
    local backup_file=$1
    
    if [[ -z "$S3_BUCKET" ]]; then
        log "S3_BUCKET not configured, skipping S3 upload"
        return 0
    fi
    
    log "Uploading backup to S3..."
    
    local s3_key="flow-backups/$ENVIRONMENT/$(basename "$backup_file")"
    
    aws s3 cp "$backup_file" "s3://$S3_BUCKET/$s3_key" \
        --storage-class STANDARD_IA \
        --metadata "environment=$ENVIRONMENT,backup-date=$(date +%Y-%m-%d)"
    
    if [[ $? -eq 0 ]]; then
        success "Backup uploaded to S3: s3://$S3_BUCKET/$s3_key"
    else
        error "S3 upload failed"
        return 1
    fi
}

# Full backup operation
perform_backup() {
    local backup_name="flow-backup-$ENVIRONMENT-$(date +%Y%m%d-%H%M%S)"
    local backup_dir
    
    log "Starting full backup: $backup_name"
    
    backup_dir=$(create_backup_dir "$backup_name")
    
    # Perform individual backups
    backup_database "$backup_dir"
    backup_n8n_data "$backup_dir"
    backup_k8s_config "$backup_dir"
    backup_redis "$backup_dir"
    create_metadata "$backup_dir"
    
    # Compress and upload
    local compressed_file
    compressed_file=$(compress_backup "$backup_dir")
    
    if [[ -n "$S3_BUCKET" ]]; then
        upload_to_s3 "$compressed_file"
    fi
    
    success "Full backup completed: $compressed_file"
    echo "$compressed_file"
}

# List available backups
list_backups() {
    log "Available local backups:"
    
    if [[ -d "$BACKUP_BASE_DIR" ]]; then
        find "$BACKUP_BASE_DIR" -name "*.tar.gz" -type f | sort -r | while read -r backup; do
            local size=$(du -h "$backup" | cut -f1)
            local date=$(stat -c %y "$backup" | cut -d' ' -f1)
            echo "  $(basename "$backup") ($size, $date)"
        done
    else
        log "No local backups found"
    fi
    
    if [[ -n "$S3_BUCKET" ]]; then
        log "Available S3 backups:"
        aws s3 ls "s3://$S3_BUCKET/flow-backups/$ENVIRONMENT/" --recursive | awk '{print "  " $4 " (" $3 ", " $1 " " $2 ")"}'
    fi
}

# Restore database
restore_database() {
    local backup_dir=$1
    log "Restoring PostgreSQL database..."
    
    if [[ ! -f "$backup_dir/database.sql" ]]; then
        error "Database backup file not found: $backup_dir/database.sql"
        return 1
    fi
    
    # Stop n8n to prevent writes during restore
    kubectl scale deployment n8n --replicas=0 -n "$NAMESPACE"
    sleep 10
    
    # Restore database
    kubectl exec -i -n "$NAMESPACE" deployment/postgres -- psql -U n8n -d n8n < "$backup_dir/database.sql"
    
    # Restart n8n
    kubectl scale deployment n8n --replicas=2 -n "$NAMESPACE"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=n8n -n "$NAMESPACE" --timeout=300s
    
    success "Database restored"
}

# Restore n8n data
restore_n8n_data() {
    local backup_dir=$1
    log "Restoring n8n data..."
    
    local n8n_pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -n "$n8n_pod" ]]; then
        # Restore workflows
        if [[ -f "$backup_dir/workflows.json" ]]; then
            kubectl cp "$backup_dir/workflows.json" "$NAMESPACE/$n8n_pod:/tmp/workflows.json"
            kubectl exec -n "$NAMESPACE" "$n8n_pod" -- sh -c "
                if command -v n8n &> /dev/null; then
                    n8n import:workflow --input=/tmp/workflows.json
                fi
            "
        fi
        
        # Restore n8n data directory
        if [[ -d "$backup_dir/n8n-data" ]]; then
            kubectl cp "$backup_dir/n8n-data" "$NAMESPACE/$n8n_pod:/home/node/.n8n"
        fi
        
        success "n8n data restored"
    else
        warning "No n8n pod found, skipping n8n data restore"
    fi
}

# Restore from backup
perform_restore() {
    local backup_file=$1
    
    if [[ -z "$backup_file" ]]; then
        error "Backup file not specified"
        return 1
    fi
    
    # Download from S3 if it's an S3 URL
    if [[ "$backup_file" =~ ^s3:// ]]; then
        log "Downloading backup from S3..."
        local local_file="/tmp/$(basename "$backup_file")"
        aws s3 cp "$backup_file" "$local_file"
        backup_file="$local_file"
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
        return 1
    fi
    
    log "Starting restore from: $backup_file"
    
    # Extract backup
    local restore_dir="/tmp/restore-$(date +%s)"
    mkdir -p "$restore_dir"
    tar -xzf "$backup_file" -C "$restore_dir"
    
    local backup_name=$(tar -tzf "$backup_file" | head -1 | cut -f1 -d'/')
    local backup_dir="$restore_dir/$backup_name"
    
    if [[ ! -d "$backup_dir" ]]; then
        error "Invalid backup structure"
        return 1
    fi
    
    # Verify backup metadata
    if [[ -f "$backup_dir/metadata.json" ]]; then
        local backup_env=$(jq -r '.environment' "$backup_dir/metadata.json")
        local backup_date=$(jq -r '.backup_timestamp' "$backup_dir/metadata.json")
        log "Backup environment: $backup_env"
        log "Backup date: $backup_date"
        
        if [[ "$backup_env" != "$ENVIRONMENT" ]]; then
            warning "Backup environment ($backup_env) differs from current environment ($ENVIRONMENT)"
            read -p "Continue? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Restore cancelled"
                return 1
            fi
        fi
    fi
    
    # Perform restore operations
    restore_database "$backup_dir"
    restore_n8n_data "$backup_dir"
    
    # Cleanup
    rm -rf "$restore_dir"
    
    success "Restore completed from: $backup_file"
}

# Cleanup old backups
cleanup_old_backups() {
    log "Cleaning up old backups (older than $RETENTION_DAYS days)..."
    
    # Cleanup local backups
    if [[ -d "$BACKUP_BASE_DIR" ]]; then
        find "$BACKUP_BASE_DIR" -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
        local removed=$(find "$BACKUP_BASE_DIR" -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS | wc -l)
        log "Removed $removed old local backups"
    fi
    
    # Cleanup S3 backups
    if [[ -n "$S3_BUCKET" ]]; then
        aws s3api list-objects-v2 \
            --bucket "$S3_BUCKET" \
            --prefix "flow-backups/$ENVIRONMENT/" \
            --query "Contents[?LastModified<='$(date -d "$RETENTION_DAYS days ago" --iso-8601)'].Key" \
            --output text | while read -r key; do
                if [[ -n "$key" ]]; then
                    aws s3 rm "s3://$S3_BUCKET/$key"
                    log "Removed S3 backup: $key"
                fi
            done
    fi
    
    success "Cleanup completed"
}

# Print usage
usage() {
    echo "Flow Backup and Restore Automation"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  backup                Create a full backup"
    echo "  restore <file>        Restore from backup file or S3 URL"
    echo "  list                  List available backups"
    echo "  cleanup               Remove old backups"
    echo "  help                  Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  BACKUP_DIR            Local backup directory (default: ./backups)"
    echo "  S3_BACKUP_BUCKET      S3 bucket for remote backups"
    echo "  ENVIRONMENT           Environment name (default: production)"
    echo "  BACKUP_RETENTION_DAYS Backup retention period (default: 30)"
    echo ""
    echo "Examples:"
    echo "  $0 backup                                    # Create full backup"
    echo "  $0 restore backup-20240101.tar.gz           # Restore from local file"
    echo "  $0 restore s3://bucket/path/backup.tar.gz   # Restore from S3"
    echo "  $0 list                                      # List all backups"
    echo "  $0 cleanup                                   # Remove old backups"
}

# Main function
main() {
    local command=${1:-backup}
    
    case "$command" in
        backup)
            check_prerequisites
            perform_backup
            ;;
        restore)
            check_prerequisites
            perform_restore "$2"
            ;;
        list)
            list_backups
            ;;
        cleanup)
            check_prerequisites
            cleanup_old_backups
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