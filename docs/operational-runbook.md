# Flow Operational Runbook

This runbook provides operational procedures for maintaining and troubleshooting the Flow platform.

## Emergency Contacts

### On-Call Escalation
1. **Primary**: Platform Team Lead
2. **Secondary**: DevOps Engineer
3. **Escalation**: Engineering Manager

### Communication Channels
- **Slack**: #flow-alerts, #flow-ops
- **Email**: ops-team@example.com
- **Phone**: Emergency hotline

## Service Level Objectives (SLOs)

### Availability Targets
- **Production**: 99.9% uptime (8.77 hours downtime/year)
- **Staging**: 99.5% uptime
- **Development**: Best effort

### Performance Targets
- **Response Time**: 95th percentile < 200ms
- **Throughput**: > 1000 workflows/minute
- **Error Rate**: < 0.1%

## Monitoring and Alerting

### Key Metrics

#### Application Metrics
- **n8n_workflow_executions_total**: Total workflow executions
- **n8n_workflow_execution_duration**: Workflow execution time
- **n8n_active_workflows**: Number of active workflows
- **n8n_webhook_requests_total**: Webhook request count

#### Infrastructure Metrics
- **node_cpu_usage**: CPU utilization
- **node_memory_usage**: Memory utilization
- **node_disk_usage**: Disk space utilization
- **node_network_io**: Network I/O

#### Database Metrics
- **postgres_up**: Database availability
- **postgres_connections**: Active connections
- **postgres_slow_queries**: Query performance
- **postgres_replication_lag**: Replication delay

### Alert Definitions

#### Critical Alerts (P1)
```yaml
- alert: ServiceDown
  expr: up{job="n8n"} == 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "Flow service is down"
    runbook_url: "https://runbook.example.com/service-down"

- alert: DatabaseDown
  expr: up{job="postgres"} == 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "Database is down"
    runbook_url: "https://runbook.example.com/database-down"

- alert: HighErrorRate
  expr: rate(n8n_workflow_executions_total{status="error"}[5m]) > 0.1
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "High workflow error rate"
    runbook_url: "https://runbook.example.com/high-error-rate"
```

#### Warning Alerts (P2)
```yaml
- alert: HighCPUUsage
  expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High CPU usage detected"

- alert: HighMemoryUsage
  expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 80
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High memory usage detected"
```

### Dashboard Access
- **Grafana**: https://grafana.example.com
- **Prometheus**: https://prometheus.example.com (internal)
- **Alertmanager**: https://alertmanager.example.com (internal)

## Incident Response Procedures

### Incident Classification

#### P1 - Critical (Response: 15 minutes)
- Complete service outage
- Data loss or corruption
- Security breach
- Payment processing failure

#### P2 - High (Response: 1 hour)
- Partial service degradation
- Performance issues affecting users
- Non-critical feature failures

#### P3 - Medium (Response: 4 hours)
- Minor feature issues
- Cosmetic problems
- Documentation errors

#### P4 - Low (Response: 24 hours)
- Enhancement requests
- Non-urgent maintenance

### Response Procedures

#### 1. Initial Response (0-15 minutes)
1. **Acknowledge** the alert in monitoring system
2. **Assess** impact and classify incident severity
3. **Notify** stakeholders via appropriate channels
4. **Document** incident in tracking system
5. **Begin** initial investigation

#### 2. Investigation (15-60 minutes)
1. **Check** service health dashboards
2. **Review** recent deployments and changes
3. **Examine** application and infrastructure logs
4. **Identify** root cause or escalate
5. **Implement** immediate mitigation if possible

#### 3. Resolution (Variable)
1. **Apply** permanent fix
2. **Verify** service restoration
3. **Monitor** for stability
4. **Update** stakeholders
5. **Document** resolution steps

#### 4. Post-Incident (24-48 hours)
1. **Conduct** post-incident review
2. **Document** lessons learned
3. **Create** action items for prevention
4. **Update** runbooks and procedures

## Common Operational Procedures

### Service Health Checks

#### Manual Health Check
```bash
#!/bin/bash
# health-check.sh

echo "=== Flow Health Check ==="
echo "Timestamp: $(date)"
echo

# Check n8n service
echo "1. Checking n8n service..."
curl -f https://n8n.example.com/healthz || echo "❌ n8n service failed"

# Check database
echo "2. Checking database..."
kubectl exec -n n8n deployment/postgres -- pg_isready -U n8n || echo "❌ Database failed"

# Check Redis
echo "3. Checking Redis..."
kubectl exec -n n8n deployment/redis -- redis-cli ping || echo "❌ Redis failed"

# Check pods
echo "4. Checking pod status..."
kubectl get pods -n n8n --no-headers | grep -v Running && echo "❌ Some pods not running"

echo "Health check complete."
```

#### Automated Health Monitoring
```bash
# Cron job: Run every 5 minutes
*/5 * * * * /opt/scripts/health-check.sh >> /var/log/health-check.log 2>&1
```

### Performance Monitoring

#### Check Resource Usage
```bash
#!/bin/bash
# resource-check.sh

echo "=== Resource Usage Check ==="

# CPU usage
echo "CPU Usage:"
kubectl top nodes

# Memory usage
echo -e "\nMemory Usage:"
kubectl top pods --all-namespaces --sort-by=memory

# Disk usage
echo -e "\nDisk Usage:"
kubectl exec -n n8n deployment/postgres -- df -h

# Database connections
echo -e "\nDatabase Connections:"
kubectl exec -n n8n deployment/postgres -- psql -U n8n -d n8n -c "SELECT count(*) FROM pg_stat_activity;"
```

#### Performance Optimization
```bash
#!/bin/bash
# optimize-performance.sh

# Restart pods if memory usage is high
HIGH_MEMORY_PODS=$(kubectl top pods -n n8n --no-headers | awk '$3 ~ /[0-9]+Mi/ && $3+0 > 1000 {print $1}')

if [ ! -z "$HIGH_MEMORY_PODS" ]; then
    echo "Restarting high memory pods: $HIGH_MEMORY_PODS"
    echo "$HIGH_MEMORY_PODS" | xargs -I {} kubectl delete pod {} -n n8n
fi
```

### Backup Operations

#### Manual Backup
```bash
#!/bin/bash
# manual-backup.sh

BACKUP_DATE=$(date +%Y%m%d_%H%M%S)

echo "Starting manual backup at $BACKUP_DATE"

# Database backup
echo "Creating database backup..."
kubectl exec -n n8n deployment/postgres -- pg_dump -U n8n n8n > "backup_db_$BACKUP_DATE.sql"

# Configuration backup
echo "Creating configuration backup..."
kubectl get all,secrets,configmaps -n n8n -o yaml > "backup_k8s_$BACKUP_DATE.yaml"

# Workflow export (if n8n CLI available)
echo "Exporting workflows..."
# n8n export:workflow --all --output="backup_workflows_$BACKUP_DATE.json"

echo "Backup completed: backup_*_$BACKUP_DATE.*"
```

#### Backup Verification
```bash
#!/bin/bash
# verify-backup.sh

LATEST_BACKUP=$(ls -t backup_db_*.sql | head -1)

if [ -f "$LATEST_BACKUP" ]; then
    echo "Verifying backup: $LATEST_BACKUP"
    
    # Check if backup file is not empty
    if [ -s "$LATEST_BACKUP" ]; then
        echo "✅ Backup file exists and is not empty"
        
        # Verify SQL syntax
        if grep -q "PostgreSQL database dump" "$LATEST_BACKUP"; then
            echo "✅ Backup appears to be valid PostgreSQL dump"
        else
            echo "❌ Backup may be corrupted"
        fi
    else
        echo "❌ Backup file is empty"
    fi
else
    echo "❌ No backup files found"
fi
```

### Deployment Operations

#### Rolling Deployment
```bash
#!/bin/bash
# rolling-deploy.sh

VERSION=${1:-latest}
echo "Deploying version: $VERSION"

# Update n8n deployment
kubectl set image deployment/n8n n8n=n8nio/n8n:$VERSION -n n8n

# Wait for rollout to complete
kubectl rollout status deployment/n8n -n n8n --timeout=300s

# Verify deployment
if kubectl get pods -n n8n | grep -q "Running"; then
    echo "✅ Deployment successful"
else
    echo "❌ Deployment failed"
    kubectl rollout undo deployment/n8n -n n8n
    exit 1
fi
```

#### Rollback Deployment
```bash
#!/bin/bash
# rollback.sh

echo "Rolling back to previous version..."

# Rollback n8n deployment
kubectl rollout undo deployment/n8n -n n8n

# Wait for rollback to complete
kubectl rollout status deployment/n8n -n n8n --timeout=300s

echo "Rollback completed"
```

### Security Operations

#### Certificate Management
```bash
#!/bin/bash
# check-certificates.sh

echo "=== Certificate Status Check ==="

# Check certificate expiration
kubectl get certificates -n n8n

# Check certificate details
kubectl describe certificate n8n-tls -n n8n

# Verify SSL endpoint
echo | openssl s_client -connect n8n.example.com:443 2>/dev/null | openssl x509 -noout -dates
```

#### Security Scan
```bash
#!/bin/bash
# security-scan.sh

echo "=== Security Scan ==="

# Scan for vulnerabilities in images
trivy image n8nio/n8n:latest

# Check for exposed secrets
kubectl get secrets -n n8n -o json | jq -r '.items[] | select(.data != null) | .metadata.name'

# Verify network policies
kubectl get networkpolicies -n n8n
```

### Maintenance Windows

#### Planned Maintenance Procedure
1. **Pre-maintenance** (T-24 hours)
   - Notify users of maintenance window
   - Prepare rollback procedures
   - Verify backup integrity

2. **During maintenance** (T-0)
   - Set maintenance mode (if available)
   - Perform updates/changes
   - Run verification tests

3. **Post-maintenance** (T+1 hour)
   - Verify service functionality
   - Monitor for issues
   - Update stakeholders

#### Maintenance Checklist
```markdown
- [ ] Backup verification completed
- [ ] Change approval obtained
- [ ] Rollback procedure documented
- [ ] Monitoring dashboards ready
- [ ] Stakeholders notified
- [ ] Maintenance window started
- [ ] Changes applied
- [ ] Verification tests passed
- [ ] Service monitoring normal
- [ ] Stakeholders updated
- [ ] Post-maintenance review scheduled
```

## Troubleshooting Guides

### Common Issues

#### Issue: High CPU Usage
**Symptoms**: Slow response times, high CPU alerts
**Investigation**:
```bash
# Check top CPU consuming pods
kubectl top pods -n n8n --sort-by=cpu

# Check CPU usage over time
# Use Grafana dashboard: Node Exporter Full

# Check for runaway processes
kubectl exec -n n8n deployment/n8n -- top
```
**Resolution**:
1. Scale horizontally if needed
2. Optimize workflows
3. Increase resource limits

#### Issue: Database Connection Pool Exhaustion
**Symptoms**: Connection errors, timeouts
**Investigation**:
```bash
# Check active connections
kubectl exec -n n8n deployment/postgres -- psql -U n8n -d n8n -c "SELECT count(*) FROM pg_stat_activity;"

# Check connection pool settings
kubectl exec -n n8n deployment/n8n -- env | grep DB_
```
**Resolution**:
1. Increase connection pool size
2. Optimize query performance
3. Scale database if needed

#### Issue: Webhook Failures
**Symptoms**: Webhook timeout errors, failed executions
**Investigation**:
```bash
# Check NGINX logs
kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx

# Check n8n logs
kubectl logs deployment/n8n -n n8n

# Test webhook endpoint
curl -X POST https://n8n.example.com/webhook/test -d '{"test": true}'
```
**Resolution**:
1. Check network connectivity
2. Verify webhook configuration
3. Increase timeout settings

### Emergency Procedures

#### Complete Service Outage
1. **Immediate Actions**
   - Check infrastructure status (AWS, Kubernetes)
   - Verify DNS resolution
   - Check load balancer health

2. **Escalation Path**
   - Notify on-call engineer
   - Engage platform team
   - Contact AWS support if needed

3. **Recovery Steps**
   - Restore from backup if needed
   - Implement emergency fixes
   - Gradually restore traffic

#### Data Corruption
1. **Immediate Actions**
   - Stop all write operations
   - Isolate affected components
   - Preserve evidence for investigation

2. **Recovery Steps**
   - Restore from latest clean backup
   - Verify data integrity
   - Gradually restore service

## Performance Tuning

### Database Optimization
```sql
-- Check slow queries
SELECT query, mean_time, calls, total_time
FROM pg_stat_statements
ORDER BY total_time DESC
LIMIT 10;

-- Analyze table statistics
ANALYZE;

-- Check index usage
SELECT schemaname, tablename, attname, n_distinct, correlation
FROM pg_stats
WHERE tablename = 'workflow_execution';
```

### Application Tuning
```bash
# Increase worker processes
kubectl patch deployment n8n -n n8n -p '{"spec":{"template":{"spec":{"containers":[{"name":"n8n","env":[{"name":"N8N_WORKERS","value":"4"}]}]}}}}'

# Optimize memory settings
kubectl patch deployment n8n -n n8n -p '{"spec":{"template":{"spec":{"containers":[{"name":"n8n","resources":{"limits":{"memory":"2Gi"}}}]}}}}'
```

## Contact Information

### Team Contacts
- **Platform Team**: platform-team@example.com
- **DevOps Team**: devops@example.com
- **Security Team**: security@example.com

### Vendor Support
- **AWS Support**: Enterprise plan
- **n8n Support**: Community/Enterprise
- **MongoDB Support**: Professional

### Documentation Links
- **Internal Wiki**: https://wiki.example.com/flow
- **API Documentation**: https://api-docs.example.com
- **Architecture Diagrams**: https://diagrams.example.com/flow