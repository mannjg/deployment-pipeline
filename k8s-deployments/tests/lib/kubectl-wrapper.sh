#!/bin/bash
# Kubectl wrapper that handles both kubectl and microk8s kubectl

# Export kubectl command for use in tests
if command -v kubectl &> /dev/null; then
    export KUBECTL_CMD="kubectl"
elif command -v microk8s &> /dev/null; then
    export KUBECTL_CMD="microk8s kubectl"
else
    export KUBECTL_CMD="kubectl"
fi

# Helper function to run kubectl
k() {
    $KUBECTL_CMD "$@"
}

export -f k
