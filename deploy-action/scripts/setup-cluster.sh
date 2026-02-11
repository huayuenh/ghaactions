#!/bin/bash

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

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
    
    # Login to IBM Cloud
    ibmcloud login --apikey "$IBM_CLOUD_API_KEY" -r "$CLUSTER_REGION"
    handle_error $? "Failed to authenticate with IBM Cloud"
    
    print_success "Authenticated with IBM Cloud"
    
    # Install required plugins based on cluster type
    if [ "$CLUSTER_TYPE" = "openshift" ]; then
        # Get OpenShift cluster config
        print_info "Getting OpenShift cluster configuration..."
        ibmcloud oc cluster config --cluster "$CLUSTER_NAME" --admin
        handle_error $? "Failed to get OpenShift cluster configuration"
        
    else
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