# Flow Production Deployment Script (Windows PowerShell)
# This script deploys the Flow platform to production environment

param(
    [string]$Environment = "production",
    [string]$AwsRegion = "us-west-2",
    [string]$ClusterName,
    [switch]$Help
)

# Configuration
$Namespace = "n8n"
$MonitoringNamespace = "monitoring"
if (-not $ClusterName) {
    $ClusterName = "flow-$Environment-cluster"
}

# Function to write colored output
function Write-ColorOutput($ForegroundColor) {
    $fc = $host.UI.RawUI.ForegroundColor
    $host.UI.RawUI.ForegroundColor = $ForegroundColor
    if ($args) {
        Write-Output $args
    }
    else {
        $input | Write-Output
    }
    $host.UI.RawUI.ForegroundColor = $fc
}

function Write-Info($Message) {
    Write-ColorOutput Blue "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Write-Success($Message) {
    Write-ColorOutput Green "[SUCCESS] $Message"
}

function Write-Warning($Message) {
    Write-ColorOutput Yellow "[WARNING] $Message"
}

function Write-Error($Message) {
    Write-ColorOutput Red "[ERROR] $Message"
}

# Show usage
function Show-Usage {
    Write-Output @"
Usage: .\deploy_prod.ps1 [options]

Options:
  -Environment ENV     Set environment (default: production)
  -AwsRegion REGION    Set AWS region (default: us-west-2)
  -ClusterName NAME    Set cluster name (default: flow-ENV-cluster)
  -Help                Show this help message

Required Environment Variables:
  POSTGRES_PASSWORD       Database password
  N8N_ADMIN_PASSWORD      n8n admin password

Optional Environment Variables:
  N8N_ADMIN_USER          n8n admin username (default: admin)
  PRODUCTION_DOMAIN       Production domain name
  CERT_EMAIL              Email for SSL certificates
  GRAFANA_ADMIN_PASSWORD  Grafana admin password

Example:
  `$env:POSTGRES_PASSWORD="secret"; `$env:N8N_ADMIN_PASSWORD="admin123"; .\deploy_prod.ps1
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

# Check prerequisites
function Test-Prerequisites {
    Write-Info "Checking prerequisites..."
    
    # Check required tools
    $tools = @("kubectl", "terraform", "aws", "helm")
    foreach ($tool in $tools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Error "$tool is not installed or not in PATH"
            exit 1
        }
    }
    
    # Check AWS credentials
    try {
        aws sts get-caller-identity | Out-Null
    } catch {
        Write-Error "AWS credentials not configured"
        exit 1
    }
    
    # Check environment variables
    if (-not $env:POSTGRES_PASSWORD) {
        Write-Error "POSTGRES_PASSWORD environment variable not set"
        exit 1
    }
    
    if (-not $env:N8N_ADMIN_PASSWORD) {
        Write-Error "N8N_ADMIN_PASSWORD environment variable not set"
        exit 1
    }
    
    Write-Success "Prerequisites check passed"
}

# Deploy infrastructure
function Deploy-Infrastructure {
    Write-Info "Deploying infrastructure with Terraform..."
    
    Set-Location terraform
    
    # Initialize Terraform
    terraform init
    
    # Create or select workspace
    try {
        terraform workspace select $Environment 2>$null
    } catch {
        terraform workspace new $Environment
    }
    
    # Plan deployment
    terraform plan `
        -var="environment=$Environment" `
        -var="project_name=flow" `
        -var="postgres_password=$env:POSTGRES_PASSWORD" `
        -out=tfplan
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform plan failed"
        exit 1
    }
    
    # Apply deployment
    terraform apply tfplan
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform apply failed"
        exit 1
    }
    
    # Save outputs
    terraform output -json > ../outputs.json
    
    Set-Location ..
    Write-Success "Infrastructure deployment completed"
}

# Configure Kubernetes
function Set-KubernetesConfig {
    Write-Info "Configuring Kubernetes access..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $AwsRegion --name $ClusterName
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update kubeconfig"
        exit 1
    }
    
    # Verify cluster access
    try {
        kubectl cluster-info | Out-Null
    } catch {
        Write-Error "Cannot access Kubernetes cluster"
        exit 1
    }
    
    Write-Success "Kubernetes configuration completed"
}

# Create namespaces
function New-Namespaces {
    Write-Info "Creating namespaces..."
    
    kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace $MonitoringNamespace --dry-run=client -o yaml | kubectl apply -f -
    
    Write-Success "Namespaces created"
}

# Create secrets
function New-Secrets {
    Write-Info "Creating Kubernetes secrets..."
    
    # Database secrets
    kubectl create secret generic postgres-secrets `
        --from-literal=POSTGRES_USER=n8n `
        --from-literal=POSTGRES_PASSWORD="$env:POSTGRES_PASSWORD" `
        --namespace="$Namespace" `
        --dry-run=client -o yaml | kubectl apply -f -
    
    # n8n secrets
    $n8nUser = if ($env:N8N_ADMIN_USER) { $env:N8N_ADMIN_USER } else { "admin" }
    kubectl create secret generic n8n-secrets `
        --from-literal=N8N_BASIC_AUTH_USER="$n8nUser" `
        --from-literal=N8N_BASIC_AUTH_PASSWORD="$env:N8N_ADMIN_PASSWORD" `
        --from-literal=DB_POSTGRESDB_PASSWORD="$env:POSTGRES_PASSWORD" `
        --namespace="$Namespace" `
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Monitoring secrets
    $grafanaPassword = if ($env:GRAFANA_ADMIN_PASSWORD) { $env:GRAFANA_ADMIN_PASSWORD } else { $env:N8N_ADMIN_PASSWORD }
    kubectl create secret generic grafana-secrets `
        --from-literal=admin-password="$grafanaPassword" `
        --namespace="$MonitoringNamespace" `
        --dry-run=client -o yaml | kubectl apply -f -
    
    Write-Success "Secrets created"
}

# Install cert-manager
function Install-CertManager {
    Write-Info "Installing cert-manager..."
    
    # Add cert-manager repository
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    # Install cert-manager
    helm upgrade --install cert-manager jetstack/cert-manager `
        --namespace cert-manager `
        --create-namespace `
        --version v1.13.0 `
        --set installCRDs=true
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install cert-manager"
        exit 1
    }
    
    # Wait for cert-manager to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager --namespace=cert-manager --timeout=300s
    
    Write-Success "cert-manager installed"
}

# Create certificate issuer
function New-CertificateIssuer {
    Write-Info "Creating certificate issuer..."
    
    $certEmail = if ($env:CERT_EMAIL) { $env:CERT_EMAIL } else { "admin@example.com" }
    
    @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $certEmail
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
"@ | kubectl apply -f -
    
    Write-Success "Certificate issuer created"
}

# Install NGINX ingress controller
function Install-NginxIngress {
    Write-Info "Installing NGINX ingress controller..."
    
    # Add NGINX repository
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    # Install NGINX ingress controller
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
        --namespace ingress-nginx `
        --create-namespace `
        --set controller.service.type=LoadBalancer `
        --set controller.metrics.enabled=true `
        --set "controller.podAnnotations.prometheus\.io/scrape=true" `
        --set "controller.podAnnotations.prometheus\.io/port=10254"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install NGINX ingress controller"
        exit 1
    }
    
    # Wait for load balancer
    Write-Info "Waiting for load balancer to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=ingress-nginx --namespace=ingress-nginx --timeout=300s
    
    Write-Success "NGINX ingress controller installed"
}

# Deploy database
function Deploy-Database {
    Write-Info "Deploying PostgreSQL database..."
    
    kubectl apply -f k8s/postgres-deployment.yaml
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to deploy database"
        exit 1
    }
    
    # Wait for database to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgres --namespace="$Namespace" --timeout=300s
    
    Write-Success "Database deployed"
}

# Deploy cache
function Deploy-Cache {
    Write-Info "Deploying Redis cache..."
    
    kubectl apply -f k8s/redis-deployment.yaml
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to deploy cache"
        exit 1
    }
    
    # Wait for Redis to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=redis --namespace="$Namespace" --timeout=300s
    
    Write-Success "Cache deployed"
}

# Deploy n8n application
function Deploy-N8n {
    Write-Info "Deploying n8n application..."
    
    kubectl apply -f k8s/n8n-deployment.yaml
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to deploy n8n"
        exit 1
    }
    
    # Wait for n8n to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=n8n --namespace="$Namespace" --timeout=600s
    
    Write-Success "n8n application deployed"
}

# Deploy ingress with SSL
function Deploy-Ingress {
    Write-Info "Deploying ingress with SSL..."
    
    if ($env:PRODUCTION_DOMAIN) {
        # Update ingress with production domain
        (Get-Content k8s/ingress-nginx.yaml) -replace 'n8n.example.com', $env:PRODUCTION_DOMAIN | kubectl apply -f -
    } else {
        Write-Warning "PRODUCTION_DOMAIN not set, using default domain"
        kubectl apply -f k8s/ingress-nginx.yaml
    }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to deploy ingress"
        exit 1
    }
    
    Write-Success "Ingress deployed"
}

# Deploy monitoring
function Deploy-Monitoring {
    Write-Info "Deploying monitoring stack..."
    
    # Deploy Prometheus
    kubectl apply -f k8s/monitoring/prometheus-deployment.yaml
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus --namespace="$MonitoringNamespace" --timeout=300s
    
    # Deploy Grafana
    kubectl apply -f k8s/monitoring/grafana-deployment.yaml
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana --namespace="$MonitoringNamespace" --timeout=300s
    
    # Deploy Alertmanager
    kubectl apply -f k8s/monitoring/alertmanager-deployment.yaml
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=alertmanager --namespace="$MonitoringNamespace" --timeout=300s
    
    Write-Success "Monitoring stack deployed"
}

# Health check
function Test-Health {
    Write-Info "Performing health checks..."
    
    # Check pod status
    Write-Info "Checking pod status..."
    kubectl get pods -n $Namespace
    kubectl get pods -n $MonitoringNamespace
    
    # Check services
    Write-Info "Checking services..."
    kubectl get services -n $Namespace
    kubectl get services -n $MonitoringNamespace
    
    # Wait for ingress to get external IP
    Write-Info "Waiting for external IP..."
    Start-Sleep 60
    
    # Get external endpoint
    $externalIp = kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    if ($externalIp) {
        Write-Success "External endpoint: $externalIp"
        
        # Test health endpoint
        try {
            Invoke-WebRequest -Uri "http://$externalIp/healthz" -UseBasicParsing | Out-Null
            Write-Success "Health check passed"
        } catch {
            Write-Warning "Health check failed - service may still be starting"
        }
    } else {
        Write-Warning "External IP not yet assigned"
    }
}

# Cleanup function
function Invoke-Cleanup {
    Write-Info "Cleaning up temporary files..."
    Remove-Item outputs.json -ErrorAction SilentlyContinue
    Remove-Item tfplan -ErrorAction SilentlyContinue
}

# Main deployment function
function Invoke-Main {
    Write-Info "Starting Flow production deployment..."
    Write-Info "Environment: $Environment"
    Write-Info "AWS Region: $AwsRegion"
    Write-Info "Cluster: $ClusterName"
    
    try {
        Test-Prerequisites
        Deploy-Infrastructure
        Set-KubernetesConfig
        New-Namespaces
        New-Secrets
        Install-CertManager
        New-CertificateIssuer
        Install-NginxIngress
        Deploy-Database
        Deploy-Cache
        Deploy-N8n
        Deploy-Ingress
        Deploy-Monitoring
        Test-Health
        
        Write-Success "Flow production deployment completed successfully!"
        
        Write-Info "Next steps:"
        Write-Info "1. Update DNS to point to the load balancer"
        Write-Info "2. Wait for SSL certificates to be issued"
        $domain = if ($env:PRODUCTION_DOMAIN) { $env:PRODUCTION_DOMAIN } else { "your-domain.com" }
        Write-Info "3. Access n8n at https://$domain"
        Write-Info "4. Access Grafana at https://grafana.$domain"
        Write-Info "5. Review logs and monitoring dashboards"
        
    } catch {
        Write-Error "Deployment failed: $($_.Exception.Message)"
        exit 1
    } finally {
        Invoke-Cleanup
    }
}

# Run main function
Invoke-Main