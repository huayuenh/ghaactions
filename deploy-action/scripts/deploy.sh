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

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
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

echo "::group::Deploying application"

# Set kubectl or oc command based on cluster type
if [ "$CLUSTER_TYPE" = "openshift" ]; then
    CMD="oc"
else
    CMD="kubectl"
fi

print_info "Using command: $CMD"
print_info "Image: $IMAGE"
print_info "Namespace: $NAMESPACE"
print_info "Deployment: $DEPLOYMENT_NAME"

# Create namespace if it doesn't exist
print_info "Ensuring namespace exists..."
$CMD get namespace "$NAMESPACE" &>/dev/null || $CMD create namespace "$NAMESPACE"
print_success "Namespace ready: $NAMESPACE"

# Create image pull secret for IBM Cloud Container Registry
if [[ "$IMAGE" =~ \.icr\.io/ ]]; then
    print_info "Creating image pull secret for IBM Cloud Container Registry..."
    
    # Extract registry from image (e.g., us.icr.io from us.icr.io/namespace/image:tag)
    REGISTRY=$(echo "$IMAGE" | cut -d'/' -f1)
    
    # Check if we have IBM Cloud API key (from environment or kubeconfig setup)
    if [ -n "$IBM_CLOUD_API_KEY" ]; then
        print_info "Using IBM Cloud API key for image pull secret"
        
        # Create or update the image pull secret
        $CMD create secret docker-registry icr-secret \
            --docker-server="$REGISTRY" \
            --docker-username=iamapikey \
            --docker-password="$IBM_CLOUD_API_KEY" \
            --docker-email=iamapikey@ibm.com \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | $CMD apply -f -
        
        handle_error $? "Failed to create image pull secret"
        print_success "Image pull secret created/updated: icr-secret"
        
        # Set the image pull secret name to use in deployment
        IMAGE_PULL_SECRET="icr-secret"
    else
        print_warning "No IBM Cloud API key available for image pull secret"
        print_warning "Assuming cluster already has access to the registry"
        IMAGE_PULL_SECRET=""
    fi
else
    print_info "Image is not from IBM Cloud Container Registry, skipping image pull secret creation"
    IMAGE_PULL_SECRET=""
fi

# Set container name
CONTAINER_NAME_ACTUAL="${CONTAINER_NAME:-$DEPLOYMENT_NAME}"

if [ -n "$DEPLOYMENT_MANIFEST" ] && [ -f "$DEPLOYMENT_MANIFEST" ]; then
    # Use provided manifest
    print_info "Using deployment manifest: $DEPLOYMENT_MANIFEST"
    
    # Replace image in manifest if needed
    sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" "$DEPLOYMENT_MANIFEST" | $CMD apply -n "$NAMESPACE" -f -
    handle_error $? "Failed to apply deployment manifest"
    
else
    # Generate deployment manifest
    print_info "Generating deployment manifest..."
    
    # Create deployment YAML
    cat > /tmp/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT_NAME
  namespace: $NAMESPACE
  labels:
    app: $DEPLOYMENT_NAME
spec:
  replicas: $REPLICAS
  selector:
    matchLabels:
      app: $DEPLOYMENT_NAME
  template:
    metadata:
      labels:
        app: $DEPLOYMENT_NAME
    spec:
EOF

    # Add image pull secrets if available
    if [ -n "$IMAGE_PULL_SECRET" ]; then
        cat >> /tmp/deployment.yaml <<EOF
      imagePullSecrets:
      - name: $IMAGE_PULL_SECRET
EOF
    fi

    # Continue with container spec
    cat >> /tmp/deployment.yaml <<EOF
      containers:
      - name: $CONTAINER_NAME_ACTUAL
        image: $IMAGE
        ports:
        - containerPort: $PORT
          protocol: TCP
        resources:
          limits:
            cpu: $RESOURCE_LIMITS_CPU
            memory: $RESOURCE_LIMITS_MEMORY
          requests:
            cpu: $RESOURCE_REQUESTS_CPU
            memory: $RESOURCE_REQUESTS_MEMORY
EOF

    # Add probes if enabled (case-insensitive check)
    ENABLE_PROBES_LOWER=$(echo "$ENABLE_PROBES" | tr '[:upper:]' '[:lower:]')
    if [ "$ENABLE_PROBES_LOWER" = "true" ]; then
        print_info "Health probes are enabled"
        # Determine probe paths
        LIVENESS_PATH="${LIVENESS_PROBE_PATH:-$HEALTH_CHECK_PATH}"
        READINESS_PATH="${READINESS_PROBE_PATH:-$HEALTH_CHECK_PATH}"
        
        # Only add probes if paths are not empty
        if [ -n "$LIVENESS_PATH" ]; then
            print_info "Adding liveness probe: $LIVENESS_PATH"
            cat >> /tmp/deployment.yaml <<EOF
        livenessProbe:
          httpGet:
            path: $LIVENESS_PATH
            port: $PORT
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
EOF
        fi
        
        if [ -n "$READINESS_PATH" ]; then
            print_info "Adding readiness probe: $READINESS_PATH"
            cat >> /tmp/deployment.yaml <<EOF
        readinessProbe:
          httpGet:
            path: $READINESS_PATH
            port: $PORT
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
EOF
        fi
    else
        print_warning "Health probes are disabled"
    fi

    # Add environment variables if provided
    if [ -n "$ENV_VARS" ]; then
        print_info "Adding environment variables..."
        echo "        env:" >> /tmp/deployment.yaml
        while IFS= read -r env_var; do
            if [ -n "$env_var" ]; then
                KEY=$(echo "$env_var" | cut -d'=' -f1)
                VALUE=$(echo "$env_var" | cut -d'=' -f2-)
                echo "        - name: $KEY" >> /tmp/deployment.yaml
                echo "          value: \"$VALUE\"" >> /tmp/deployment.yaml
            fi
        done <<< "$ENV_VARS"
    fi
    
    # Apply deployment
    print_info "Applying deployment..."
    $CMD apply -f /tmp/deployment.yaml
    handle_error $? "Failed to apply deployment"
fi

print_success "Deployment created/updated"

# Wait for deployment to be ready
print_info "Waiting for deployment to be ready..."
$CMD rollout status deployment/$DEPLOYMENT_NAME -n "$NAMESPACE" --timeout=5m
handle_error $? "Deployment failed to become ready"

print_success "Deployment is ready"

# Create or update service
print_info "Creating/updating service..."

cat > /tmp/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $DEPLOYMENT_NAME
  namespace: $NAMESPACE
  labels:
    app: $DEPLOYMENT_NAME
spec:
  type: $SERVICE_TYPE
  selector:
    app: $DEPLOYMENT_NAME
  ports:
  - port: 80
    targetPort: $PORT
    protocol: TCP
    name: http
EOF

$CMD apply -f /tmp/service.yaml
handle_error $? "Failed to create/update service"

print_success "Service created/updated"

# Get service information
print_info "Retrieving service information..."
sleep 5  # Wait for service to be fully provisioned

SERVICE_IP=""
APP_URL=""
CLUSTER_IP=""

# Get cluster IP (always available)
CLUSTER_IP=$($CMD get service $DEPLOYMENT_NAME -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

if [ "$SERVICE_TYPE" = "LoadBalancer" ]; then
    # Wait for external IP
    print_info "Waiting for LoadBalancer external IP..."
    for i in {1..60}; do
        SERVICE_IP=$($CMD get service $DEPLOYMENT_NAME -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -z "$SERVICE_IP" ]; then
            SERVICE_IP=$($CMD get service $DEPLOYMENT_NAME -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        fi
        
        if [ -n "$SERVICE_IP" ]; then
            break
        fi
        
        echo -n "."
        sleep 5
    done
    echo ""
    
    if [ -n "$SERVICE_IP" ]; then
        APP_URL="http://${SERVICE_IP}"
        print_success "LoadBalancer IP: $SERVICE_IP"
    else
        print_warning "LoadBalancer IP not yet assigned (this is normal for VPC clusters without LB)"
        print_info "Service is accessible within cluster at: ${CLUSTER_IP}:80"
    fi
    
elif [ "$SERVICE_TYPE" = "NodePort" ]; then
    NODE_PORT=$($CMD get service $DEPLOYMENT_NAME -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
    
    # Try multiple methods to get a public/external IP
    NODE_IP=""
    
    # Method 1: For IBM Cloud clusters, use ibmcloud CLI to get public IP
    if [ -n "$IBM_CLOUD_API_KEY" ] && command -v ibmcloud &> /dev/null && [ -n "$CLUSTER_NAME" ]; then
        print_info "Attempting to get public IP via IBM Cloud CLI..."
        
        # Get list of workers and extract public IP
        WORKERS_OUTPUT=$(ibmcloud ks workers --cluster "$CLUSTER_NAME" --output json 2>/dev/null || echo "")
        
        if [ -n "$WORKERS_OUTPUT" ]; then
            # Try to get public IP from first worker
            NODE_IP=$(echo "$WORKERS_OUTPUT" | grep -o '"publicIP":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
            
            if [ -n "$NODE_IP" ] && [ "$NODE_IP" != "null" ] && [ "$NODE_IP" != "-" ]; then
                print_success "Found public IP via IBM Cloud CLI: $NODE_IP"
            else
                print_warning "No public IP found in IBM Cloud worker info"
                NODE_IP=""
            fi
        fi
    fi
    
    # Method 2: Try to get ExternalIP from nodes (works for non-VPC clusters)
    if [ -z "$NODE_IP" ]; then
        EXTERNAL_IP=$($CMD get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null | awk '{print $1}')
        
        # Check if it's a public IP (not starting with 10., 172.16-31., or 192.168.)
        if [ -n "$EXTERNAL_IP" ]; then
            if [[ ! "$EXTERNAL_IP" =~ ^10\. ]] && [[ ! "$EXTERNAL_IP" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && [[ ! "$EXTERNAL_IP" =~ ^192\.168\. ]]; then
                NODE_IP="$EXTERNAL_IP"
                print_info "Found public ExternalIP from node"
            else
                print_warning "ExternalIP is a private IP: $EXTERNAL_IP"
            fi
        fi
    fi
    
    # Method 3: Try to get public IP from IBM Cloud node labels
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$($CMD get nodes -o jsonpath='{.items[0].metadata.labels.ibm-cloud\.kubernetes\.io/external-ip}' 2>/dev/null || echo "")
        if [ -n "$NODE_IP" ] && [ "$NODE_IP" != "null" ]; then
            print_info "Found IBM Cloud public IP from node labels"
        else
            NODE_IP=""
        fi
    fi
    
    # Method 4: Fall back to Hostname type address
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$($CMD get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="Hostname")].address}' 2>/dev/null || echo "")
        if [ -n "$NODE_IP" ]; then
            print_info "Using node hostname"
        fi
    fi
    
    # Method 5: Last resort - use internal IP with warning
    if [ -z "$NODE_IP" ]; then
        NODE_IP=$($CMD get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        print_warning "No public IP found - using internal node IP (may not be accessible externally)"
        print_warning "For IBM Cloud VPC clusters, ensure you have a public gateway or use LoadBalancer service type"
    fi
    
    if [ -n "$NODE_IP" ] && [ -n "$NODE_PORT" ]; then
        SERVICE_IP="${NODE_IP}:${NODE_PORT}"
        APP_URL="http://${SERVICE_IP}"
        print_success "NodePort: $NODE_PORT on $NODE_IP"
    fi
    
elif [ "$SERVICE_TYPE" = "ClusterIP" ]; then
    print_info "Service type is ClusterIP - accessible only within the cluster"
    if [ -n "$CLUSTER_IP" ]; then
        SERVICE_IP="${CLUSTER_IP}:80"
        print_info "Cluster IP: $CLUSTER_IP"
        print_info "Internal URL: http://${SERVICE_IP}"
        print_info "Service DNS: ${DEPLOYMENT_NAME}.${NAMESPACE}.svc.cluster.local"
        
        # Only set APP_URL if Ingress is not configured
        if [ -z "$INGRESS_HOST" ]; then
            # For ClusterIP without Ingress, provide the internal DNS name as the URL
            APP_URL="http://${DEPLOYMENT_NAME}.${NAMESPACE}.svc.cluster.local"
        else
            print_info "Ingress will be configured - skipping ClusterIP URL"
        fi
    fi
fi

# Handle OpenShift Route
if [ "$CLUSTER_TYPE" = "openshift" ] && [ "$CREATE_ROUTE" = "true" ]; then
    print_info "Creating OpenShift route..."
    
    if [ -n "$ROUTE_HOSTNAME" ]; then
        oc expose service $DEPLOYMENT_NAME -n "$NAMESPACE" --hostname="$ROUTE_HOSTNAME" 2>/dev/null || oc patch route $DEPLOYMENT_NAME -n "$NAMESPACE" -p "{\"spec\":{\"host\":\"$ROUTE_HOSTNAME\"}}"
    else
        oc expose service $DEPLOYMENT_NAME -n "$NAMESPACE" 2>/dev/null || echo "Route already exists"
    fi
    
    # Get route URL
    ROUTE_HOST=$(oc get route $DEPLOYMENT_NAME -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$ROUTE_HOST" ]; then
        APP_URL="http://${ROUTE_HOST}"
        print_success "Route created: $APP_URL"
    fi
fi

# Handle Kubernetes Ingress
if [ "$CLUSTER_TYPE" = "kubernetes" ] && [ -n "$INGRESS_HOST" ]; then
    print_info "Creating Kubernetes ingress..."
    
    TLS_CONFIG=""
    if [ "$INGRESS_TLS" = "true" ]; then
        TLS_CONFIG="  tls:
  - hosts:
    - $INGRESS_HOST
    secretName: ${DEPLOYMENT_NAME}-tls"
    fi
    
    cat > /tmp/ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $DEPLOYMENT_NAME
  namespace: $NAMESPACE
  labels:
    app: $DEPLOYMENT_NAME
spec:
$TLS_CONFIG
  rules:
  - host: $INGRESS_HOST
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $DEPLOYMENT_NAME
            port:
              number: 80
EOF
    
    $CMD apply -f /tmp/ingress.yaml
    handle_error $? "Failed to create ingress"
    
    if [ "$INGRESS_TLS" = "true" ]; then
        APP_URL="https://${INGRESS_HOST}"
    else
        APP_URL="http://${INGRESS_HOST}"
    fi
    
    print_success "Ingress created: $APP_URL"
fi

# Set outputs
echo "status=success" >> $GITHUB_OUTPUT

if [ -n "$APP_URL" ]; then
    echo "app-url=$APP_URL" >> $GITHUB_OUTPUT
    print_success "Application URL: $APP_URL"
fi

if [ -n "$SERVICE_IP" ]; then
    echo "service-ip=$SERVICE_IP" >> $GITHUB_OUTPUT
fi

# Get deployment info
DEPLOYMENT_INFO=$($CMD get deployment $DEPLOYMENT_NAME -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
echo "info<<EOF" >> $GITHUB_OUTPUT
echo "$DEPLOYMENT_INFO" >> $GITHUB_OUTPUT
echo "EOF" >> $GITHUB_OUTPUT

print_success "Deployment completed successfully"

echo "::endgroup::"

# Made with Bob