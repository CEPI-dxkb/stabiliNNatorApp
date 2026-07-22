#!/bin/bash
# Build script for stabiliNNator Docker images
# Captures build metadata and tags appropriately

set -e

# Configuration
REGISTRY="${REGISTRY:-dxkb}"
IMAGE_BASE="stabilinnator"
IMAGE_BVBRC="stabilinnator-bvbrc"
VERSION="${VERSION:-1.0.0}"

# Target architecture. Docker Hub images are consumed on linux/amd64 HPC nodes
# (and converted to Apptainer there), so amd64 is the default even when building
# on an arm64 host. Override with --platform or the PLATFORM env var.
PLATFORM="${PLATFORM:-linux/amd64}"

# Capture build metadata
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

echo "Building stabiliNNator Docker images"
echo "====================================="
echo "Registry: $REGISTRY"
echo "Version: $VERSION"
echo "Platform: $PLATFORM"
echo "Build Date: $BUILD_DATE"
echo "Git Commit: $GIT_COMMIT"
echo "Git Branch: $GIT_BRANCH"
echo ""

# Parse arguments
BUILD_BASE=false
BUILD_BVBRC=false
PUSH=false
STABILINNATOR_SRC=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)
            BUILD_BASE=true
            shift
            ;;
        --bvbrc)
            BUILD_BVBRC=true
            shift
            ;;
        --all)
            BUILD_BASE=true
            BUILD_BVBRC=true
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --stabilinnator-src)
            STABILINNATOR_SRC="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --base              Build base stabiliNNator image"
            echo "  --bvbrc             Build BV-BRC integrated image"
            echo "  --all               Build all images"
            echo "  --push              Push images to registry after build"
            echo "  --stabilinnator-src Path to stabiliNNator source (for base image)"
            echo "  --platform ARCH     Target architecture (default: linux/amd64)"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Default to building all if no specific target
if [ "$BUILD_BASE" = false ] && [ "$BUILD_BVBRC" = false ]; then
    BUILD_BVBRC=true
fi

# Build base image
if [ "$BUILD_BASE" = true ]; then
    echo "Building base stabiliNNator image..."

    if [ -z "$STABILINNATOR_SRC" ]; then
        echo "Error: --stabilinnator-src required for base image build"
        echo "Example: ./build.sh --base --stabilinnator-src /path/to/stabiliNNator"
        exit 1
    fi

    if [ ! -d "$STABILINNATOR_SRC/proliNNator" ] || [ ! -d "$STABILINNATOR_SRC/disulfiNNate" ]; then
        echo "Error: stabiliNNator source not found at $STABILINNATOR_SRC"
        echo "Expected directories: proliNNator/, disulfiNNate/"
        exit 1
    fi

    # Create temporary build context
    BUILD_CONTEXT=$(mktemp -d)
    trap "rm -rf $BUILD_CONTEXT" EXIT

    cp Dockerfile.stabilinnator "$BUILD_CONTEXT/"
    cp -r "$STABILINNATOR_SRC/proliNNator" "$BUILD_CONTEXT/"
    cp -r "$STABILINNATOR_SRC/disulfiNNate" "$BUILD_CONTEXT/"

    docker build --platform "$PLATFORM" \
        --build-arg BUILD_DATE="$BUILD_DATE" \
        --build-arg GIT_COMMIT="$GIT_COMMIT" \
        --build-arg GIT_BRANCH="$GIT_BRANCH" \
        --build-arg VERSION="$VERSION" \
        -t "$REGISTRY/$IMAGE_BASE:latest-gpu" \
        -t "$REGISTRY/$IMAGE_BASE:$VERSION-gpu" \
        -f "$BUILD_CONTEXT/Dockerfile.stabilinnator" \
        "$BUILD_CONTEXT"

    echo "Base image built: $REGISTRY/$IMAGE_BASE:latest-gpu"

    if [ "$PUSH" = true ]; then
        docker push "$REGISTRY/$IMAGE_BASE:latest-gpu"
        docker push "$REGISTRY/$IMAGE_BASE:$VERSION-gpu"
    fi
fi

# Build BV-BRC image
if [ "$BUILD_BVBRC" = true ]; then
    echo "Building BV-BRC integrated image..."

    # Check that base image exists
    if ! docker image inspect "$REGISTRY/$IMAGE_BASE:latest-gpu" >/dev/null 2>&1; then
        echo "Warning: Base image $REGISTRY/$IMAGE_BASE:latest-gpu not found"
        echo "You may need to build it first with: ./build.sh --base --stabilinnator-src /path/to/source"
        echo "Or pull it from registry"
    fi

    # Build context is parent directory (contains app_specs, service-scripts)
    cd "$(dirname "$0")/.."

    docker build --platform "$PLATFORM" \
        --build-arg BUILD_DATE="$BUILD_DATE" \
        --build-arg GIT_COMMIT="$GIT_COMMIT" \
        --build-arg GIT_BRANCH="$GIT_BRANCH" \
        --build-arg VERSION="$VERSION" \
        -t "$REGISTRY/$IMAGE_BVBRC:latest-gpu" \
        -t "$REGISTRY/$IMAGE_BVBRC:$VERSION-gpu" \
        -f container/Dockerfile.stabilinnator-bvbrc \
        .

    echo "BV-BRC image built: $REGISTRY/$IMAGE_BVBRC:latest-gpu"

    if [ "$PUSH" = true ]; then
        docker push "$REGISTRY/$IMAGE_BVBRC:latest-gpu"
        docker push "$REGISTRY/$IMAGE_BVBRC:$VERSION-gpu"
    fi
fi

echo ""
echo "Build complete!"
echo ""
echo "Images built:"
[ "$BUILD_BASE" = true ] && echo "  - $REGISTRY/$IMAGE_BASE:latest-gpu"
[ "$BUILD_BVBRC" = true ] && echo "  - $REGISTRY/$IMAGE_BVBRC:latest-gpu"
