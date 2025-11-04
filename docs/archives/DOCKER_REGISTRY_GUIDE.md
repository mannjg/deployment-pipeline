# Nexus Docker Registry - Quick Reference

## 🔧 Initial Setup (ONE-TIME)

### 1. Enable Docker Bearer Token Realm

⚠️ **IMPORTANT**: This must be done before the Docker registry will work!

1. Login to Nexus: http://nexus.local
2. Username: `admin` / Password: `admin123`
3. Go to: **Settings** (gear icon) → **Security** → **Realms**
4. Move **"Docker Bearer Token Realm"** from Available to Active
5. Click **Save**

### 2. Configure Insecure Registry (Optional for localhost)

If using localhost:30500, add to `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["localhost:30500", "localhost:5000", "nexus.local:5000"]
}
```

Then restart Docker:
```bash
sudo systemctl restart docker
```

---

## 📍 Registry Access Points

### From Your Host Machine

| Method | Address | Use Case | Persistent? |
|--------|---------|----------|-------------|
| **NodePort** | `localhost:30500` | Primary access | ✅ Yes |
| **Port-Forward** | `localhost:5000` | Temporary testing | ❌ No |

### From Inside Kubernetes

| Address | Use Case |
|---------|----------|
| `nexus.local:5000` | Jenkins builds, pod pulls |
| `nexus.nexus.svc.cluster.local:5000` | Full DNS name |

---

## 🚀 Quick Start

### Using the Helper Script

```bash
# Check status
./scripts/docker-registry-helper.sh status

# Login to registry
./scripts/docker-registry-helper.sh login

# Test connectivity
./scripts/docker-registry-helper.sh test

# Start port-forward (if needed)
./scripts/docker-registry-helper.sh forward

# Push an image
./scripts/docker-registry-helper.sh push myimage:tag
```

### Manual Commands

**Login to Registry:**
```bash
# Via NodePort (persistent)
docker login localhost:30500 -u admin -p admin123

# Via port-forward (temporary)
docker login localhost:5000 -u admin -p admin123
```

**Tag and Push Image:**
```bash
# Tag image
docker tag myapp:latest localhost:30500/myapp:latest

# Push to registry
docker push localhost:30500/myapp:latest
```

**Pull Image:**
```bash
# From host
docker pull localhost:30500/myapp:latest

# From inside cluster (use in pod specs)
# image: nexus.local:5000/myapp:latest
```

---

## 🔍 Troubleshooting

### Connection Refused

**Symptom:** `connection refused` when trying to connect

**Solutions:**

1. **Check if Docker Bearer Token Realm is enabled** (see Initial Setup)

2. **Verify Nexus is running:**
   ```bash
   microk8s kubectl get pods -n nexus
   ```

3. **Check services:**
   ```bash
   microk8s kubectl get svc -n nexus
   ```

4. **Test registry endpoint:**
   ```bash
   # Via NodePort
   curl http://localhost:30500/v2/

   # Should return: {"errors":[{"code":"UNAUTHORIZED"...]}
   # This is GOOD - it means registry is responding
   ```

5. **If NodePort doesn't work, use port-forward:**
   ```bash
   microk8s kubectl port-forward -n nexus svc/nexus 5000:5000
   # Then use localhost:5000
   ```

### Unauthorized Errors

**Symptom:** `unauthorized: authentication required`

**Solution:** Login first:
```bash
docker login localhost:30500 -u admin -p admin123
```

### Cannot Push to Registry

**Symptom:** `denied: deployment to Docker hosted` or similar

**Solutions:**

1. **Check Docker Bearer Token Realm is enabled**

2. **Verify repository exists:**
   - Go to: http://nexus.local → Browse → docker-hosted

3. **Check Nexus logs:**
   ```bash
   microk8s kubectl logs -n nexus -l app=nexus --tail=50
   ```

### Insecure Registry Error

**Symptom:** `http: server gave HTTP response to HTTPS client`

**Solution:** Configure Docker to allow insecure registries:

Edit `/etc/docker/daemon.json`:
```json
{
  "insecure-registries": ["localhost:30500", "localhost:5000", "nexus.local:5000"]
}
```

Restart Docker:
```bash
sudo systemctl restart docker
```

---

## 📋 Common Tasks

### Push Jenkins Agent Image

```bash
# Login
docker login localhost:30500 -u admin -p admin123

# Tag the image
docker tag jenkins-agent-custom:latest localhost:30500/jenkins-agent-custom:latest

# Push to registry
docker push localhost:30500/jenkins-agent-custom:latest

# Verify
curl -u admin:admin123 http://localhost:30500/v2/jenkins-agent-custom/tags/list
```

### List Images in Registry

```bash
# Via API
curl -u admin:admin123 http://localhost:30500/v2/_catalog

# Via Nexus UI
# http://nexus.local → Browse → docker-hosted
```

### Pull Image from Registry

```bash
# From host
docker pull localhost:30500/myimage:tag

# Update Kubernetes manifest
# image: nexus.local:5000/myimage:tag
```

### Delete Image from Registry

Cannot be done via Docker CLI. Use Nexus UI:
1. Go to: http://nexus.local
2. Browse → docker-hosted → Select image
3. Delete Component

---

## 🐛 Debugging

### Check Registry Connectivity from Pod

```bash
# Run test pod
microk8s kubectl run -n nexus test-curl --rm -i --restart=Never \
  --image=curlimages/curl:latest \
  -- curl -v http://nexus.nexus.svc.cluster.local:5000/v2/

# Should see HTTP 401 (Unauthorized) - this is good!
```

### Check Nexus Logs

```bash
# Full logs
microk8s kubectl logs -n nexus -l app=nexus

# Follow logs
microk8s kubectl logs -n nexus -l app=nexus -f

# Last 50 lines
microk8s kubectl logs -n nexus -l app=nexus --tail=50
```

### Restart Nexus

```bash
microk8s kubectl rollout restart deployment -n nexus nexus
```

### Check Port Forwarding Status

```bash
# Check if port-forward is running
ps aux | grep "kubectl port-forward.*nexus"

# Test port-forward endpoint
curl http://localhost:5000/v2/
```

---

## 📊 Registry Status Check

Run this comprehensive test:

```bash
./scripts/docker-registry-helper.sh test
```

Or manually:

```bash
# 1. Check pod
microk8s kubectl get pods -n nexus

# 2. Check services
microk8s kubectl get svc -n nexus

# 3. Test NodePort
curl http://localhost:30500/v2/

# 4. Test port-forward (if running)
curl http://localhost:5000/v2/

# 5. Login test
docker login localhost:30500 -u admin -p admin123

# 6. List repositories
curl -u admin:admin123 http://localhost:30500/v2/_catalog
```

---

## 🔐 Credentials

| Item | Value |
|------|-------|
| Username | `admin` |
| Password | `admin123` |
| Registry URL (host) | `localhost:30500` |
| Registry URL (cluster) | `nexus.local:5000` |

---

## 📝 Configuration Files

### Nexus Service (with NodePort)
Location: `k8s/nexus/nexus-docker-nodeport.yaml`

### Helper Script
Location: `scripts/docker-registry-helper.sh`

### Docker Daemon Config
Location: `/etc/docker/daemon.json` (on your machine)

---

## ✅ Verification Checklist

Before using the Docker registry, verify:

- [ ] Nexus pod is running: `microk8s kubectl get pods -n nexus`
- [ ] NodePort service exists: `microk8s kubectl get svc -n nexus nexus-docker`
- [ ] Docker Bearer Token Realm is enabled (via Nexus UI)
- [ ] Can access registry: `curl http://localhost:30500/v2/`
- [ ] Can login: `docker login localhost:30500 -u admin -p admin123`
- [ ] Can list repos: `curl -u admin:admin123 http://localhost:30500/v2/_catalog`

---

## 🎯 For CI/CD Pipeline

### From Jenkins (inside cluster)

Use `nexus.local:5000` in:
- Jenkinsfile Docker commands
- Maven pom.xml Jib configuration
- Kubernetes pod specs

### From Host (testing)

Use `localhost:30500` for:
- Local Docker builds
- Pushing test images
- Manual verification

---

**Quick Links:**
- Nexus UI: http://nexus.local
- Registry Helper: `./scripts/docker-registry-helper.sh help`
- Troubleshooting: See this guide or `/home/jmann/git/mannjg/deployment-pipeline/docs/TROUBLESHOOTING.md`
