# Flow - Enterprise Workflow Automation Platform

Flow is a comprehensive enterprise-grade workflow automation platform built on n8n, designed for high availability, scalability, and security in production environments.

## 🚀 Features

- **Enterprise n8n Deployment**: Production-ready n8n setup with PostgreSQL and Redis
- **Cloud Infrastructure**: Multi-cloud Terraform modules (AWS/GCP/Azure)
- **Container Orchestration**: Complete Kubernetes manifests with health checks
- **Monitoring & Observability**: Prometheus, Grafana, and Alertmanager stack
- **CI/CD Pipeline**: GitHub Actions with comprehensive testing and deployment
- **Security**: SSL/TLS, network policies, RBAC, and security scanning
- **High Availability**: Load balancing, auto-scaling, and disaster recovery
- **Documentation**: Complete operational runbooks and troubleshooting guides

## 📋 Prerequisites

- Docker Desktop or compatible container runtime
- kubectl (Kubernetes CLI)
- Terraform v1.6+
- AWS CLI v2 (for cloud deployment)
- Git

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                              │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                  Load Balancer                              │
│              (AWS Application LB)                           │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                 NGINX Ingress                               │
│          SSL Termination & Routing                          │
└─────────────────────┬───────────────────────────────────────┘
                      │
    ┌─────────────────┼─────────────────┐
    │                 │                 │
    ▼                 ▼                 ▼
┌───────┐    ┌─────────────┐    ┌─────────────┐
│ n8n   │    │ Monitoring  │    │  Grafana    │
│ App   │    │ Prometheus  │    │ Dashboard   │
└───┬───┘    └─────────────┘    └─────────────┘
    │
    ▼
┌─────────────────────────────────────────────┐
│              Data Layer                     │
├─────────────────┬───────────────────────────┤
│   PostgreSQL    │         Redis             │
│   (Primary DB)  │      (Cache/Queue)        │
└─────────────────┴───────────────────────────┘
```

## 🚦 Quick Start

### Local Development

1. **Clone the repository**
   ```bash
   git clone https://github.com/Bino-Elgua/Flow.git
   cd Flow
   ```

2. **Start local services**
   ```bash
   cd docker
   cp ../config/.env.example .env
   # Edit .env with your configuration
   docker-compose up -d
   ```

3. **Access n8n**
   - URL: http://localhost:5678
   - Username: admin
   - Password: admin (configured in .env)

### Production Deployment

1. **Configure AWS credentials**
   ```bash
   aws configure
   ```

2. **Deploy infrastructure**
   ```bash
   cd terraform
   terraform init
   terraform plan -var="environment=production"
   terraform apply -var="environment=production"
   ```

3. **Deploy applications**
   ```bash
   # Update kubeconfig
   aws eks update-kubeconfig --region us-west-2 --name flow-production-cluster
   
   # Deploy services
   kubectl apply -f k8s/
   kubectl apply -f k8s/monitoring/
   ```

## 📁 Repository Structure

```
├── .github/workflows/     # GitHub Actions CI/CD pipelines
├── scripts/              # Deployment and automation scripts
├── workflows/            # n8n workflow templates
├── terraform/            # Infrastructure as Code
├── k8s/                  # Kubernetes manifests
│   └── monitoring/       # Prometheus, Grafana, Alertmanager
├── docker/               # Docker configurations
├── nginx/               # NGINX configuration
├── docs/                # Documentation
├── config/              # Configuration templates
├── tests/               # Testing framework
└── LICENSE
```

## 🔧 Configuration

### Environment Variables

Key configuration options in `.env`:

```bash
# n8n Configuration
N8N_HOST=0.0.0.0
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://n8n.example.com/

# Database Configuration
DB_POSTGRESDB_HOST=postgres-service
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=🔑SECURE_PASSWORD🔑

# Redis Configuration
QUEUE_BULL_REDIS_HOST=redis-service
QUEUE_BULL_REDIS_PORT=6379

# Security Configuration
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=🔑ADMIN_USER🔑
N8N_BASIC_AUTH_PASSWORD=🔑ADMIN_PASSWORD🔑

# Monitoring
N8N_METRICS=true
```

### Terraform Variables

Configure infrastructure in `terraform/variables.tf`:

```hcl
variable "environment" {
  description = "Environment name"
  default     = "production"
}

variable "aws_region" {
  description = "AWS region"
  default     = "us-west-2"
}

variable "node_instance_types" {
  description = "EC2 instance types for EKS node group"
  default     = ["t3.medium"]
}
```

## 🔍 Monitoring

### Dashboards

- **Grafana**: https://grafana.example.com
  - Flow Overview Dashboard
  - n8n Metrics Dashboard
  - Infrastructure Monitoring
  - Application Performance

- **Prometheus**: https://prometheus.example.com (internal)
  - Metrics collection
  - Alert rules
  - Service discovery

### Key Metrics

- `n8n_workflow_executions_total`: Total workflow executions
- `n8n_workflow_execution_duration`: Workflow execution time
- `n8n_active_workflows`: Number of active workflows
- `up{job="n8n"}`: Service availability

### Alerts

- Service downtime (Critical)
- High error rates (Warning)
- Resource exhaustion (Warning)
- Certificate expiration (Warning)

## 🔒 Security

### Features

- **SSL/TLS**: Automatic certificate management with Let's Encrypt
- **Network Security**: Kubernetes network policies and VPC isolation
- **Authentication**: Basic auth, JWT support, RBAC
- **Scanning**: Container vulnerability scanning with Trivy
- **Secrets**: Kubernetes secrets management
- **Rate Limiting**: NGINX-based rate limiting and DDoS protection

### Best Practices

- Regular security updates
- Principle of least privilege
- Network segmentation
- Audit logging
- Backup encryption

## 🧪 Testing

### Running Tests

```bash
# Run workflow tests
cd tests
node workflow.test.js

# Run infrastructure tests
cd terraform
terraform plan -var="environment=test"

# Run container tests
docker-compose -f docker/docker-compose.yml up --build
```

### CI/CD Pipeline

The GitHub Actions pipeline includes:

1. **Lint & Validate**: JSON, YAML, Docker, Terraform validation
2. **Security Scan**: Vulnerability and secret scanning
3. **Build & Test**: Multi-service Docker builds and testing
4. **Integration Tests**: End-to-end service testing
5. **Deploy**: Automated deployment to staging/production

## 📚 Documentation

- [Architecture Guide](docs/architecture.md)
- [Deployment Guide](docs/deployment-guide.md)
- [Operational Runbook](docs/operational-runbook.md)
- [Troubleshooting Guide](docs/troubleshooting.md)
- [API Specifications](docs/api-specs.yaml)

## 🚀 Deployment Environments

### Development
- Single-node local setup
- Docker Compose
- Basic monitoring
- HTTP (no SSL)

### Staging
- Multi-node Kubernetes
- Full infrastructure stack
- Complete monitoring
- SSL with self-signed certs

### Production
- High-availability setup
- Multi-AZ deployment
- Enterprise monitoring
- Valid SSL certificates
- Backup and disaster recovery

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

- **Documentation**: Complete guides in `/docs`
- **Issues**: [GitHub Issues](https://github.com/Bino-Elgua/Flow/issues)
- **Community**: [n8n Community](https://community.n8n.io/)

## 🎯 Roadmap

- [ ] Multi-cloud support (GCP, Azure)
- [ ] Advanced workflow analytics
- [ ] Machine learning integration
- [ ] Enhanced security features
- [ ] Global load balancing
- [ ] Serverless deployment options

## 📊 Performance

### Service Level Objectives
- **Availability**: 99.9% uptime
- **Response Time**: <200ms p95
- **Throughput**: 1000 workflows/minute
- **Error Rate**: <0.1%

### Resource Requirements
- **Minimum**: 2 vCPU, 4GB RAM per node
- **Recommended**: 4 vCPU, 8GB RAM per node
- **Storage**: 100GB minimum, 500GB recommended

---

**Built with ❤️ by the Flow Team**