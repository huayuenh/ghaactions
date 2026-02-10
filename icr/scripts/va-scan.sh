#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}ℹ${NC} $1"
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

# Main vulnerability scan function
run_va_scan() {
    local image=$1
    
    echo "::group::Running vulnerability scan"
    
    print_info "Scanning image: $image"
    echo
    
    # Initiate the vulnerability scan
    print_info "Initiating vulnerability scan..."
    ibmcloud cr va "$image" --output json || true
    echo
    
    # Wait for scan to complete (poll every 10 seconds, max 5 minutes)
    print_info "Waiting for scan results..."
    MAX_ATTEMPTS=30  # 30 attempts * 10 seconds = 5 minutes
    ATTEMPT=0
    SCAN_OUTPUT=""
    SCAN_STATUS=""
    SCAN_COMPLETE=false
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        echo "Checking scan status (attempt $ATTEMPT/$MAX_ATTEMPTS)..."
        
        # Get scan results (ignore exit code, only check JSON output)
        SCAN_OUTPUT=$(ibmcloud cr va "$image" --output json 2>&1 || true)
        
        # Extract status from JSON output using jq
        SCAN_STATUS=$(echo "$SCAN_OUTPUT" | jq -r '.[0].status' 2>/dev/null || echo "")
        
        # Check if we got a valid status
        if [ -n "$SCAN_STATUS" ] && [ "$SCAN_STATUS" != "null" ]; then
            echo "Current scan status: $SCAN_STATUS"
            
            # Check if scan is complete (not INCOMPLETE or UNSCANNED)
            if [[ "$SCAN_STATUS" != "INCOMPLETE" ]] && [[ "$SCAN_STATUS" != "UNSCANNED" ]]; then
                SCAN_COMPLETE=true
                print_success "Scan completed successfully!"
                break
            fi
        else
            echo "Scan status not yet available or could not be parsed"
        fi
        
        if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
            print_warning "Scan did not complete within timeout period (5 minutes)"
            break
        fi
        
        sleep 10
    done
    
    echo
    echo "=== Vulnerability Scan Results ==="
    echo "$SCAN_OUTPUT"
    echo
    
    # Handle final result based on status
    if [ "$SCAN_COMPLETE" = true ]; then
        case "$SCAN_STATUS" in
            OK)
                print_success "✓ Scan completed with status: OK - No vulnerabilities found"
                echo "status=$SCAN_STATUS" >> $GITHUB_OUTPUT
                ;;
            WARN)
                print_warning "⚠ Scan completed with status: WARN - Warnings found"
                echo "status=$SCAN_STATUS" >> $GITHUB_OUTPUT
                ;;
            UNSUPPORTED)
                print_info "ℹ Scan completed with status: UNSUPPORTED - Image type not supported for scanning"
                echo "status=$SCAN_STATUS" >> $GITHUB_OUTPUT
                ;;
            FAIL)
                print_error "✗ Vulnerability scan failed with status: FAIL - Critical vulnerabilities found"
                echo "status=FAIL" >> $GITHUB_OUTPUT
                
                # Check if we should fail the build on vulnerability
                if [ "${FAIL_ON_VULNERABILITY:-true}" = "true" ]; then
                    echo "::error::Critical vulnerabilities found in image"
                    exit 1
                else
                    print_warning "⚠ Build will continue despite FAIL status (scan-fail-on-vulnerability is disabled)"
                    echo "::warning::Critical vulnerabilities found but build is allowed to continue"
                fi
                ;;
            *)
                print_error "✗ Vulnerability scan returned unexpected status: $SCAN_STATUS"
                echo "::error::Unexpected scan status: $SCAN_STATUS"
                echo "status=$SCAN_STATUS" >> $GITHUB_OUTPUT
                exit 1
                ;;
        esac
    else
        print_warning "⚠ Scan did not complete within the timeout period"
        echo "::warning::Vulnerability scan timeout - results may be incomplete"
        echo "status=timeout" >> $GITHUB_OUTPUT
        # Don't fail the build on timeout, just warn
    fi
    
    # Set output
    echo "result<<EOF" >> $GITHUB_OUTPUT
    echo "$SCAN_OUTPUT" >> $GITHUB_OUTPUT
    echo "EOF" >> $GITHUB_OUTPUT
    
    echo "::endgroup::"
}

# Check if image parameter is provided
if [ -z "$1" ]; then
    print_error "Image parameter is required"
    echo "Usage: $0 <image>"
    exit 1
fi

# Run the scan
run_va_scan "$1"

# Made with Bob