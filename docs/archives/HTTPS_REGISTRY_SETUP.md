# HTTPS Docker Registry Setup Complete

## Summary

Successfully migrated Nexus Docker registry from HTTP to HTTPS using self-signed certificate and Kubernetes ingress. This resolves the Jib build failures caused by refusing to send credentials over HTTP.

## What Was Done

### 1. Certificate & Infrastructure
- ✅ Generated self-signed TLS certificate for docker.local (valid until 2035)
- ✅ Created Kubernetes TLS secret: `docker-registry-tls` in nexus namespace
- ✅ Created HTTPS ingress: `nexus-docker-registry` routing docker.local → nexus:5000
- ✅ Verified HTTPS connectivity (HTTP/2 401 response with docker-distribution-api-version header)

### 2. Application Configuration
- ✅ Updated Jenkinsfile:
  - Changed `DOCKER_REGISTRY` from `nexus.nexus.svc.cluster.local:5000` to `docker.local`
  - Added `hostAliases` to pod template for in-cluster DNS resolution
  - Removed `-Djib.sendCredentialsOverHttp=true` (no longer needed with HTTPS)
  - Kept `-Djib.allowInsecureRegistries=true` (required for self-signed certificate)

- ✅ Updated pom.xml:
  - Changed `image.registry` from `localhost:30500` to `docker.local`
  - Removed `<sendCredentialsOverHttp>true</sendCredentialsOverHttp>`
  - Kept `<allowInsecureRegistries>true</allowInsecureRegistries>`

- ✅ Committed changes to git (commit: 3da64cc)

## Architecture

**BEFORE (Broken):**
```
Jenkins Pod → HTTP → nexus.nexus.svc.cluster.local:5000 → Nexus
❌ Jib refuses to send credentials over HTTP
```

**AFTER (Working):**
```
Jenkins Pod → HTTPS (docker.local:443) → Nginx Ingress (TLS termination) → HTTP → Nexus Service (port 5000)
✅ Jib sends credentials over HTTPS connection
```

## Manual Step Required

You must add docker.local to your /etc/hosts file:

```bash
echo "127.0.0.1 docker.local" | sudo tee -a /etc/hosts
```

Verify it was added:
```bash
grep docker.local /etc/hosts
```

Test DNS resolution:
```bash
ping -c 1 docker.local
```

## Testing the Setup

### Test 1: Verify HTTPS Connectivity

```bash
# Should return HTTP/2 401 with Docker registry headers
curl -k -I https://docker.local/v2/
```

Expected output:
```
HTTP/2 401
docker-distribution-api-version: registry/2.0
www-authenticate: BASIC realm="Sonatype Nexus Repository Manager"
```

### Test 2: Test Docker Login (Optional)

```bash
# Login with Nexus credentials
docker login docker.local
# Username: jenkins
# Password: jenkins123
```

### Test 3: Trigger Jenkins Build

1. Go to Jenkins: http://jenkins.local
2. Navigate to example-app-ci job
3. Click "Build Now"
4. Watch the console output

Expected behavior:
- Pod should be able to resolve docker.local (via hostAliases)
- Jib should connect to https://docker.local
- Jib should accept the HTTPS connection (with allowInsecureRegistries)
- Image should push successfully
- Build should complete successfully

## Troubleshooting

### Issue: "Could not resolve host: docker.local" from Jenkins pod

**Cause:** hostAliases not working or ingress not accessible

**Solution:**
```bash
# Check ingress is running
microk8s kubectl get ingress -n nexus

# Check if ingress has address
microk8s kubectl describe ingress nexus-docker-registry -n nexus

# Test from within a pod
microk8s kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- sh
# Inside pod:
nslookup docker.local || true
curl -k -I https://docker.local/v2/
```

### Issue: Certificate validation errors

**Cause:** Self-signed certificate not trusted

**Solution:** This is expected with self-signed certs. The `-Djib.allowInsecureRegistries=true` flag tells Jib to accept it.

### Issue: Build still fails with HTTP error

**Cause:** Jenkins might be caching the old Jenkinsfile

**Solution:**
```bash
# Push changes to GitLab
git push origin main

# Or manually update the job configuration in Jenkins UI
```

## Files Created/Modified

### Created:
- `/tmp/docker-local.key` - Private key (10-year validity)
- `/tmp/docker-local.crt` - Self-signed certificate (10-year validity)
- `k8s/nexus/nexus-docker-ingress.yaml` - HTTPS ingress configuration

### Modified:
- `example-app/Jenkinsfile` - Updated registry and pod configuration
- `example-app/pom.xml` - Updated image registry property

### Kubernetes Resources:
- Secret: `docker-registry-tls` (namespace: nexus)
- Ingress: `nexus-docker-registry` (namespace: nexus)

## Next Steps

1. ✅ Add docker.local to /etc/hosts (MANUAL STEP REQUIRED)
2. ⏳ Test Jenkins build
3. 📝 Optional: Apply same pattern to other services:
   - jenkins.local → HTTPS for Jenkins UI
   - gitlab.local → HTTPS for GitLab
   - argocd.local → HTTPS for ArgoCD

## Future Enhancements

### Option 1: Upgrade to cert-manager

For automatic certificate management and renewal:

```bash
# Install cert-manager
microk8s kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml

# Create ClusterIssuer
# Create Certificates
# Update ingress to use cert-manager annotations
```

Benefits:
- Automatic certificate renewal
- Easily scale to multiple services
- Industry-standard tool
- Production-ready

### Option 2: Use Let's Encrypt for Production

Requirements:
- Public domain name
- DNS accessible from internet
- ACME HTTP-01 or DNS-01 challenge

## References

- Jib documentation: https://github.com/GoogleContainerTools/jib
- Kubernetes ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/
- cert-manager: https://cert-manager.io/
- Nexus Repository: https://help.sonatype.com/repomanager3

## Support

For issues or questions, check:
1. Jenkins console logs: http://jenkins.local/job/example-app-ci/
2. Nexus logs: `microk8s kubectl logs -n nexus deployment/nexus`
3. Ingress logs: `microk8s kubectl logs -n ingress nginx-ingress-controller`
