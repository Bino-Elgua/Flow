# Flow Troubleshooting Guide

This guide provides solutions to common issues encountered with the Flow platform.

## Quick Diagnostic Commands

### System Status Overview
```bash
# Check all services
kubectl get pods --all-namespaces

# Check service endpoints
kubectl get endpoints -n n8n

# Check ingress status
kubectl get ingress -n n8n

# Check persistent volumes
kubectl get pv,pvc -n n8n
```

### Log Collection
```bash
# Collect all logs
kubectl logs deployment/n8n -n n8n --tail=100 > n8n.log
kubectl logs deployment/postgres -n n8n --tail=100 > postgres.log
kubectl logs deployment/redis -n n8n --tail=100 > redis.log
kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --tail=100 > nginx.log
```

## Application Issues

### n8n Application Problems

#### Issue: n8n Won't Start
**Symptoms**: 
- Pod in CrashLoopBackOff state
- Container restart count increasing
- Application not accessible

**Diagnostic Steps**:
```bash
# Check pod status and events
kubectl describe pod -l app.kubernetes.io/name=n8n -n n8n

# Check container logs
kubectl logs deployment/n8n -n n8n --previous

# Check resource constraints
kubectl top pods -n n8n
```

**Common Causes & Solutions**:

1. **Database Connection Issues**
   ```bash
   # Test database connectivity
   kubectl exec -it deployment/n8n -n n8n -- sh
   # Inside container:
   nc -zv postgres-service 5432
   ```
   **Solution**: Verify database credentials and network connectivity

2. **Insufficient Resources**
   ```bash
   # Check resource usage
   kubectl describe node
   ```
   **Solution**: Increase resource limits or add more nodes

3. **Configuration Errors**
   ```bash
   # Check environment variables
   kubectl exec deployment/n8n -n n8n -- env | grep N8N_
   ```
   **Solution**: Verify configuration in secrets and configmaps

#### Issue: Slow Performance
**Symptoms**:
- High response times
- Timeout errors
- Slow workflow execution

**Diagnostic Steps**:
```bash
# Check resource usage
kubectl top pods -n n8n

# Check database performance
kubectl exec -it deployment/postgres -n n8n -- psql -U n8n -d n8n -c "
SELECT query, mean_time, calls, total_time 
FROM pg_stat_statements 
ORDER BY total_time DESC 
LIMIT 10;"

# Check Redis performance
kubectl exec -it deployment/redis -n n8n -- redis-cli info stats
```

**Solutions**:
1. **Scale horizontally**: `kubectl scale deployment n8n --replicas=3 -n n8n`
2. **Increase resources**: Update deployment resource limits
3. **Optimize database**: Run `VACUUM ANALYZE` on PostgreSQL
4. **Clear Redis cache**: `kubectl exec deployment/redis -n n8n -- redis-cli FLUSHDB`

#### Issue: Workflows Not Executing
**Symptoms**:
- Workflows appear inactive
- Webhook triggers not working
- Manual executions fail

**Diagnostic Steps**:
```bash
# Check workflow status in database
kubectl exec -it deployment/postgres -n n8n -- psql -U n8n -d n8n -c "
SELECT id, name, active, created_at, updated_at 
FROM workflow_entity 
ORDER BY updated_at DESC 
LIMIT 10;"

# Check webhook endpoints
curl -X POST https://your-domain.com/webhook/test -d '{"test": true}'

# Check n8n logs for errors
kubectl logs deployment/n8n -n n8n | grep -i error
```

**Solutions**:
1. **Restart n8n service**: `kubectl rollout restart deployment/n8n -n n8n`
2. **Verify webhook URLs**: Check ingress configuration
3. **Check database connectivity**: Ensure database is accessible
4. **Verify credentials**: Check secret configurations

### Database Issues

#### Issue: PostgreSQL Connection Failures
**Symptoms**:
- "Connection refused" errors
- "Too many connections" errors
- Database pod not ready

**Diagnostic Steps**:
```bash
# Check PostgreSQL pod status
kubectl get pods -l app.kubernetes.io/name=postgres -n n8n

# Check PostgreSQL logs
kubectl logs deployment/postgres -n n8n

# Test connectivity
kubectl exec -it deployment/n8n -n n8n -- pg_isready -h postgres-service -p 5432 -U n8n
```

**Solutions**:

1. **Connection Pool Exhaustion**
   ```sql
   -- Check active connections
   SELECT count(*) FROM pg_stat_activity;
   
   -- Kill idle connections
   SELECT pg_terminate_backend(pid) 
   FROM pg_stat_activity 
   WHERE state = 'idle' AND query_start < now() - interval '5 minutes';
   ```

2. **Resource Constraints**
   ```bash
   # Check PostgreSQL resource usage
   kubectl top pod -l app.kubernetes.io/name=postgres -n n8n
   
   # Increase resources if needed
   kubectl patch statefulset postgres -n n8n -p '{"spec":{"template":{"spec":{"containers":[{"name":"postgres","resources":{"limits":{"memory":"1Gi"}}}]}}}}'
   ```

3. **Storage Issues**
   ```bash
   # Check PVC status
   kubectl get pvc -n n8n
   
   # Check available disk space
   kubectl exec deployment/postgres -n n8n -- df -h
   ```

#### Issue: Database Performance Problems
**Symptoms**:
- Slow query execution
- High CPU usage on database pod
- Application timeouts

**Diagnostic Steps**:
```sql
-- Connect to database
kubectl exec -it deployment/postgres -n n8n -- psql -U n8n -d n8n

-- Check slow queries
SELECT query, mean_time, calls, total_time 
FROM pg_stat_statements 
ORDER BY mean_time DESC 
LIMIT 10;

-- Check table sizes
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Check index usage
SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes 
ORDER BY idx_scan DESC;
```

**Solutions**:
1. **Optimize Queries**: Add missing indexes
2. **Database Maintenance**: Run `VACUUM ANALYZE`
3. **Increase Resources**: Scale up database instance
4. **Connection Pooling**: Implement connection pooling

### Redis Issues

#### Issue: Redis Connection Failures
**Symptoms**:
- "Connection refused" to Redis
- Queue processing failures
- Session storage issues

**Diagnostic Steps**:
```bash
# Check Redis pod status
kubectl get pods -l app.kubernetes.io/name=redis -n n8n

# Test Redis connectivity
kubectl exec -it deployment/redis -n n8n -- redis-cli ping

# Check Redis logs
kubectl logs deployment/redis -n n8n

# Check Redis configuration
kubectl exec deployment/redis -n n8n -- redis-cli config get "*"
```

**Solutions**:

1. **Redis Not Responding**
   ```bash
   # Restart Redis pod
   kubectl delete pod -l app.kubernetes.io/name=redis -n n8n
   
   # Check Redis memory usage
   kubectl exec deployment/redis -n n8n -- redis-cli info memory
   ```

2. **Memory Issues**
   ```bash
   # Clear Redis cache
   kubectl exec deployment/redis -n n8n -- redis-cli FLUSHDB
   
   # Increase Redis memory limit
   kubectl patch deployment redis -n n8n -p '{"spec":{"template":{"spec":{"containers":[{"name":"redis","resources":{"limits":{"memory":"512Mi"}}}]}}}}'
   ```

## Infrastructure Issues

### Kubernetes Cluster Problems

#### Issue: Pods Stuck in Pending State
**Symptoms**:
- Pods not scheduling
- "Insufficient resources" events
- Cluster nodes at capacity

**Diagnostic Steps**:
```bash
# Check pod events
kubectl describe pod <pod-name> -n n8n

# Check node resources
kubectl describe nodes

# Check node capacity
kubectl top nodes
```

**Solutions**:
1. **Add More Nodes**: Scale EKS node group
2. **Optimize Resources**: Reduce resource requests
3. **Clean Up**: Remove unused pods and resources

#### Issue: Network Connectivity Problems
**Symptoms**:
- Service discovery failures
- Intermittent connection issues
- DNS resolution problems

**Diagnostic Steps**:
```bash
# Check service endpoints
kubectl get endpoints -n n8n

# Test DNS resolution
kubectl exec -it deployment/n8n -n n8n -- nslookup postgres-service

# Check network policies
kubectl get networkpolicies -n n8n

# Test connectivity between pods
kubectl exec -it deployment/n8n -n n8n -- nc -zv postgres-service 5432
```

**Solutions**:
1. **Verify Service Configuration**: Check service selectors
2. **Update Network Policies**: Ensure proper traffic flow
3. **Restart CoreDNS**: `kubectl rollout restart deployment/coredns -n kube-system`

### Storage Issues

#### Issue: Persistent Volume Problems
**Symptoms**:
- Pods can't mount volumes
- Data persistence failures
- Storage capacity issues

**Diagnostic Steps**:
```bash
# Check PVC status
kubectl get pvc -n n8n

# Check PV status
kubectl get pv

# Check storage class
kubectl get storageclass

# Check volume mount issues
kubectl describe pod <pod-name> -n n8n
```

**Solutions**:
1. **Resize PVC**: Increase storage size
2. **Fix Permissions**: Check volume ownership
3. **Storage Class Issues**: Verify storage class configuration

## Networking Issues

### Ingress Problems

#### Issue: External Access Failures
**Symptoms**:
- 404 errors from external requests
- SSL certificate problems
- Routing issues

**Diagnostic Steps**:
```bash
# Check ingress status
kubectl get ingress -n n8n

# Check ingress controller logs
kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx

# Check SSL certificates
kubectl get certificates -n n8n

# Test external connectivity
curl -I https://your-domain.com
```

**Solutions**:

1. **DNS Issues**
   ```bash
   # Check DNS resolution
   nslookup your-domain.com
   
   # Verify DNS configuration in domain registrar
   ```

2. **Certificate Problems**
   ```bash
   # Check certificate status
   kubectl describe certificate n8n-tls -n n8n
   
   # Force certificate renewal
   kubectl delete certificate n8n-tls -n n8n
   kubectl apply -f k8s/ingress-nginx.yaml
   ```

3. **Load Balancer Issues**
   ```bash
   # Check load balancer status
   kubectl get service -n ingress-nginx
   
   # Check AWS Load Balancer (if using ELB)
   aws elbv2 describe-load-balancers
   ```

### SSL/TLS Issues

#### Issue: Certificate Errors
**Symptoms**:
- SSL handshake failures
- Certificate expiration warnings
- Mixed content errors

**Diagnostic Steps**:
```bash
# Check certificate details
echo | openssl s_client -connect your-domain.com:443 2>/dev/null | openssl x509 -noout -text

# Check cert-manager logs
kubectl logs -l app=cert-manager -n cert-manager

# Verify certificate in Kubernetes
kubectl get certificates -n n8n -o yaml
```

**Solutions**:
1. **Renew Certificates**: Delete and recreate certificate resources
2. **Check DNS**: Verify domain ownership for Let's Encrypt
3. **Update Configuration**: Fix certificate issuer configuration

## Monitoring Issues

### Prometheus Problems

#### Issue: Metrics Not Collected
**Symptoms**:
- Missing metrics in Grafana
- Prometheus targets down
- Alert notifications not working

**Diagnostic Steps**:
```bash
# Check Prometheus targets
kubectl port-forward svc/prometheus 9090:9090 -n monitoring
# Navigate to http://localhost:9090/targets

# Check Prometheus configuration
kubectl get configmap prometheus-config -n monitoring -o yaml

# Check service discovery
kubectl get endpoints -n n8n
```

**Solutions**:
1. **Fix Service Annotations**: Add Prometheus scraping annotations
2. **Update Configuration**: Fix Prometheus scrape configs
3. **Restart Prometheus**: `kubectl rollout restart deployment/prometheus -n monitoring`

### Grafana Issues

#### Issue: Dashboard Loading Problems
**Symptoms**:
- Dashboards not loading
- Data source connection errors
- Authentication issues

**Diagnostic Steps**:
```bash
# Check Grafana logs
kubectl logs deployment/grafana -n monitoring

# Check data source configuration
kubectl port-forward svc/grafana 3000:3000 -n monitoring
# Navigate to http://localhost:3000

# Check Grafana configuration
kubectl get configmap grafana-config -n monitoring -o yaml
```

**Solutions**:
1. **Fix Data Sources**: Update Prometheus URL
2. **Restart Grafana**: `kubectl rollout restart deployment/grafana -n monitoring`
3. **Import Dashboards**: Re-import dashboard configurations

## Performance Issues

### High Resource Usage

#### Issue: High Memory Consumption
**Symptoms**:
- Out of memory errors
- Pod evictions
- Performance degradation

**Diagnostic Steps**:
```bash
# Check memory usage
kubectl top pods --all-namespaces --sort-by=memory

# Check memory limits
kubectl describe pod <pod-name> -n n8n

# Check node memory
kubectl top nodes
```

**Solutions**:
1. **Increase Memory Limits**: Update deployment resources
2. **Optimize Application**: Review memory usage patterns
3. **Scale Horizontally**: Add more replicas
4. **Add Nodes**: Scale cluster if needed

#### Issue: High CPU Usage
**Symptoms**:
- Slow response times
- CPU throttling
- High load averages

**Diagnostic Steps**:
```bash
# Check CPU usage
kubectl top pods --all-namespaces --sort-by=cpu

# Check CPU limits
kubectl describe pod <pod-name> -n n8n

# Check processes inside container
kubectl exec -it deployment/n8n -n n8n -- top
```

**Solutions**:
1. **Increase CPU Limits**: Update resource configurations
2. **Optimize Code**: Profile application performance
3. **Scale Out**: Add more replicas
4. **Load Balance**: Distribute load across instances

## Security Issues

### Authentication Problems

#### Issue: Login Failures
**Symptoms**:
- Cannot access n8n interface
- Authentication errors
- Session timeouts

**Diagnostic Steps**:
```bash
# Check authentication configuration
kubectl get secret n8n-secrets -n n8n -o yaml

# Check n8n logs for auth errors
kubectl logs deployment/n8n -n n8n | grep -i auth

# Test authentication
curl -u admin:password https://your-domain.com/api/v1/workflows
```

**Solutions**:
1. **Verify Credentials**: Check secret configuration
2. **Reset Password**: Update authentication secrets
3. **Check Configuration**: Verify auth settings in n8n config

### Certificate Security

#### Issue: SSL Security Warnings
**Symptoms**:
- Browser security warnings
- Certificate validation errors
- Mixed content issues

**Diagnostic Steps**:
```bash
# Check SSL configuration
openssl s_client -connect your-domain.com:443 -showcerts

# Check certificate chain
kubectl get certificate n8n-tls -n n8n -o yaml

# Verify NGINX configuration
kubectl get configmap nginx-config -o yaml
```

**Solutions**:
1. **Update Certificates**: Ensure proper certificate chain
2. **Fix NGINX Config**: Update SSL configuration
3. **Verify DNS**: Ensure proper domain validation

## Recovery Procedures

### Service Recovery

#### Complete Service Restoration
```bash
#!/bin/bash
# service-recovery.sh

echo "Starting service recovery..."

# Check cluster status
kubectl cluster-info

# Restart all services in order
kubectl rollout restart deployment/postgres -n n8n
kubectl rollout status deployment/postgres -n n8n

kubectl rollout restart deployment/redis -n n8n
kubectl rollout status deployment/redis -n n8n

kubectl rollout restart deployment/n8n -n n8n
kubectl rollout status deployment/n8n -n n8n

# Verify service health
sleep 30
curl -f https://your-domain.com/healthz || echo "Health check failed"

echo "Service recovery completed"
```

### Data Recovery

#### Database Recovery from Backup
```bash
#!/bin/bash
# database-recovery.sh

BACKUP_FILE=${1:-latest}

echo "Starting database recovery from backup: $BACKUP_FILE"

# Scale down n8n to prevent writes
kubectl scale deployment n8n --replicas=0 -n n8n

# Restore database
kubectl exec -i deployment/postgres -n n8n -- psql -U n8n -d n8n < $BACKUP_FILE

# Scale up n8n
kubectl scale deployment n8n --replicas=2 -n n8n

echo "Database recovery completed"
```

## Emergency Contacts

### Escalation Procedures
1. **Level 1**: On-call engineer (immediate response)
2. **Level 2**: Platform team lead (15 minutes)
3. **Level 3**: Engineering manager (30 minutes)
4. **Level 4**: VP Engineering (1 hour)

### Contact Information
- **On-call**: +1-555-ON-CALL
- **Platform Team**: platform-team@example.com
- **DevOps**: devops@example.com
- **Security**: security-team@example.com

### External Support
- **AWS Support**: Enterprise plan
- **Kubernetes Support**: Community/Enterprise
- **n8n Support**: Community/Enterprise

## Prevention and Best Practices

### Monitoring Best Practices
1. Set up comprehensive alerting
2. Monitor key performance indicators
3. Regular health checks
4. Capacity planning

### Operational Best Practices
1. Regular backups and testing
2. Documentation updates
3. Change management procedures
4. Incident post-mortems

### Security Best Practices
1. Regular security audits
2. Keep software updated
3. Monitor for vulnerabilities
4. Access control reviews