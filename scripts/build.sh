#!/bin/bash
set -e

# Build script for docker-volume-glusterfs plugin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
PLUGIN_NAME="${PLUGIN_NAME:-antoniospatera/glusterfs}"
PLUGIN_TAG="${PLUGIN_TAG:-next}"
BUILD_DIR="${PROJECT_DIR}/build"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS] [COMMAND]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  build       Build the plugin (default)"
    echo "  clean       Remove build artifacts"
    echo "  enable      Enable the plugin"
    echo "  disable     Disable the plugin"
    echo "  install     Build and enable the plugin"
    echo "  uninstall   Disable and remove the plugin"
    echo "  push        Push plugin to registry"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -n, --name NAME    Plugin name (default: $PLUGIN_NAME)"
    echo "  -t, --tag TAG      Plugin tag (default: $PLUGIN_TAG)"
    echo "  -h, --help         Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                          # Build plugin"
    echo "  $0 install                  # Build and enable"
    echo "  $0 -t v1.0 build            # Build with custom tag"
    echo ""
}

log() {
    echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1" >&2
    exit 1
}

do_clean() {
    log "Cleaning build directory"
    rm -rf "$BUILD_DIR"
    success "Clean complete"
}

do_build() {
    log "Building plugin ${PLUGIN_NAME}:${PLUGIN_TAG}"

    # Build Docker image
    echo -e "${DIM}Building rootfs image...${NC}"
    docker build -q -t "${PLUGIN_NAME}:rootfs" "$PROJECT_DIR" || error "Docker build failed"

    # Create build directory
    echo -e "${DIM}Creating rootfs...${NC}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/rootfs"

    # Export rootfs
    docker create --name tmp "${PLUGIN_NAME}:rootfs" >/dev/null
    docker export tmp | tar -x -C "$BUILD_DIR/rootfs"
    docker rm -vf tmp >/dev/null

    # Copy config
    cp "$PROJECT_DIR/config.json" "$BUILD_DIR/"

    # Remove old plugin if exists
    echo -e "${DIM}Removing old plugin (if exists)...${NC}"
    docker plugin rm -f "${PLUGIN_NAME}:${PLUGIN_TAG}" 2>/dev/null || true

    # Create plugin
    echo -e "${DIM}Creating plugin...${NC}"
    docker plugin create "${PLUGIN_NAME}:${PLUGIN_TAG}" "$BUILD_DIR" || error "Plugin create failed"

    success "Plugin ${PLUGIN_NAME}:${PLUGIN_TAG} built successfully"
}

do_enable() {
    log "Enabling plugin ${PLUGIN_NAME}:${PLUGIN_TAG}"
    docker plugin enable "${PLUGIN_NAME}:${PLUGIN_TAG}" || error "Plugin enable failed"
    success "Plugin enabled"
}

do_disable() {
    log "Disabling plugin ${PLUGIN_NAME}:${PLUGIN_TAG}"
    docker plugin disable "${PLUGIN_NAME}:${PLUGIN_TAG}" 2>/dev/null || true
    success "Plugin disabled"
}

do_install() {
    do_build
    do_enable
    echo ""
    log "Plugin installed and ready"
    echo -e "${DIM}Test with:${NC}"
    echo "  docker volume create -d ${PLUGIN_NAME}:${PLUGIN_TAG} -o servers=<server> -o volname=<vol> testvol"
}

do_uninstall() {
    log "Uninstalling plugin ${PLUGIN_NAME}:${PLUGIN_TAG}"
    docker plugin disable "${PLUGIN_NAME}:${PLUGIN_TAG}" 2>/dev/null || true
    docker plugin rm -f "${PLUGIN_NAME}:${PLUGIN_TAG}" 2>/dev/null || true
    success "Plugin uninstalled"
}

do_push() {
    log "Pushing plugin ${PLUGIN_NAME}:${PLUGIN_TAG}"
    docker plugin push "${PLUGIN_NAME}:${PLUGIN_TAG}" || error "Plugin push failed"
    success "Plugin pushed"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            PLUGIN_NAME="$2"
            shift 2
            ;;
        -t|--tag)
            PLUGIN_TAG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        build|clean|enable|disable|install|uninstall|push)
            COMMAND="$1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Default command
COMMAND="${COMMAND:-build}"

# Execute command
case $COMMAND in
    build)     do_build ;;
    clean)     do_clean ;;
    enable)    do_enable ;;
    disable)   do_disable ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    push)      do_push ;;
    *)         usage; exit 1 ;;
esac
