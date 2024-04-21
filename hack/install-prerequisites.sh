#!/bin/bash
# Enable debugging mode
set -x

# Default values
DEFAULT_NAMESPACE="capi-operator-system"
DEFAULT_PROVIDER="aws"

NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
PROVIDER="${PROVIDER:-$DEFAULT_PROVIDER}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -n, --namespace NAME     Specify the namespace for the Operator (default: $DEFAULT_NAMESPACE)"
    echo "  -p, --provider PROVIDER  Specify the provider for the Operator (default: $DEFAULT_PROVIDER)"
    echo "  -h, --help               Display this help message"
}

check_tool() {
    local name=$1
    if ! command -v "${name}" &> /dev/null; then
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



setup_aws_credential() {
    read -p "Enter AWS_ACCESS_KEY_ID: " AWS_ACCESS_KEY_ID
    export AWS_ACCESS_KEY_ID

    read -p "Enter AWS_SECRET_ACCESS_KEY: " AWS_SECRET_ACCESS_KEY
    export AWS_SECRET_ACCESS_KEY
    
    read -p "Enter REGION: " AWS_REGION
    export AWS_REGION 

    echo "AWS credentials set."
}

check_aws_credentials() {
    if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" && -n "$AWS_REGION" ]]; then
        echo "AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_REGION are all set."
    elif [ -n "$AWS_PROFILE" ]; then
        current_profile="$AWS_PROFILE"
        echo "Current AWS profile: $current_profile"

        read -p "Do you want to use the current profile? (yes/no): " use_current_profile
        if [ "$use_current_profile" == "yes" ]; then
            AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id --profile "$current_profile")
            export AWS_ACCESS_KEY_ID

            AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key --profile "$current_profile")
            export AWS_SECRET_ACCESS_KEY

            AWS_REGION=$(aws configure get region --profile "$current_profile")
            export AWS_REGION

            echo "AWS credentials set from profile: $current_profile"
        else
            setup_aws_credential
        fi
    else
        echo "No AWS profile is currently set."
        setup_aws_credential
    fi
}

check_operator_ready() {
    if kubectl get infrastructureproviders --namespace aws-infrastructure-system | awk '$3 == "True" && $1 == "aws" ' >/dev/null 2>&1; then
        echo "Operator deployment is ready."
        return 0
    else
        echo "Waiting for Operator deployment to be ready..."
        return 1
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

check_tool "kubectl"

check_tool "helm"

check_k8s_cluster

case "${PROVIDER}" in
    "aws")
        check_tool "clusterawsadm"
        if [$? -eq 1]; then
            echo "Installing clusterawsadm..."
            curl -L https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download/v0.0.0/clusterawsadm-linux-amd64 -o ./bin/clusterawsadm
            chmod +x clusterawsadm
            CLUSTERAWSADM=./bin/clusterawsadm
        else
            CLUSTERAWSADM=clusterawsadm
        fi

        check_aws_credentials
        clusterawsadm bootstrap iam create-cloudformation-stack
        export AWS_B64ENCODED_CREDENTIALS=$(clusterawsadm bootstrap credentials encode-as-profile)
    ;;
    *)
        echo "We have not support the ${PROVIDER} provider yet"
        exit 1
    ;;
esac

export EXP_CLUSTER_RESOURCE_SET=true
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

helm install "$CAPI_HELM_REPO_NAME" capi-operator/cluster-api-operator --create-namespace -n ${NAMESPACE} --set infrastructure=${PROVIDER}:v2.1.4 --set cert-manager.enabled=true --set configSecret.name=${CREDENTIALS_SECRET_NAME} --set configSecret.namespace=${CREDENTIALS_SECRET_NAMESPACE}  --wait


# Main
echo "Installing Operator..."
if check_operator_ready; then
    exit 0
fi
