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

# Function to handle errors
handle_error() {
    local exit_code=$1
    local error_message=$2
    
    if [ $exit_code -ne 0 ]; then
        print_error "$error_message"
        echo "::error::$error_message"
        exit $exit_code
    fi
}

# Function to extract namespace from image path
extract_namespace() {
    local image=$1
    # Extract namespace from image path (e.g., us.icr.io/namespace/image:tag -> namespace)
    echo "$image" | sed -E 's|^[^/]+/([^/]+)/.*|\1|'
}

# Function to extract image name without tag
extract_image_name() {
    local image=$1
    # Remove tag if present
    echo "$image" | sed -E 's|:[^:]+$||'
}

# Function to push image
push_image() {
    local image=$1
    local local_image=$2
    
    echo "::group::Pushing image to IBM Cloud Container Registry"
    print_info "Target image: $image"
    
    # If local image is specified, tag it first
    if [ -n "$local_image" ]; then
        print_info "Local image: $local_image"
        
        # Check if local image exists
        if ! docker image inspect "$local_image" &> /dev/null; then
            handle_error 1 "Local image $local_image not found. Please build the image first."
        fi
        
        # Tag the local image with the target registry path
        print_info "Tagging local image $local_image as $image"
        docker tag "$local_image" "$image"
        handle_error $? "Failed to tag local image"
        print_success "Image tagged successfully"
    else
        # Check if image exists locally
        if ! docker image inspect "$image" &> /dev/null; then
            handle_error 1 "Image $image not found locally. Please build the image first or specify local-image parameter."
        fi
    fi
    
    # Push the image
    print_info "Pushing image to registry..."
    docker push "$image"
    handle_error $? "Failed to push image $image"
    
    # Get image digest
    DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "")
    
    if [ -n "$DIGEST" ]; then
        print_success "Image pushed successfully"
        print_info "Image digest: $DIGEST"
        echo "digest=$DIGEST" >> $GITHUB_OUTPUT
    else
        print_success "Image pushed successfully"
    fi
    
    echo "status=success" >> $GITHUB_OUTPUT
    echo "::endgroup::"
}

# Function to pull image
pull_image() {
    local image=$1
    
    echo "::group::Pulling image from IBM Cloud Container Registry"
    print_info "Pulling image: $image"
    
    # Pull the image
    docker pull "$image"
    handle_error $? "Failed to pull image $image"
    
    # Get image digest
    DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "")
    
    if [ -n "$DIGEST" ]; then
        print_success "Image pulled successfully"
        print_info "Image digest: $DIGEST"
        echo "digest=$DIGEST" >> $GITHUB_OUTPUT
    else
        print_success "Image pulled successfully"
    fi
    
    echo "status=success" >> $GITHUB_OUTPUT
    echo "::endgroup::"
}

# Function to delete image
delete_image() {
    local image=$1
    
    echo "::group::Deleting image from IBM Cloud Container Registry"
    print_info "Deleting image: $image"
    
    # Check if image exists
    if ! ibmcloud cr image-inspect "$image" &> /dev/null; then
        print_warning "Image $image not found in registry"
        echo "status=not_found" >> $GITHUB_OUTPUT
        echo "::endgroup::"
        return 0
    fi
    
    # Delete the image
    print_warning "Deleting image from registry..."
    ibmcloud cr image-rm "$image" -f
    handle_error $? "Failed to delete image $image"
    
    print_success "Image deleted successfully"
    echo "status=success" >> $GITHUB_OUTPUT
    echo "::endgroup::"
}

# Function to tag image
tag_image() {
    local image=$1
    local target_tag=$2
    
    echo "::group::Tagging image in IBM Cloud Container Registry"
    
    # Extract base image name without tag
    local base_image=$(extract_image_name "$image")
    local target_image="${base_image}:${target_tag}"
    
    print_info "Source image: $image"
    print_info "Target image: $target_image"
    
    # Use IBM Cloud CR command to tag the image
    ibmcloud cr image-tag "$image" "$target_image"
    handle_error $? "Failed to tag image"
    
    print_success "Image tagged successfully"
    print_info "New tag: $target_tag"
    
    echo "status=success" >> $GITHUB_OUTPUT
    echo "::endgroup::"
}

# Function to retag image
retag_image() {
    local image=$1
    local source_tag=$2
    local target_tag=$3
    
    echo "::group::Retagging image in IBM Cloud Container Registry"
    
    # Extract base image name without tag
    local base_image=$(extract_image_name "$image")
    local source_image="${base_image}:${source_tag}"
    local target_image="${base_image}:${target_tag}"
    
    print_info "Source image: $source_image"
    print_info "Target image: $target_image"
    
    # Check if source image exists
    if ! ibmcloud cr image-inspect "$source_image" &> /dev/null; then
        handle_error 1 "Source image $source_image not found in registry"
    fi
    
    # Tag the image with new tag
    ibmcloud cr image-tag "$source_image" "$target_image"
    handle_error $? "Failed to create new tag"
    
    print_success "Image retagged successfully"
    print_info "Old tag: $source_tag"
    print_info "New tag: $target_tag"
    
    # Optionally remove old tag (commented out for safety)
    # print_info "Removing old tag: $source_tag"
    # ibmcloud cr image-rm "$source_image"
    
    echo "status=success" >> $GITHUB_OUTPUT
    echo "::endgroup::"
}

# Function to manage namespaces
manage_namespace() {
    local namespace=$1
    local namespace_action=$2
    
    echo "::group::Managing namespace in IBM Cloud Container Registry"
    
    case "$namespace_action" in
        create)
            print_info "Creating namespace: $namespace"
            
            # Check if namespace already exists
            if ibmcloud cr namespaces | grep -q "^${namespace}$"; then
                print_warning "Namespace $namespace already exists"
                echo "status=exists" >> $GITHUB_OUTPUT
            else
                ibmcloud cr namespace-add "$namespace"
                handle_error $? "Failed to create namespace $namespace"
                print_success "Namespace $namespace created successfully"
                echo "status=success" >> $GITHUB_OUTPUT
            fi
            ;;
        
        delete)
            print_info "Deleting namespace: $namespace"
            
            # Check if namespace exists
            if ! ibmcloud cr namespaces | grep -q "^${namespace}$"; then
                print_warning "Namespace $namespace does not exist"
                echo "status=not_found" >> $GITHUB_OUTPUT
            else
                # Confirm deletion (in CI/CD, we proceed automatically)
                print_warning "Deleting namespace will remove all images in it"
                ibmcloud cr namespace-rm "$namespace" -f
                handle_error $? "Failed to delete namespace $namespace"
                print_success "Namespace $namespace deleted successfully"
                echo "status=success" >> $GITHUB_OUTPUT
            fi
            ;;
        
        list)
            print_info "Listing namespaces"
            
            NAMESPACES=$(ibmcloud cr namespaces)
            handle_error $? "Failed to list namespaces"
            
            print_success "Namespaces retrieved successfully"
            echo "$NAMESPACES"
            
            # Set output
            echo "namespaces<<EOF" >> $GITHUB_OUTPUT
            echo "$NAMESPACES" >> $GITHUB_OUTPUT
            echo "EOF" >> $GITHUB_OUTPUT
            
            echo "status=success" >> $GITHUB_OUTPUT
            ;;
        
        *)
            handle_error 1 "Invalid namespace action: $namespace_action"
            ;;
    esac
    
    echo "::endgroup::"
}

# Main execution
main() {
    print_info "Starting IBM Cloud Container Registry operation"
    print_info "Action type: $ACTION_TYPE"
    
    case "$ACTION_TYPE" in
        push)
            if [ -z "$IMAGE" ]; then
                handle_error 1 "Image path is required for push operation"
            fi
            push_image "$IMAGE" "$LOCAL_IMAGE"
            ;;
        
        pull)
            if [ -z "$IMAGE" ]; then
                handle_error 1 "Image path is required for pull operation"
            fi
            pull_image "$IMAGE"
            ;;
        
        delete)
            if [ -z "$IMAGE" ]; then
                handle_error 1 "Image path is required for delete operation"
            fi
            delete_image "$IMAGE"
            ;;
        
        tag)
            if [ -z "$IMAGE" ] || [ -z "$TARGET_TAG" ]; then
                handle_error 1 "Image path and target-tag are required for tag operation"
            fi
            tag_image "$IMAGE" "$TARGET_TAG"
            ;;
        
        retag)
            if [ -z "$IMAGE" ] || [ -z "$SOURCE_TAG" ] || [ -z "$TARGET_TAG" ]; then
                handle_error 1 "Image path, source-tag, and target-tag are required for retag operation"
            fi
            retag_image "$IMAGE" "$SOURCE_TAG" "$TARGET_TAG"
            ;;
        
        namespace)
            if [ -z "$NAMESPACE_ACTION" ]; then
                handle_error 1 "namespace-action is required for namespace operation"
            fi
            if [ "$NAMESPACE_ACTION" != "list" ] && [ -z "$NAMESPACE" ]; then
                handle_error 1 "namespace is required for create/delete operations"
            fi
            manage_namespace "$NAMESPACE" "$NAMESPACE_ACTION"
            ;;
        
        *)
            handle_error 1 "Invalid action type: $ACTION_TYPE"
            ;;
    esac
    
    print_success "Operation completed successfully"
}

# Run main function
main

# Made with Bob
