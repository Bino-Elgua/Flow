#!/bin/bash

# Flow Production Deployment Script (Linux)
# This script deploys the Flow platform to production environment

set -e  # Exit on any error

# Configuration
ENVIRONMENT="production"
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="flow-${ENVIRONMENT}-cluster"
NAMESPACE="n8n"
MONITORING_NAMESPACE="monitoring"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
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
    local tools=("kubectl" "terraform" "aws" "helm" "jq")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "$tool is not installed or not in PATH"
            exit 1
        fi
    done
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured"
        exit 1
    fi
    
    # Check environment variables
    if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
        error "POSTGRES_PASSWORD environment variable not set"
        exit 1
    fi
    
    if [[ -z "${N8N_ADMIN_PASSWORD:-}" ]]; then
        error "N8N_ADMIN_PASSWORD environment variable not set"
        exit 1
    fi
    
    success "Prerequisites check passed"
}

# Deploy infrastructure
deploy_infrastructure() {
    log "Deploying infrastructure with Terraform..."
    
    cd terraform
    
    # Initialize Terraform
    terraform init
    
    # Create or select workspace
    terraform workspace select "$ENVIRONMENT" 2>/dev/null || terraform workspace new "$ENVIRONMENT"
    
    # Plan deployment
    terraform plan \
        -var="environment=$ENVIRONMENT" \
        -var="project_name=flow" \
        -var="postgres_password=$POSTGRES_PASSWORD" \
        -out=tfplan
    
    # Apply deployment
    terraform apply tfplan
    
    # Save outputs
    terraform output -json > ../outputs.json
    
    cd ..
    success "Infrastructure deployment completed"
}

# Configure Kubernetes
configure_kubernetes() {
    log "Configuring Kubernetes access..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
    
    # Verify cluster access
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot access Kubernetes cluster"
        exit 1
    fi
    
    success "Kubernetes configuration completed"
}

# Create namespaces
create_namespaces() {
    log "Creating namespaces..."
    
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    success "Namespaces created"
}

# Create secrets
create_secrets() {
    log "Creating Kubernetes secrets..."
    
    # Database secrets
    kubectl create secret generic postgres-secrets \
        --from-literal=POSTGRES_USER=n8n \
        --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # n8n secrets
    kubectl create secret generic n8n-secrets \
        --from-literal=N8N_BASIC_AUTH_USER="${N8N_ADMIN_USER:-admin}" \
        --from-literal=N8N_BASIC_AUTH_PASSWORD="$N8N_ADMIN_PASSWORD" \
        --from-literal=DB_POSTGRESDB_PASSWORD="$POSTGRES_PASSWORD" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Monitoring secrets
    kubectl create secret generic grafana-secrets \
        --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD:-$N8N_ADMIN_PASSWORD}" \
        --namespace="$MONITORING_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    success "Secrets created"
}

# Install cert-manager
install_cert_manager() {
    log "Installing cert-manager..."
    
    # Add cert-manager repository
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    # Install cert-manager
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.13.0 \
        --set installCRDs=true
    
    # Wait for cert-manager to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager --namespace=cert-manager --timeout=300s
    
    success "cert-manager installed"
}

# Create certificate issuer
create_certificate_issuer() {
    log "Creating certificate issuer..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${CERT_EMAIL:-admin@example.com}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
    
    success "Certificate issuer created"
}

# Install NGINX ingress controller
install_nginx_ingress() {
    log "Installing NGINX ingress controller..."
    
    # Add NGINX repository
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    # Install NGINX ingress controller
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=LoadBalancer \
        --set controller.metrics.enabled=true \
        --set controller.podAnnotations."prometheus\.io/scrape"=true \
        --set controller.podAnnotations."prometheus\.io/port"=10254
    
    # Wait for load balancer
    log "Waiting for load balancer to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=ingress-nginx --namespace=ingress-nginx --timeout=300s
    
    success "NGINX ingress controller installed"
}

# Deploy database
deploy_database() {
    log "Deploying PostgreSQL database..."
    
    kubectl apply -f k8s/postgres-deployment.yaml
    
    # Wait for database to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgres --namespace="$NAMESPACE" --timeout=300s
    
    success "Database deployed"
}

# Deploy cache
deploy_cache() {
    log "Deploying Redis cache..."
    
    kubectl apply -f k8s/redis-deployment.yaml
    
    # Wait for Redis to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=redis --namespace="$NAMESPACE" --timeout=300s
    
    success "Cache deployed"
}

# Deploy n8n application
deploy_n8n() {
    log "Deploying n8n application..."
    
    kubectl apply -f k8s/n8n-deployment.yaml
    
    # Wait for n8n to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=n8n --namespace="$NAMESPACE" --timeout=600s
    
    success "n8n application deployed"
}

# Deploy ingress with SSL
deploy_ingress() {
    log "Deploying ingress with SSL..."
    
    # Update ingress with production domain
    if [[ -n "${PRODUCTION_DOMAIN:-}" ]]; then
        sed "s/n8n.example.com/$PRODUCTION_DOMAIN/g" k8s/ingress-nginx.yaml | kubectl apply -f -
    else
        warning "PRODUCTION_DOMAIN not set, using default domain"
        kubectl apply -f k8s/ingress-nginx.yaml
    fi
    
    success "Ingress deployed"
}

# Deploy monitoring
deploy_monitoring() {
    log "Deploying monitoring stack..."
    
    # Deploy Prometheus
    kubectl apply -f k8s/monitoring/prometheus-deployment.yaml
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus --namespace="$MONITORING_NAMESPACE" --timeout=300s
    
    # Deploy Grafana
    kubectl apply -f k8s/monitoring/grafana-deployment.yaml
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana --namespace="$MONITORING_NAMESPACE" --timeout=300s
    
    # Deploy Alertmanager
    kubectl apply -f k8s/monitoring/alertmanager-deployment.yaml
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=alertmanager --namespace="$MONITORING_NAMESPACE" --timeout=300s
    
    success "Monitoring stack deployed"
}

# Health check
health_check() {
    log "Performing health checks..."
    
    # Check pod status
    log "Checking pod status..."
    kubectl get pods -n "$NAMESPACE"
    kubectl get pods -n "$MONITORING_NAMESPACE"
    
    # Check services
    log "Checking services..."
    kubectl get services -n "$NAMESPACE"
    kubectl get services -n "$MONITORING_NAMESPACE"
    
    # Wait for ingress to get external IP
    log "Waiting for external IP..."
    sleep 60
    
    # Get external endpoint
    EXTERNAL_IP=$(kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [[ -n "$EXTERNAL_IP" ]]; then
        success "External endpoint: $EXTERNAL_IP"
        
        # Test health endpoint
        if curl -f "http://$EXTERNAL_IP/healthz" 2>/dev/null; then
            success "Health check passed"
        else
            warning "Health check failed - service may still be starting"
        fi
    else
        warning "External IP not yet assigned"
    fi
}

# Cleanup function
cleanup() {
    log "Cleaning up temporary files..."
    rm -f outputs.json
    rm -f tfplan
}

# Main deployment function
main() {
    log "Starting Flow production deployment..."
    log "Environment: $ENVIRONMENT"
    log "AWS Region: $AWS_REGION"
    log "Cluster: $CLUSTER_NAME"
    
    # Trap cleanup on exit
    trap cleanup EXIT
    
    check_prerequisites
    deploy_infrastructure
    configure_kubernetes
    create_namespaces
    create_secrets
    install_cert_manager
    create_certificate_issuer
    install_nginx_ingress
    deploy_database
    deploy_cache
    deploy_n8n
    deploy_ingress
    deploy_monitoring
    health_check
    
    success "Flow production deployment completed successfully!"
    
    log "Next steps:"
    log "1. Update DNS to point to the load balancer"
    log "2. Wait for SSL certificates to be issued"
    log "3. Access n8n at https://${PRODUCTION_DOMAIN:-your-domain.com}"
    log "4. Access Grafana at https://grafana.${PRODUCTION_DOMAIN:-your-domain.com}"
    log "5. Review logs and monitoring dashboards"
}

# Print usage
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -e, --environment ENV   Set environment (default: production)"
    echo "  -r, --region REGION     Set AWS region (default: us-west-2)"
    echo ""
    echo "Required Environment Variables:"
    echo "  POSTGRES_PASSWORD       Database password"
    echo "  N8N_ADMIN_PASSWORD      n8n admin password"
    echo ""
    echo "Optional Environment Variables:"
    echo "  N8N_ADMIN_USER          n8n admin username (default: admin)"
    echo "  PRODUCTION_DOMAIN       Production domain name"
    echo "  CERT_EMAIL              Email for SSL certificates"
    echo "  GRAFANA_ADMIN_PASSWORD  Grafana admin password"
    echo ""
    echo "Example:"
    echo "  POSTGRES_PASSWORD=secret N8N_ADMIN_PASSWORD=admin123 $0"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Run main function
main "$@"