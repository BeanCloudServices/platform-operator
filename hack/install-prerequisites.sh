#!/bin/bash

# Default values
DEFAULT_NAMESPACE="capi-operator-system"
DEFAULT_PROVIDER="aws"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -n, --namespace NAME     Specify the namespace for the Operator (default: $DEFAULT_NAMESPACE)"
    echo "  -p, --provider PROVIDER  Specify the provider for the Operator (default: $DEFAULT_PROVIDER)"
    echo "  -h, --help               Display this help message"
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed or not in PATH."
        exit 1
    fi
}

check_helm() {
    if ! command -v helm &> /dev/null; then
        echo "Error: Helm is not installed or not in PATH."
        exit 1
    fi
}

check_k8s_cluster() {
    if ! kubectl cluster-info &> /dev/null; then
        echo "Error: Unable to connect to Kubernetes cluster."
        exit 1
    fi
}

check_b64encoded_credentials() {
    if [ -z "${B64ENCODED_CREDENTIALS}" ]; then
        echo "Error: Environment variable B64ENCODED_CREDENTIALS is not exported.\nPlease get the encoded base64 credentials of your provider in https://cluster-api.sigs.k8s.io/user/quick-start#initialization-for-common-providers"
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        -n|--namespace)
        NAMESPACE="$2"
        shift 
        shift 
        ;;
        -p|--provider)
        PROVIDER="$2"
        shift
        shift 
        ;;
        -h|--help)
        usage
        exit 0
        ;;
        *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
done

check_kubectl

check_b64encoded_credentials

check_helm

check_k8s_cluster

NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
PROVIDER="${PROVIDER:-$DEFAULT_PROVIDER}"

export CREDENTIALS_SECRET_NAME="credentials-secret"
export CREDENTIALS_SECRET_NAMESPACE="default"

if kubectl get secret "$CREDENTIALS_SECRET_NAME" -n "$CREDENTIALS_SECRET_NAMESPACE" > /dev/null 2>&1; then
    echo "Secret '$CREDENTIALS_SECRET_NAME' exists."
else
    echo "Creating secret '$CREDENTIALS_SECRET_NAME' in namespace '$CREDENTIALS_SECRET_NAMESPACE..."
    kubectl create secret generic "${CREDENTIALS_SECRET_NAME}" --from-literal=AWS_B64ENCODED_CREDENTIALS="${B64ENCODED_CREDENTIALS}" --namespace "${CREDENTIALS_SECRET_NAMESPACE}"
fi

# Install Cluster API operator
CAPI_HELM_REPO_NAME="capi-operator"

# Run helm repo list command and check if the repository exists
if helm repo list | grep -q "$CAPI_HELM_REPO_NAME"; then
    echo "Repository '$CAPI_HELM_REPO_NAME' is added in Helm."
else
    echo "Adding '$CAPI_HELM_REPO_NAME' repo to helm..."
    helm repo add "$CAPI_HELM_REPO_NAME" https://kubernetes-sigs.github.io/cluster-api-operator
    helm repo update
fi

helm install "$CAPI_HELM_REPO_NAME" capi-operator/cluster-api-operator --create-namespace -n ${NAMESPACE} --set infrastructure=${PROVIDER} --set cert-manager.enabled=true --set configSecret.name=${CREDENTIALS_SECRET_NAME} --set configSecret.namespace=${CREDENTIALS_SECRET_NAMESPACE}  --wait

check_operator_ready() {
    local operator=$(kubectl get infrastructureproviders -A -o=jsonpath='{.items[*].metadata.name}')
    
    if [[ $operator == *aws* ]]; then
        echo "Operator deployment is ready."
        return 0
    else
        echo "Waiting for Operator deployment to be ready..."
        return 1
    fi
}

# Main
echo "Installing Operator..."
if check_operator_ready; then
    return 0
fi
