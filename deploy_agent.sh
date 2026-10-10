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




#trapping signals for smooth termination of program w/o suddenly killing

cleanup_on_interrupt() {
    echo
    warn "Deployment interrupted! Cleaning up..."

    if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]]; then
        local zip_name="${PROJECT_NAME}_archive.zip"

        # If a previous archive exists, remove it so we don't nest zips
        [[ -f "$zip_name" ]] && rm -f "$zip_name"

        info "Archiving incomplete project into: $zip_name"
        if zip -r "$zip_name" "$PROJECT_DIR" >/dev/null 2>&1; then
            ok "Archive created: $zip_name"
        else
            error "Failed to create archive."
        fi

        # Remove the half-made directory
        rm -rf "$PROJECT_DIR"
        ok "Removed incomplete directory: $PROJECT_DIR"
    else
        warn "No partial project directory found to archive."
    fi

    INTERRUPTED=1
    echo
    info "Session ended cleanly. Goodbye."
    exit 130   # 128 + SIGINT(2) = 130; conventional for Ctrl+C
}

# Install traps only while deploying
install_traps() {
    trap cleanup_on_interrupt SIGINT SIGTSTP
}
uninstall_traps() {
    trap - SIGINT SIGTSTP
}
