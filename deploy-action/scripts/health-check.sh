#!/bin/bash

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "::group::Running health checks"

# Determine command based on cluster type
if command -v oc &> /dev/null && oc status &> /dev/null; then
    CMD="oc"
else
    CMD="kubectl"
fi

print_info "Checking deployment status..."

# Check if deployment exists
if ! $CMD get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" &>/dev/null; then
    print_error "Deployment $DEPLOYMENT_NAME not found in namespace $NAMESPACE"
    echo "result=deployment_not_found" >> $GITHUB_OUTPUT
    exit 1
fi

# Get deployment status
READY_REPLICAS=$($CMD get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED_REPLICAS=$($CMD get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')

print_info "Ready replicas: $READY_REPLICAS/$DESIRED_REPLICAS"

if [ "$READY_REPLICAS" != "$DESIRED_REPLICAS" ]; then
    print_warning "Not all replicas are ready"
fi

# Check pod status
print_info "Checking pod status..."
PODS=$($CMD get pods -n "$NAMESPACE" -l app="$DEPLOYMENT_NAME" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
    print_error "No pods found for deployment $DEPLOYMENT_NAME"
    echo "result=no_pods_found" >> $GITHUB_OUTPUT
    exit 1
fi

print_info "Found pods: $PODS"

# Check each pod status
ALL_RUNNING=true
for POD in $PODS; do
    POD_STATUS=$($CMD get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    print_info "Pod $POD status: $POD_STATUS"
    
    if [ "$POD_STATUS" != "Running" ]; then
        ALL_RUNNING=false
        print_warning "Pod $POD is not running"
        
        # Show pod events for debugging
        print_info "Recent events for $POD:"
        $CMD get events -n "$NAMESPACE" --field-selector involvedObject.name="$POD" --sort-by='.lastTimestamp' | tail -5
    fi
done

if [ "$ALL_RUNNING" = false ]; then
    print_warning "Some pods are not in Running state"
fi

# Perform HTTP health check if APP_URL is available
if [ -n "$APP_URL" ]; then
    print_info "Performing HTTP health check..."
    
    # Determine which endpoint to check
    if [ -n "$HEALTH_CHECK_PATH" ] && [ "$HEALTH_CHECK_PATH" != "/" ]; then
        HEALTH_CHECK_URL="${APP_URL}${HEALTH_CHECK_PATH}"
        print_info "Checking health endpoint: $HEALTH_CHECK_URL"
    else
        HEALTH_CHECK_URL="${APP_URL}"
        print_info "Checking root endpoint: $HEALTH_CHECK_URL"
    fi
    
    TIMEOUT=$HEALTH_CHECK_TIMEOUT
    ELAPSED=0
    INTERVAL=5
    
    print_info "Waiting for application to respond (timeout: ${TIMEOUT}s)..."
    
    while [ $ELAPSED -lt $TIMEOUT ]; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$HEALTH_CHECK_URL" 2>/dev/null || echo "000")
        
        # Accept 200, 204, and also 301/302 redirects as success
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
            print_success "Application is responding! HTTP $HTTP_CODE"
            
            # Get response body for additional info
            RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 "$HEALTH_CHECK_URL" 2>/dev/null || echo "")
            if [ -n "$RESPONSE" ]; then
                print_info "Response preview:"
                echo "$RESPONSE" | head -10
            fi
            
            echo "result=healthy" >> $GITHUB_OUTPUT
            echo "http_code=$HTTP_CODE" >> $GITHUB_OUTPUT
            
            print_success "Application is healthy and responding"
            echo "::endgroup::"
            exit 0
        fi
        
        if [ "$HTTP_CODE" != "000" ]; then
            print_warning "Received HTTP $HTTP_CODE (expected 200, 204, 301, or 302)"
            
            # If we got a 404 on health path, try root endpoint as fallback
            if [ "$HTTP_CODE" = "404" ] && [ -n "$HEALTH_CHECK_PATH" ] && [ "$HEALTH_CHECK_PATH" != "/" ]; then
                print_info "Health endpoint not found, trying root endpoint..."
                ROOT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$APP_URL" 2>/dev/null || echo "000")
                if [ "$ROOT_CODE" = "200" ] || [ "$ROOT_CODE" = "301" ] || [ "$ROOT_CODE" = "302" ]; then
                    print_success "Root endpoint is responding! HTTP $ROOT_CODE"
                    echo "result=healthy_root" >> $GITHUB_OUTPUT
                    echo "http_code=$ROOT_CODE" >> $GITHUB_OUTPUT
                    print_warning "Note: Health endpoint $HEALTH_CHECK_PATH returned 404, but root endpoint is accessible"
                    echo "::endgroup::"
                    exit 0
                fi
            fi
        else
            print_warning "Unable to connect to application"
        fi
        
        echo -n "."
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    
    echo ""
    print_error "Health check timed out after ${TIMEOUT}s"
    
    # Show recent pod logs for debugging
    print_info "Recent logs from pods:"
    for POD in $PODS; do
        echo "--- Logs from $POD ---"
        $CMD logs "$POD" -n "$NAMESPACE" --tail=20 2>/dev/null || echo "Unable to retrieve logs"
    done
    
    echo "result=timeout" >> $GITHUB_OUTPUT
    echo "http_code=$HTTP_CODE" >> $GITHUB_OUTPUT
    
    print_warning "Health check failed, but deployment is running"
    print_warning "You may need to check the application logs and configuration"
    
else
    print_warning "No application URL available, skipping HTTP health check"
    
    # Just verify pods are running
    if [ "$ALL_RUNNING" = true ]; then
        print_success "All pods are running"
        echo "result=pods_running" >> $GITHUB_OUTPUT
    else
        print_warning "Some pods are not running"
        echo "result=pods_not_ready" >> $GITHUB_OUTPUT
    fi
fi

echo "::endgroup::"

# Made with Bob