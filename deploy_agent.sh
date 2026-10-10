#!/bin/bash


# deploy_agent.sh - Automated Project Bootstrapping


set -u  # error on undefined variables (but NOT set -e; would return errors everytime)

#Colors for readable output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

#Globals
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
PROJECT_NAME=""
PROJECT_DIR=""
DEPLOY_IN_PROGRESS=0
INTERRUPTED=0

# Helper logging functions
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

#preflight checks

preflight_checks() {
    info "Running pre-flight checks..."
    local missing=0

    if ! command -v python3 &>/dev/null; then
        error "python3 is not installed or not on PATH."
        missing=1
    else
        ok "python3 found: $(python3 --version 2>&1)"
    fi

    if ! command -v zip &>/dev/null; then
        error "zip is not installed or not on PATH."
        missing=1
    else
        ok "zip found."
    fi

    if [[ ! -d "$TEMPLATES_DIR" ]]; then
        error "templates/ directory not found at: $TEMPLATES_DIR"
        missing=1
    fi

    if (( missing )); then
        error "Pre-flight checks failed. Aborting."
        return 1
    fi
    ok "All pre-flight checks passed."
    return 0
}





