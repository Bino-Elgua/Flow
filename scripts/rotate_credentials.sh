#!/bin/bash

# Flow Credential Rotation Automation Script
# This script automates the rotation of credentials and secrets

set -e  # Exit on any error

# Configuration
ENVIRONMENT="${ENVIRONMENT:-production}"
NAMESPACE="n8n"
MONITORING_NAMESPACE="monitoring"
ROTATION_LOG="/var/log/credential-rotation.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${BLUE}${message}${NC}"
    echo "$message" >> "$ROTATION_LOG"
}

error() {
    local message="[ERROR] $1"
    echo -e "${RED}${message}${NC}" >&2
    echo "$message" >> "$ROTATION_LOG"
}

warning() {
    local message="[WARNING] $1"
    echo -e "${YELLOW}${message}${NC}"
    echo "$message" >> "$ROTATION_LOG"
}

success() {
    local message="[SUCCESS] $1"
    echo -e "${GREEN}${message}${NC}"
    echo "$message" >> "$ROTATION_LOG"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check required tools
    local tools=("kubectl" "openssl" "base64" "jq")
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
    
    # Check if AWS CLI is available for AWS secrets
    if ! command -v aws &> /dev/null; then
        warning "AWS CLI not found, AWS secrets rotation will be skipped"
    fi
    
    success "Prerequisites check passed"
}

# Generate secure password
generate_password() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-$length
}

# Generate API key
generate_api_key() {
    local prefix=${1:-"sk"}
    echo "${prefix}_$(openssl rand -hex 32)"
}

# Backup current secrets before rotation
backup_secrets() {
    log "Backing up current secrets..."
    
    local backup_dir="secret-backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Backup n8n secrets
    kubectl get secret n8n-secrets -n "$NAMESPACE" -o yaml > "$backup_dir/n8n-secrets.yaml"
    kubectl get secret postgres-secrets -n "$NAMESPACE" -o yaml > "$backup_dir/postgres-secrets.yaml"
    
    # Backup monitoring secrets
    kubectl get secret grafana-secrets -n "$MONITORING_NAMESPACE" -o yaml > "$backup_dir/grafana-secrets.yaml" 2>/dev/null || true
    
    success "Secrets backed up to $backup_dir"
    echo "$backup_dir"
}

# Rotate PostgreSQL password
rotate_postgres_password() {
    log "Rotating PostgreSQL password..."
    
    local new_password=$(generate_password 32)
    
    # Update secret
    kubectl patch secret postgres-secrets -n "$NAMESPACE" -p="{\"data\":{\"POSTGRES_PASSWORD\":\"$(echo -n "$new_password" | base64 -w 0)\"}}"
    
    # Update n8n secret with new database password
    kubectl patch secret n8n-secrets -n "$NAMESPACE" -p="{\"data\":{\"DB_POSTGRESDB_PASSWORD\":\"$(echo -n "$new_password" | base64 -w 0)\"}}"
    
    # Restart PostgreSQL to apply new password
    kubectl rollout restart statefulset/postgres -n "$NAMESPACE"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgres -n "$NAMESPACE" --timeout=300s
    
    # Restart n8n to use new password
    kubectl rollout restart deployment/n8n -n "$NAMESPACE"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=n8n -n "$NAMESPACE" --timeout=300s
    
    success "PostgreSQL password rotated"
}

# Rotate n8n admin credentials
rotate_n8n_admin() {
    log "Rotating n8n admin credentials..."
    
    local new_password=$(generate_password 16)
    
    # Update n8n admin password
    kubectl patch secret n8n-secrets -n "$NAMESPACE" -p="{\"data\":{\"N8N_BASIC_AUTH_PASSWORD\":\"$(echo -n "$new_password" | base64 -w 0)\"}}"
    
    # Restart n8n to apply new credentials
    kubectl rollout restart deployment/n8n -n "$NAMESPACE"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=n8n -n "$NAMESPACE" --timeout=300s
    
    success "n8n admin password rotated"
    log "New n8n admin password: $new_password"
}

# Rotate Grafana admin password
rotate_grafana_admin() {
    log "Rotating Grafana admin password..."
    
    local new_password=$(generate_password 16)
    
    # Update Grafana admin password
    kubectl patch secret grafana-secrets -n "$MONITORING_NAMESPACE" -p="{\"data\":{\"admin-password\":\"$(echo -n "$new_password" | base64 -w 0)\"}}"
    
    # Restart Grafana to apply new password
    kubectl rollout restart deployment/grafana -n "$MONITORING_NAMESPACE"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n "$MONITORING_NAMESPACE" --timeout=300s
    
    success "Grafana admin password rotated"
    log "New Grafana admin password: $new_password"
}

# Rotate SSL certificates
rotate_ssl_certificates() {
    log "Rotating SSL certificates..."
    
    # Check if cert-manager is available
    if ! kubectl get clusterissuer letsencrypt-prod &> /dev/null; then
        warning "cert-manager not found, skipping SSL certificate rotation"
        return 0
    fi
    
    # Get all certificates in the namespace
    local certificates=$(kubectl get certificates -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')
    
    for cert in $certificates; do
        log "Rotating certificate: $cert"
        
        # Delete the certificate to trigger renewal
        kubectl delete certificate "$cert" -n "$NAMESPACE"
        
        # Reapply the certificate from ingress
        kubectl apply -f k8s/ingress-nginx.yaml
        
        # Wait for certificate to be ready
        kubectl wait --for=condition=ready certificate "$cert" -n "$NAMESPACE" --timeout=600s
        
        success "Certificate $cert rotated"
    done
}

# Rotate AWS IAM access keys
rotate_aws_keys() {
    if ! command -v aws &> /dev/null; then
        warning "AWS CLI not available, skipping AWS key rotation"
        return 0
    fi
    
    log "Rotating AWS IAM access keys..."
    
    # Get current user
    local current_user=$(aws sts get-caller-identity --query 'Arn' --output text | cut -d'/' -f2)
    
    if [[ -z "$current_user" ]]; then
        warning "Cannot determine current AWS user, skipping AWS key rotation"
        return 0
    fi
    
    log "Current AWS user: $current_user"
    
    # Create new access key
    local new_key_output=$(aws iam create-access-key --user-name "$current_user")
    local new_access_key=$(echo "$new_key_output" | jq -r '.AccessKey.AccessKeyId')
    local new_secret_key=$(echo "$new_key_output" | jq -r '.AccessKey.SecretAccessKey')
    
    if [[ -n "$new_access_key" && -n "$new_secret_key" ]]; then
        log "New AWS access key created: $new_access_key"
        
        # Update Kubernetes secret if it exists
        if kubectl get secret aws-credentials -n "$NAMESPACE" &> /dev/null; then
            kubectl patch secret aws-credentials -n "$NAMESPACE" -p="{\"data\":{\"AWS_ACCESS_KEY_ID\":\"$(echo -n "$new_access_key" | base64 -w 0)\",\"AWS_SECRET_ACCESS_KEY\":\"$(echo -n "$new_secret_key" | base64 -w 0)\"}}"
            success "AWS credentials updated in Kubernetes"
        fi
        
        # Wait before deleting old key (to ensure new key is active)
        log "Waiting 60 seconds before deleting old access key..."
        sleep 60
        
        # Get and delete old access keys
        local old_keys=$(aws iam list-access-keys --user-name "$current_user" --query 'AccessKeyMetadata[?AccessKeyId!=`'$new_access_key'`].AccessKeyId' --output text)
        
        for old_key in $old_keys; do
            aws iam delete-access-key --user-name "$current_user" --access-key-id "$old_key"
            log "Deleted old access key: $old_key"
        done
        
        success "AWS IAM access keys rotated"
    else
        error "Failed to create new AWS access key"
    fi
}

# Update webhook URLs with new credentials
update_webhook_urls() {
    log "Updating webhook URLs with new authentication..."
    
    # This would typically involve updating external systems that call n8n webhooks
    # Implementation depends on your specific setup
    
    warning "Webhook URL updates need to be implemented for your specific environment"
    
    # Example: Update external services with new webhook credentials
    # curl -X PUT "https://external-service.com/webhooks/n8n" \
    #      -H "Authorization: Bearer $EXTERNAL_API_TOKEN" \
    #      -d '{"url": "https://n8n.example.com/webhook/endpoint", "auth": "new_credentials"}'
}

# Rotate API tokens and webhooks
rotate_api_tokens() {
    log "Rotating API tokens and webhook signatures..."
    
    # Generate new API tokens
    local new_webhook_secret=$(generate_password 64)
    local new_api_token=$(generate_api_key "n8n")
    
    # Update secrets
    kubectl create secret generic n8n-api-tokens \
        --from-literal=WEBHOOK_SECRET="$new_webhook_secret" \
        --from-literal=API_TOKEN="$new_api_token" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    success "API tokens rotated"
    log "New webhook secret: $new_webhook_secret"
    log "New API token: $new_api_token"
}

# Send notification about credential rotation
send_notification() {
    local rotation_summary=$1
    
    log "Sending rotation notification..."
    
    # Create notification message
    local message="Credential rotation completed for environment: $ENVIRONMENT
    
Rotation Summary:
$rotation_summary

Timestamp: $(date)
Environment: $ENVIRONMENT
Cluster: $(kubectl config current-context)"
    
    # Send to Slack (if webhook URL is configured)
    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        curl -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-type: application/json' \
            -d "{\"text\":\"$message\"}" || warning "Failed to send Slack notification"
    fi
    
    # Send email (if configured)
    if [[ -n "${NOTIFICATION_EMAIL:-}" ]] && command -v mail &> /dev/null; then
        echo "$message" | mail -s "Flow Credential Rotation - $ENVIRONMENT" "$NOTIFICATION_EMAIL" || warning "Failed to send email notification"
    fi
    
    # Log to audit trail
    echo "$message" >> "/var/log/audit-credential-rotation.log"
    
    success "Notification sent"
}

# Verify services after rotation
verify_services() {
    log "Verifying services after credential rotation..."
    
    # Check pod status
    local failing_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running -o jsonpath='{.items[*].metadata.name}')
    if [[ -n "$failing_pods" ]]; then
        error "Some pods are not running: $failing_pods"
        return 1
    fi
    
    # Check service endpoints
    local endpoints=("http://n8n-service:5678/healthz")
    for endpoint in "${endpoints[@]}"; do
        if kubectl run curl-test --image=curlimages/curl:latest --rm -it --restart=Never -- curl -f "$endpoint" &> /dev/null; then
            success "Service endpoint healthy: $endpoint"
        else
            error "Service endpoint unhealthy: $endpoint"
            return 1
        fi
    done
    
    success "All services verified"
}

# Full credential rotation
perform_full_rotation() {
    log "Starting full credential rotation for environment: $ENVIRONMENT"
    
    local backup_dir
    backup_dir=$(backup_secrets)
    
    local rotation_summary=""
    
    # Rotate individual components
    if rotate_postgres_password; then
        rotation_summary+="\n✓ PostgreSQL password rotated"
    else
        rotation_summary+="\n✗ PostgreSQL password rotation failed"
    fi
    
    if rotate_n8n_admin; then
        rotation_summary+="\n✓ n8n admin credentials rotated"
    else
        rotation_summary+="\n✗ n8n admin rotation failed"
    fi
    
    if rotate_grafana_admin; then
        rotation_summary+="\n✓ Grafana admin password rotated"
    else
        rotation_summary+="\n✗ Grafana admin rotation failed"
    fi
    
    if rotate_ssl_certificates; then
        rotation_summary+="\n✓ SSL certificates rotated"
    else
        rotation_summary+="\n✗ SSL certificate rotation failed"
    fi
    
    if rotate_aws_keys; then
        rotation_summary+="\n✓ AWS IAM keys rotated"
    else
        rotation_summary+="\n✗ AWS IAM key rotation failed"
    fi
    
    if rotate_api_tokens; then
        rotation_summary+="\n✓ API tokens rotated"
    else
        rotation_summary+="\n✗ API token rotation failed"
    fi
    
    # Verify services
    if verify_services; then
        rotation_summary+="\n✓ All services verified"
    else
        rotation_summary+="\n✗ Service verification failed"
    fi
    
    # Send notification
    send_notification "$rotation_summary"
    
    success "Full credential rotation completed"
    log "Backup location: $backup_dir"
    log "Rotation summary:$rotation_summary"
}

# Emergency rollback
emergency_rollback() {
    local backup_dir=$1
    
    if [[ -z "$backup_dir" ]]; then
        error "Backup directory required for rollback"
        return 1
    fi
    
    if [[ ! -d "$backup_dir" ]]; then
        error "Backup directory not found: $backup_dir"
        return 1
    fi
    
    log "Performing emergency rollback from: $backup_dir"
    
    # Restore secrets
    kubectl apply -f "$backup_dir/n8n-secrets.yaml"
    kubectl apply -f "$backup_dir/postgres-secrets.yaml"
    kubectl apply -f "$backup_dir/grafana-secrets.yaml" 2>/dev/null || true
    
    # Restart services
    kubectl rollout restart statefulset/postgres -n "$NAMESPACE"
    kubectl rollout restart deployment/n8n -n "$NAMESPACE"
    kubectl rollout restart deployment/grafana -n "$MONITORING_NAMESPACE"
    
    # Wait for services
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgres -n "$NAMESPACE" --timeout=300s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=n8n -n "$NAMESPACE" --timeout=300s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n "$MONITORING_NAMESPACE" --timeout=300s
    
    success "Emergency rollback completed"
}

# Print usage
usage() {
    echo "Flow Credential Rotation Automation"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  full                  Perform full credential rotation"
    echo "  postgres              Rotate PostgreSQL password only"
    echo "  n8n                   Rotate n8n admin credentials only"
    echo "  grafana               Rotate Grafana admin password only"
    echo "  ssl                   Rotate SSL certificates only"
    echo "  aws                   Rotate AWS IAM keys only"
    echo "  api                   Rotate API tokens only"
    echo "  verify                Verify services after rotation"
    echo "  rollback <backup_dir> Emergency rollback to previous credentials"
    echo "  help                  Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  ENVIRONMENT           Environment name (default: production)"
    echo "  SLACK_WEBHOOK_URL     Slack webhook for notifications"
    echo "  NOTIFICATION_EMAIL    Email for notifications"
    echo ""
    echo "Examples:"
    echo "  $0 full                                    # Full rotation"
    echo "  $0 postgres                                # PostgreSQL only"
    echo "  $0 rollback secret-backups/20240101_120000 # Emergency rollback"
}

# Main function
main() {
    local command=${1:-full}
    
    # Create log directory
    mkdir -p "$(dirname "$ROTATION_LOG")"
    
    case "$command" in
        full)
            check_prerequisites
            perform_full_rotation
            ;;
        postgres)
            check_prerequisites
            backup_secrets > /dev/null
            rotate_postgres_password
            verify_services
            ;;
        n8n)
            check_prerequisites
            backup_secrets > /dev/null
            rotate_n8n_admin
            verify_services
            ;;
        grafana)
            check_prerequisites
            backup_secrets > /dev/null
            rotate_grafana_admin
            verify_services
            ;;
        ssl)
            check_prerequisites
            rotate_ssl_certificates
            ;;
        aws)
            check_prerequisites
            rotate_aws_keys
            ;;
        api)
            check_prerequisites
            backup_secrets > /dev/null
            rotate_api_tokens
            verify_services
            ;;
        verify)
            check_prerequisites
            verify_services
            ;;
        rollback)
            check_prerequisites
            emergency_rollback "$2"
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