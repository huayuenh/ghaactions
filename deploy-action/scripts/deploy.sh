#!/bin/bash

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

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
    
    # Parse manifest to extract service and ingress information
    print_info "Parsing manifest for service and ingress configuration..."
    
    # Extract service type from manifest (look for ClusterIP, NodePort, or LoadBalancer)
    MANIFEST_SERVICE_TYPE=$(grep -A 10 "kind: Service" "$DEPLOYMENT_MANIFEST" | grep "type:" | head -1 | awk '{print $2}' || echo "")
    if [ -n "$MANIFEST_SERVICE_TYPE" ]; then
        print_info "Found service type in manifest: $MANIFEST_SERVICE_TYPE"
        SERVICE_TYPE="$MANIFEST_SERVICE_TYPE"
    fi
    
    # Extract service name from manifest
    MANIFEST_SERVICE_NAME=$(grep -B 5 "kind: Service" "$DEPLOYMENT_MANIFEST" | grep "name:" | tail -1 | awk '{print $2}' || echo "")
    if [ -n "$MANIFEST_SERVICE_NAME" ]; then
        print_info "Found service name in manifest: $MANIFEST_SERVICE_NAME"
    fi
    
    # Check if manifest contains Ingress
    if grep -q "kind: Ingress" "$DEPLOYMENT_MANIFEST"; then
        print_info "Ingress configuration found in manifest"
        
        # Extract ingress host from manifest
        MANIFEST_INGRESS_HOST=$(grep -A 20 "kind: Ingress" "$DEPLOYMENT_MANIFEST" | grep "host:" | head -1 | awk '{print $2}' | tr -d '"' || echo "")
        if [ -n "$MANIFEST_INGRESS_HOST" ]; then
            print_info "Found ingress host in manifest: $MANIFEST_INGRESS_HOST"
            
            # Check if it's a placeholder that needs to be replaced
            if [[ "$MANIFEST_INGRESS_HOST" == *"cluster-ingress-subdomain"* ]] && [ "$AUTO_INGRESS" = "true" ]; then
                print_info "Ingress host is a placeholder, will auto-detect actual subdomain"
                # Will be handled by auto-ingress logic later
            else
                INGRESS_HOST="$MANIFEST_INGRESS_HOST"
            fi
        fi
        
        # Check if TLS is configured in manifest
        if grep -A 30 "kind: Ingress" "$DEPLOYMENT_MANIFEST" | grep -q "tls:"; then
            print_info "TLS configuration found in manifest"
            INGRESS_TLS="true"
        fi
    fi
    
    # Replace image placeholder and apply manifest
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

# Auto-detect IBM Cloud Ingress subdomain if requested
if [ "$CLUSTER_TYPE" = "kubernetes" ] && [ "$AUTO_INGRESS" = "true" ]; then
    print_info "Auto-detecting IBM Cloud cluster ingress subdomain..."
    
    if [ -n "$CLUSTER_NAME" ] && command -v ibmcloud &> /dev/null; then
        # Get the ingress subdomain from IBM Cloud
        INGRESS_SUBDOMAIN=$(ibmcloud ks cluster get --cluster "$CLUSTER_NAME" 2>/dev/null | grep "Ingress Subdomain" | awk '{print $NF}' || echo "")
        
        if [ -n "$INGRESS_SUBDOMAIN" ] && [ "$INGRESS_SUBDOMAIN" != "-" ]; then
            print_success "Auto-detected ingress subdomain: $INGRESS_SUBDOMAIN"
            
            # If using a manifest with placeholder, replace it
            if [ -n "$DEPLOYMENT_MANIFEST" ] && [ -f "$DEPLOYMENT_MANIFEST" ]; then
                if grep -q "cluster-ingress-subdomain" "$DEPLOYMENT_MANIFEST"; then
                    print_info "Replacing cluster-ingress-subdomain placeholder in manifest..."
                    
                    # Create a temporary file with replacements
                    sed "s|cluster-ingress-subdomain|${INGRESS_SUBDOMAIN}|g" "$DEPLOYMENT_MANIFEST" > /tmp/deployment-with-ingress.yaml
                    
                    # Apply the updated manifest
                    sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" /tmp/deployment-with-ingress.yaml | $CMD apply -n "$NAMESPACE" -f -
                    handle_error $? "Failed to apply manifest with ingress subdomain"
                    
                    # Extract the actual ingress host that was applied
                    INGRESS_HOST=$(grep -A 20 "kind: Ingress" /tmp/deployment-with-ingress.yaml | grep "host:" | head -1 | awk '{print $2}' | tr -d '"' || echo "")
                    print_info "Ingress host from manifest: $INGRESS_HOST"
                fi
            elif [ -z "$INGRESS_HOST" ]; then
                # No manifest or no placeholder - create hostname using deployment name
                INGRESS_HOST="${DEPLOYMENT_NAME}.${INGRESS_SUBDOMAIN}"
                print_info "Using ingress host: $INGRESS_HOST"
            fi
            
            # Enable TLS by default for IBM Cloud ingress
            if [ -z "$INGRESS_TLS" ] || [ "$INGRESS_TLS" != "false" ]; then
                INGRESS_TLS="true"
                print_info "TLS enabled for IBM Cloud ingress"
            fi
        else
            print_warning "Could not auto-detect ingress subdomain for cluster: $CLUSTER_NAME"
            print_warning "Ingress will not be configured"
        fi
    else
        print_warning "Cannot auto-detect ingress: ibmcloud CLI not available or CLUSTER_NAME not set"
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