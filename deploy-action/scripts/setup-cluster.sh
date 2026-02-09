#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

handle_error() {
    local exit_code=$1
    local error_message=$2
    
    if [ $exit_code -ne 0 ]; then
        print_error "$error_message"
        echo "::error::$error_message"
        exit $exit_code
    fi
}

echo "::group::Setting up cluster access"

print_info "Cluster type: $CLUSTER_TYPE"

# Setup kubeconfig directory
mkdir -p ~/.kube

if [ -n "$KUBECONFIG_CONTENT" ]; then
    # Use provided kubeconfig
    print_info "Using provided kubeconfig"
    
    # Check if content is base64 encoded
    if echo "$KUBECONFIG_CONTENT" | base64 -d &>/dev/null; then
        print_info "Decoding base64 kubeconfig"
        echo "$KUBECONFIG_CONTENT" | base64 -d > ~/.kube/config
    else
        print_info "Using plain text kubeconfig"
        echo "$KUBECONFIG_CONTENT" > ~/.kube/config
    fi
    
    chmod 600 ~/.kube/config
    
elif [ -n "$IBM_CLOUD_API_KEY" ]; then
    # Use IBM Cloud CLI to get cluster config
    print_info "Authenticating with IBM Cloud"
    
    # Check if IBM Cloud CLI is installed
    if ! command -v ibmcloud &> /dev/null; then
        print_info "Installing IBM Cloud CLI..."
        curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
        handle_error $? "Failed to install IBM Cloud CLI"
    fi
    
    # Login to IBM Cloud
    ibmcloud login --apikey "$IBM_CLOUD_API_KEY" -r "$CLUSTER_REGION" --no-region
    handle_error $? "Failed to authenticate with IBM Cloud"
    
    print_success "Authenticated with IBM Cloud"
    
    # Install required plugins based on cluster type
    if [ "$CLUSTER_TYPE" = "openshift" ]; then
        print_info "Installing OpenShift plugin..."
        if ! ibmcloud plugin list | grep -q "container-service"; then
            ibmcloud plugin install container-service -f
        fi
        
        # Get OpenShift cluster config
        print_info "Getting OpenShift cluster configuration..."
        ibmcloud oc cluster config --cluster "$CLUSTER_NAME" --admin
        handle_error $? "Failed to get OpenShift cluster configuration"
        
    else
        print_info "Installing Kubernetes plugin..."
        if ! ibmcloud plugin list | grep -q "container-service"; then
            ibmcloud plugin install container-service -f
        fi
        
        # Get Kubernetes cluster config
        print_info "Getting Kubernetes cluster configuration..."
        ibmcloud ks cluster config --cluster "$CLUSTER_NAME" --admin
        handle_error $? "Failed to get Kubernetes cluster configuration"
    fi
    
    print_success "Cluster configuration retrieved"
fi

# Verify cluster access
print_info "Verifying cluster access..."

if [ "$CLUSTER_TYPE" = "openshift" ]; then
    # Check if oc is available
    if ! command -v oc &> /dev/null; then
        print_info "Installing OpenShift CLI (oc)..."
        
        # Download and install oc
        OC_VERSION="4.14"
        curl -sL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-${OC_VERSION}/openshift-client-linux.tar.gz" | tar xzf - -C /tmp
        sudo mv /tmp/oc /usr/local/bin/
        sudo chmod +x /usr/local/bin/oc
        
        handle_error $? "Failed to install OpenShift CLI"
    fi
    
    # Verify oc connection
    oc version --client
    oc cluster-info
    handle_error $? "Failed to connect to OpenShift cluster"
    
    print_success "Connected to OpenShift cluster"
    
else
    # Verify kubectl connection
    kubectl version --client
    kubectl cluster-info
    handle_error $? "Failed to connect to Kubernetes cluster"
    
    print_success "Connected to Kubernetes cluster"
fi

# Display cluster information
print_info "Cluster information:"
if [ "$CLUSTER_TYPE" = "openshift" ]; then
    oc get nodes 2>/dev/null || echo "Unable to list nodes (may require additional permissions)"
else
    kubectl get nodes 2>/dev/null || echo "Unable to list nodes (may require additional permissions)"
fi

echo "::endgroup::"

# Made with Bob