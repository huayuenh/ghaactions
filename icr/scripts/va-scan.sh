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
    
    # Retry configuration
    MAX_DURATION=300  # 5 minutes in seconds
    RETRY_INTERVAL=15  # 15 seconds between retries
    START_TIME=$(date +%s)
    SCAN_OUTPUT=""
    SCAN_STATUS=""
    SCAN_COMPLETE=false
    
    print_info "Will retry for up to 5 minutes (checking every ${RETRY_INTERVAL} seconds)..."
    
    # Retry loop
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        
        if [ $ELAPSED -ge $MAX_DURATION ]; then
            print_error "Vulnerability scan timeout after 5 minutes"
            echo "::error::Vulnerability scan timeout after 5 minutes"
            echo "status=timeout" >> $GITHUB_OUTPUT
            exit 1
        fi
        
        # Run vulnerability assessment using the correct 'va' command
        SCAN_OUTPUT=$(ibmcloud cr va "$image" --output json 2>&1)
        SCAN_EXIT_CODE=$?
        
        # Check if scan command executed successfully
        if [ $SCAN_EXIT_CODE -eq 0 ]; then
            # Extract status from JSON output using jq
            SCAN_STATUS=$(echo "$SCAN_OUTPUT" | jq -r '.[0].status' 2>/dev/null)
            
            # Check if we got a valid status
            if [ -n "$SCAN_STATUS" ] && [ "$SCAN_STATUS" != "null" ]; then
                print_info "Scan status: $SCAN_STATUS"
                
                # Check if scan is complete (not INCOMPLETE or UNSCANNED)
                if [[ "$SCAN_STATUS" != "INCOMPLETE" ]] && [[ "$SCAN_STATUS" != "UNSCANNED" ]]; then
                    SCAN_COMPLETE=true
                    print_success "Vulnerability scan completed"
                    echo "$SCAN_OUTPUT"
                    break
                else
                    # Scan still in progress
                    REMAINING=$((MAX_DURATION - ELAPSED))
                    print_info "Scan status: $SCAN_STATUS - still in progress. Retrying in ${RETRY_INTERVAL} seconds... (${REMAINING}s remaining)"
                fi
            else
                # Could not parse status, wait and retry
                REMAINING=$((MAX_DURATION - ELAPSED))
                print_warning "Could not parse scan status. Retrying in ${RETRY_INTERVAL} seconds... (${REMAINING}s remaining)"
            fi
        else
            # Command failed, wait and retry
            REMAINING=$((MAX_DURATION - ELAPSED))
            print_warning "Scan command failed. Retrying in ${RETRY_INTERVAL} seconds... (${REMAINING}s remaining)"
        fi
        
        sleep $RETRY_INTERVAL
    done
    
    # Handle final result based on status
    if [ "$SCAN_COMPLETE" = true ]; then
        case "$SCAN_STATUS" in
            OK|WARN|UNSUPPORTED)
                print_success "Scan completed with status: $SCAN_STATUS"
                echo "status=$SCAN_STATUS" >> $GITHUB_OUTPUT
                ;;
            FAIL)
                print_error "Vulnerability scan failed with status: FAIL"
                echo "::error::Vulnerability scan failed with status: FAIL"
                echo "status=FAIL" >> $GITHUB_OUTPUT
                echo "$SCAN_OUTPUT"
                exit 1
                ;;
            *)
                print_error "Vulnerability scan returned unexpected status: $SCAN_STATUS"
                echo "::error::Vulnerability scan returned unexpected status: $SCAN_STATUS"
                echo "status=$SCAN_STATUS" >> $GITHUB_OUTPUT
                echo "$SCAN_OUTPUT"
                exit 1
                ;;
        esac
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