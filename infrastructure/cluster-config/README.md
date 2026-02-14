# Cluster Configuration

This directory contains optional cluster-specific configuration files.

## Prerequisites

This project is **Kubernetes distribution-agnostic**. It works with:
- MicroK8s
- kind (Kubernetes in Docker)
- k3s
- minikube
- EKS, GKE, AKS, or any managed Kubernetes
- Any other conformant Kubernetes cluster

**You are responsible for:**
1. Installing and configuring your Kubernetes cluster
2. Ensuring `kubectl` is configured to access your cluster
3. Adjusting storage classes and ingress as needed for your distribution

## Verification

Before running any scripts, verify kubectl access:

```bash
# Check cluster access
kubectl cluster-info

# List nodes
kubectl get nodes

# Test namespace creation
kubectl create namespace test-ns
kubectl delete namespace test-ns
```

## Files

- `kubeconfig` - Optional kubeconfig file (not committed to git)
- `README.md` - This file

## Distribution-Specific Notes

### Storage Classes

The default Jenkins Helm values use `microk8s-hostpath`. Update `infrastructure/jenkins/values.yaml` if your cluster uses a different storage class:

```bash
# List available storage classes
kubectl get storageclass

# Common storage classes by distribution:
# - microk8s: microk8s-hostpath
# - kind: standard
# - k3s: local-path
# - minikube: standard
# - EKS: gp2, gp3
# - GKE: standard, premium-rwo
```

### Ingress Controllers

This project expects an ingress controller. Install one appropriate for your distribution:

```bash
# Verify ingress controller is running
kubectl get pods -n ingress-nginx  # or your ingress namespace
kubectl get ingressclass
```

### Local Domain Resolution

Add to `/etc/hosts` (pointing to your cluster's ingress IP):
```
127.0.0.1  gitlab.jmann.local jenkins.jmann.local nexus.jmann.local argocd.jmann.local docker.jmann.local
```

## Troubleshooting

### kubectl not connecting

```bash
# Check current context
kubectl config current-context

# List available contexts
kubectl config get-contexts

# Switch context
kubectl config use-context <context-name>
```

### Storage issues

```bash
# Check PVC status
kubectl get pvc -A

# Describe stuck PVC
kubectl describe pvc <name> -n <namespace>
```

### DNS not resolving

```bash
# Check CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test DNS resolution from within cluster
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default
```
