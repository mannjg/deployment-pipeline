# ArgoCD HTTPS Configuration

This directory contains the ArgoCD configuration files for HTTPS access.

## Files

- `tls-secret.yaml` - TLS certificate secret for argocd.local
- `ingress.yaml` - Ingress configuration with HTTPS/TLS termination

## Access

**URL:** https://argocd.local

**Credentials:**
- Username: `admin`
- Password: Retrieved with:
  ```bash
  microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  ```

## Setup

The configuration uses:
- **TLS Termination** at ingress level (not SSL passthrough)
- **Self-signed certificate** for argocd.local
- **Backend protocol**: HTTPS (ArgoCD server runs with TLS)

### Apply Configuration

```bash
# Apply TLS secret
microk8s kubectl apply -f argocd/tls-secret.yaml

# Apply ingress
microk8s kubectl apply -f argocd/ingress.yaml
```

### Regenerate TLS Certificate

If you need to regenerate the self-signed certificate:

```bash
# Generate new certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/argocd-tls.key \
  -out /tmp/argocd-tls.crt \
  -subj "/CN=argocd.local/O=argocd" \
  -addext "subjectAltName=DNS:argocd.local"

# Update the secret
cat /tmp/argocd-tls.crt | base64 -w 0 > /tmp/cert.b64
cat /tmp/argocd-tls.key | base64 -w 0 > /tmp/key.b64

# Update tls-secret.yaml with the new base64 values
# Then apply: microk8s kubectl apply -f argocd/tls-secret.yaml
```

## Troubleshooting

### Certificate Warnings in Browser

Since this uses a self-signed certificate, browsers will show security warnings. This is expected for local development.

To avoid warnings, you can:
1. Accept the self-signed certificate in your browser
2. Add the certificate to your system's trusted certificates
3. Use a proper CA-signed certificate for production

### Test HTTPS Access

```bash
# Test with curl (accepting self-signed cert)
curl -k https://argocd.local

# Check certificate details
echo | openssl s_client -showcerts -servername argocd.local -connect argocd.local:443 2>/dev/null | openssl x509 -inform pem -noout -text
```
