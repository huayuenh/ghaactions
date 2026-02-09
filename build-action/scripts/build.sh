#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
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

echo "::group::Building Docker image"

# Validate required inputs
if [ -z "$IMAGE_NAME" ]; then
    handle_error 1 "image-name is required"
fi

print_info "Building Docker image: $IMAGE_NAME"
print_info "Build context: $BUILD_CONTEXT"
print_info "Dockerfile: $DOCKERFILE"

# Build the docker build command
BUILD_CMD="docker buildx build"

# Add context and dockerfile
BUILD_CMD="$BUILD_CMD -f $DOCKERFILE"

# Add image name/tag
BUILD_CMD="$BUILD_CMD -t $IMAGE_NAME"

# Add build arguments
if [ -n "$BUILD_ARGS" ]; then
    print_info "Adding build arguments..."
    while IFS= read -r arg; do
        if [ -n "$arg" ]; then
            BUILD_CMD="$BUILD_CMD --build-arg $arg"
            # Don't print the actual value for security
            ARG_NAME=$(echo "$arg" | cut -d'=' -f1)
            print_info "  - $ARG_NAME"
        fi
    done <<< "$BUILD_ARGS"
fi

# Add platforms for multi-platform builds
if [ -n "$PLATFORMS" ]; then
    print_info "Target platforms: $PLATFORMS"
    BUILD_CMD="$BUILD_CMD --platform $PLATFORMS"
fi

# Add cache configuration
if [ -n "$CACHE_FROM" ]; then
    print_info "Using cache from: $CACHE_FROM"
    BUILD_CMD="$BUILD_CMD --cache-from $CACHE_FROM"
fi

if [ -n "$CACHE_TO" ]; then
    print_info "Exporting cache to: $CACHE_TO"
    BUILD_CMD="$BUILD_CMD --cache-to $CACHE_TO"
fi

# Add labels
if [ -n "$LABELS" ]; then
    print_info "Adding labels..."
    while IFS= read -r label; do
        if [ -n "$label" ]; then
            BUILD_CMD="$BUILD_CMD --label $label"
            LABEL_NAME=$(echo "$label" | cut -d'=' -f1)
            print_info "  - $LABEL_NAME"
        fi
    done <<< "$LABELS"
fi

# Add target stage
if [ -n "$TARGET" ]; then
    print_info "Target build stage: $TARGET"
    BUILD_CMD="$BUILD_CMD --target $TARGET"
fi

# Add no-cache flag
if [ "$NO_CACHE" = "true" ]; then
    print_info "Building without cache"
    BUILD_CMD="$BUILD_CMD --no-cache"
fi

# Add pull flag
if [ "$PULL" = "true" ]; then
    print_info "Always pulling base images"
    BUILD_CMD="$BUILD_CMD --pull"
fi

# Add push or load flags
if [ "$PUSH" = "true" ]; then
    print_info "Image will be pushed after build"
    BUILD_CMD="$BUILD_CMD --push"
elif [ "$LOAD" = "true" ]; then
    if [ -n "$PLATFORMS" ]; then
        print_warning "Cannot load multi-platform builds into docker daemon"
        print_warning "Image will be built but not loaded"
    else
        print_info "Image will be loaded into docker daemon"
        BUILD_CMD="$BUILD_CMD --load"
    fi
fi

# Add metadata output
BUILD_CMD="$BUILD_CMD --metadata-file /tmp/build-metadata.json"

# Add context at the end
BUILD_CMD="$BUILD_CMD $BUILD_CONTEXT"

# Print the build command (sanitized)
print_info "Executing build command..."
echo "$BUILD_CMD" | sed 's/--build-arg [^=]*=[^ ]*/--build-arg ***=***/g'

# Execute the build
eval $BUILD_CMD
handle_error $? "Docker build failed"

print_success "Docker image built successfully"

# Set outputs
echo "image-name=$IMAGE_NAME" >> $GITHUB_OUTPUT

# Get image ID if loaded
if [ "$LOAD" = "true" ] && [ -z "$PLATFORMS" ]; then
    IMAGE_ID=$(docker images -q "$IMAGE_NAME" 2>/dev/null || echo "")
    if [ -n "$IMAGE_ID" ]; then
        print_info "Image ID: $IMAGE_ID"
        echo "image-id=$IMAGE_ID" >> $GITHUB_OUTPUT
    fi
fi

# Get digest if pushed
if [ "$PUSH" = "true" ]; then
    # Try to get digest from metadata file
    if [ -f /tmp/build-metadata.json ]; then
        DIGEST=$(cat /tmp/build-metadata.json | grep -o '"containerimage.digest":"[^"]*"' | cut -d'"' -f4 || echo "")
        if [ -n "$DIGEST" ]; then
            print_info "Image digest: $DIGEST"
            echo "digest=$DIGEST" >> $GITHUB_OUTPUT
        fi
    fi
fi

# Output metadata
if [ -f /tmp/build-metadata.json ]; then
    METADATA=$(cat /tmp/build-metadata.json)
    echo "metadata<<EOF" >> $GITHUB_OUTPUT
    echo "$METADATA" >> $GITHUB_OUTPUT
    echo "EOF" >> $GITHUB_OUTPUT
fi

echo "::endgroup::"

print_success "Build completed successfully"

# Made with Bob