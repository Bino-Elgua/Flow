# Flow Deployment Guide

This guide provides step-by-step instructions for deploying the Flow platform across different environments.

## Prerequisites

### Required Tools
- Docker Desktop or compatible container runtime
- kubectl (Kubernetes CLI)
- Terraform v1.6+
- AWS CLI v2
- Helm v3
- Git

### Required Accounts
- AWS account with appropriate permissions
- GitHub account for CI/CD
- Domain name for SSL certificates (production)

### Required Permissions
- EKS cluster management
- RDS instance creation
- ElastiCache cluster management
- VPC and networking
- IAM role and policy management

## Environment Setup

### Local Development

#### 1. Clone Repository
```bash
git clone https://github.com/Bino-Elgua/Flow.git
cd Flow
```

#### 2. Start Local Services
```bash
cd docker
cp ../config/.env.example .env
# Edit .env with your local configuration
docker-compose up -d
```

#### 3. Verify Installation
```bash
# Check service health
curl http://localhost:5678/healthz

# Access n8n interface
open http://localhost:5678
```

### Staging Environment

#### 1. Configure AWS Credentials
```bash
aws configure
# Enter your AWS access key, secret key, and region
```

#### 2. Deploy Infrastructure
```bash
cd terraform
terraform init
terraform plan -var="environment=staging"
terraform apply -var="environment=staging"
```

#### 3. Configure Kubernetes
```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-west-2 --name flow-staging-cluster

# Verify cluster access
kubectl cluster-info
```

#### 4. Deploy Applications
```bash
# Create namespace
kubectl create namespace n8n

# Deploy database
kubectl apply -f k8s/postgres-deployment.yaml

# Deploy cache
kubectl apply -f k8s/redis-deployment.yaml

# Deploy n8n
kubectl apply -f k8s/n8n-deployment.yaml

# Deploy ingress
kubectl apply -f k8s/ingress-nginx.yaml
```

#### 5. Deploy Monitoring
```bash
# Create monitoring namespace
kubectl create namespace monitoring

# Deploy Prometheus
kubectl apply -f k8s/monitoring/prometheus-deployment.yaml

# Deploy Grafana
kubectl apply -f k8s/monitoring/grafana-deployment.yaml

# Deploy Alertmanager
kubectl apply -f k8s/monitoring/alertmanager-deployment.yaml
```

### Production Environment

#### 1. Environment Preparation
```bash
# Set production variables
export TF_VAR_environment=production
export TF_VAR_postgres_password="your-secure-password"
```

#### 2. Infrastructure Deployment
```bash
cd terraform
terraform workspace new production
terraform init
terraform plan -var="environment=production"
terraform apply -var="environment=production"
```

#### 3. SSL Certificate Setup
```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Create cluster issuer
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

#### 4. Application Deployment
```bash
# Deploy with production configuration
kubectl apply -f k8s/postgres-deployment.yaml
kubectl apply -f k8s/redis-deployment.yaml
kubectl apply -f k8s/n8n-deployment.yaml

# Update ingress with production domain
sed 's/n8n.example.com/your-production-domain.com/g' k8s/ingress-nginx.yaml | kubectl apply -f -
```

## Configuration Management

### Environment Variables

#### Development (.env)
```bash
# Basic configuration for local development
N8N_HOST=0.0.0.0
N8N_PORT=5678
N8N_PROTOCOL=http
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
WEBHOOK_URL=http://localhost:5678/
```

#### Staging
```bash
# Enhanced configuration for staging
N8N_HOST=0.0.0.0
N8N_PORT=5678
N8N_PROTOCOL=https
DB_POSTGRESDB_HOST=flow-staging-postgres.region.rds.amazonaws.com
WEBHOOK_URL=https://n8n-staging.example.com/
N8N_METRICS=true
```

#### Production
```bash
# Full production configuration
N8N_HOST=0.0.0.0
N8N_PORT=5678
N8N_PROTOCOL=https
DB_POSTGRESDB_HOST=flow-production-postgres.region.rds.amazonaws.com
WEBHOOK_URL=https://n8n.example.com/
N8N_METRICS=true
N8N_LOG_LEVEL=warn
```

### Secrets Management

#### Create Kubernetes Secrets
```bash
# Database secrets
kubectl create secret generic postgres-secrets \
  --from-literal=POSTGRES_USER=n8n \
  --from-literal=POSTGRES_PASSWORD=your-secure-password \
  --namespace=n8n

# n8n secrets
kubectl create secret generic n8n-secrets \
  --from-literal=N8N_BASIC_AUTH_USER=admin \
  --from-literal=N8N_BASIC_AUTH_PASSWORD=your-admin-password \
  --from-literal=DB_POSTGRESDB_PASSWORD=your-secure-password \
  --namespace=n8n

# Monitoring secrets
kubectl create secret generic grafana-secrets \
  --from-literal=admin-password=your-grafana-password \
  --namespace=monitoring
```

## Monitoring Setup

### Prometheus Configuration

#### 1. Verify Prometheus Deployment
```bash
kubectl get pods -n monitoring
kubectl logs -f deployment/prometheus -n monitoring
```

#### 2. Access Prometheus UI
```bash
kubectl port-forward svc/prometheus 9090:9090 -n monitoring
open http://localhost:9090
```

### Grafana Setup

#### 1. Access Grafana
```bash
kubectl port-forward svc/grafana 3000:3000 -n monitoring
open http://localhost:3000
```

#### 2. Initial Login
- Username: `admin`
- Password: From `grafana-secrets` secret

#### 3. Import Dashboards
- Navigate to Dashboards > Import
- Use dashboard ID or upload JSON files
- Configure data sources (Prometheus)

### Alerting Configuration

#### 1. Configure Alertmanager
```bash
kubectl edit configmap alertmanager-config -n monitoring
```

#### 2. Update Notification Channels
```yaml
# Email configuration
smtp_smarthost: 'your-smtp-server:587'
smtp_from: 'alerts@your-domain.com'
smtp_auth_username: 'your-smtp-user'
smtp_auth_password: 'your-smtp-password'

# Slack configuration
slack_api_url: 'your-slack-webhook-url'
```

## Health Checks and Validation

### Service Health Verification

#### 1. Check All Pods
```bash
kubectl get pods --all-namespaces
```

#### 2. Verify Service Endpoints
```bash
# n8n health
kubectl exec -it deployment/n8n -n n8n -- curl localhost:5678/healthz

# Database connectivity
kubectl exec -it deployment/postgres -n n8n -- pg_isready -U n8n

# Redis connectivity
kubectl exec -it deployment/redis -n n8n -- redis-cli ping
```

#### 3. External Connectivity
```bash
# From outside cluster
curl https://your-domain.com/healthz

# Webhook test
curl -X POST https://your-domain.com/webhook/test -d '{"test": true}'
```

### Performance Testing

#### 1. Load Testing
```bash
# Install k6
brew install k6  # macOS
# or
sudo apt-get install k6  # Ubuntu

# Run load test
k6 run tests/load-test.js
```

#### 2. Monitor Resources
```bash
# Watch resource usage
kubectl top nodes
kubectl top pods --all-namespaces
```

## Backup and Recovery

### Database Backup

#### 1. Automated Backups
```bash
# RDS automated backups are enabled by default
# Verify backup settings
aws rds describe-db-instances --db-instance-identifier flow-production-postgres
```

#### 2. Manual Backup
```bash
# Create manual snapshot
aws rds create-db-snapshot \
  --db-instance-identifier flow-production-postgres \
  --db-snapshot-identifier flow-manual-backup-$(date +%Y%m%d)
```

### Configuration Backup

#### 1. Export Configurations
```bash
# Export all Kubernetes manifests
kubectl get all --all-namespaces -o yaml > cluster-backup.yaml

# Export secrets (encrypted)
kubectl get secrets --all-namespaces -o yaml > secrets-backup.yaml
```

#### 2. Workflow Backup
```bash
# Connect to n8n and export workflows
# Use n8n CLI or API to export workflow definitions
```

## Troubleshooting

### Common Issues

#### 1. Pod Startup Issues
```bash
# Check pod status
kubectl describe pod <pod-name> -n <namespace>

# Check logs
kubectl logs <pod-name> -n <namespace> --previous
```

#### 2. Database Connection Issues
```bash
# Test database connectivity
kubectl run postgres-client --image=postgres:15 --rm -it --restart=Never -- \
  psql -h <db-host> -U n8n -d n8n
```

#### 3. Ingress Issues
```bash
# Check ingress configuration
kubectl describe ingress n8n-ingress -n n8n

# Check NGINX logs
kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx
```

### Performance Issues

#### 1. High Memory Usage
```bash
# Increase resource limits
kubectl patch deployment n8n -n n8n -p '{"spec":{"template":{"spec":{"containers":[{"name":"n8n","resources":{"limits":{"memory":"2Gi"}}}]}}}}'
```

#### 2. Database Performance
```bash
# Monitor database metrics in Grafana
# Consider scaling up RDS instance class
aws rds modify-db-instance --db-instance-identifier flow-production-postgres --db-instance-class db.t3.large
```

### Security Issues

#### 1. Certificate Problems
```bash
# Check certificate status
kubectl describe certificate n8n-tls -n n8n

# Force certificate renewal
kubectl delete certificate n8n-tls -n n8n
kubectl apply -f k8s/ingress-nginx.yaml
```

#### 2. Access Issues
```bash
# Verify RBAC permissions
kubectl auth can-i get pods --namespace=n8n --as=system:serviceaccount:n8n:default
```

## Maintenance

### Regular Tasks

#### 1. Update Dependencies
```bash
# Update Docker images
docker-compose pull
docker-compose up -d

# Update Kubernetes manifests
kubectl set image deployment/n8n n8n=n8nio/n8n:latest -n n8n
```

#### 2. Certificate Renewal
```bash
# Certificates auto-renew with cert-manager
# Verify renewal process
kubectl get certificates --all-namespaces
```

#### 3. Backup Verification
```bash
# Test backup restoration monthly
# Document recovery procedures
# Validate backup integrity
```

### Scaling Operations

#### 1. Horizontal Scaling
```bash
# Scale n8n pods
kubectl scale deployment n8n --replicas=3 -n n8n

# Scale database connections (update configuration)
```

#### 2. Vertical Scaling
```bash
# Update resource limits
kubectl patch deployment n8n -n n8n -p '{"spec":{"template":{"spec":{"containers":[{"name":"n8n","resources":{"requests":{"cpu":"500m","memory":"1Gi"},"limits":{"cpu":"1000m","memory":"2Gi"}}}]}}}}'
```

## Support and Documentation

### Getting Help
- GitHub Issues: [Repository Issues](https://github.com/Bino-Elgua/Flow/issues)
- Documentation: `/docs` directory
- Monitoring: Grafana dashboards
- Logs: Centralized logging in Kubernetes

### Additional Resources
- [n8n Documentation](https://docs.n8n.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Prometheus Documentation](https://prometheus.io/docs/)