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
#feature1 deploy

feature_deploy() {
    DEPLOY_IN_PROGRESS=1
    install_traps

    # 1. Pre-flight
    if ! preflight_checks; then
        uninstall_traps
        DEPLOY_IN_PROGRESS=0
        return 1
    fi

    # 2. Ask for project name
    read -rp "Enter a name for your project (e.g. 'v1'): " user_input
    if [[ -z "$user_input" ]]; then
        error "Project name cannot be empty."
        uninstall_traps; DEPLOY_IN_PROGRESS=0
        return 1
    fi

    PROJECT_NAME="attendance_tracker_${user_input}"
    PROJECT_DIR="$SCRIPT_DIR/$PROJECT_NAME"

    # 3. Handle existing directory
    if [[ -d "$PROJECT_DIR" ]]; then
        warn "Directory '$PROJECT_NAME' already exists."
        read -rp "Overwrite it? [y/N]: " answer
        case "$answer" in
            [yY]|[yY][eE][sS])
                info "Removing existing directory..."
                rm -rf "$PROJECT_DIR"
                ;;
            *)
                error "Aborted. Existing directory left untouched."
                uninstall_traps; DEPLOY_IN_PROGRESS=0
                return 1
                ;;
        esac
    fi

    # 4. Create directory structure
    mkdir -p "$PROJECT_DIR/Helpers" "$PROJECT_DIR/reports"
    ok "Created directory structure: $PROJECT_NAME/{Helpers,reports}"

    # 5. Copy unmodified files
    cp "$TEMPLATES_DIR/attendance_checker.py" "$PROJECT_DIR/attendance_checker.py"
    cp "$TEMPLATES_DIR/config.json"           "$PROJECT_DIR/Helpers/config.json"
    ok "Deployed attendance_checker.py and Helpers/config.json"

    # 6. Build roster (Option A or B)
    build_roster "$PROJECT_DIR/Helpers/assets.csv"

    # 7. Set permissions
    chmod +x "$PROJECT_DIR/attendance_checker.py"
    chmod 600 "$PROJECT_DIR/Helpers/config.json"
    ok "Set permissions: attendance_checker.py (+x), Helpers/config.json (600)"

    # 8. Offer threshold update
    offer_threshold_update "$PROJECT_DIR/Helpers/config.json"

    # 9. Verify by running the app
    info "Verifying deployment by launching the application..."
    echo
    ( cd "$PROJECT_DIR" && python3 attendance_checker.py )
    local rc=$?

    # 10. Clean up traps
    uninstall_traps
    DEPLOY_IN_PROGRESS=0

    if (( rc == 0 )); then
        ok "Deployment verified successfully."
    else
        warn "Application exited with code $rc (this may be normal if you quit early)."
    fi
}

build_roster() {
    local target="$1"

    echo
    echo "How would you like to build the roster?"
    echo "  A) Copy from template (uses the 10 sample students)"
    echo "  B) Generate a fresh roster (new students, 0 sessions)"
    read -rp "Choose [A/B]: " choice

    case "$choice" in
        [aA]|[aA][bB]*)  # matches A, a, or "a..."
            build_roster_from_template "$target"
            ;;
        [bB])
            build_roster_fresh "$target"
            ;;
        *)
            warn "Invalid choice; defaulting to Option A (template copy)."
            build_roster_from_template "$target"
            ;;
    esac
}

build_roster_from_template() {
    local target="$1"
    local template_csv="$TEMPLATES_DIR/assets.csv"

    read -rp "How many students to copy (1-10)? " n
    # Validate: must be a number between 1 and 10
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > 10 )); then
        warn "Invalid number; defaulting to all 10 students."
        n=10
    fi

    # Header + first n data rows
    head -n $(( n + 1 )) "$template_csv" > "$target"
    ok "Copied $n students (with 4 prior sessions each) into roster."
    # config.json template already says total_sessions: 5, so nothing to change
}

build_roster_fresh() {
    local target="$1"

    read -rp "How many students to generate? " n
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
        warn "Invalid number; defaulting to 5 students."
        n=5
    fi

    # Sample names/emails — extend as needed
    local names=("Latonia Mensah" "Regis Owusu" "Bruno Adjei" "Diana Prince"
                 "Ethan Cole" "Fatima Noor" "George Mensah" "Hannah Kim"
                 "Ibrahim Osei" "Jasmine Lee")
    local emails=("latonia@alustudent.com" "regis@alustudent.com" "bruno@alustudent.com"
                  "diana@alustudent.com" "ethan@alustudent.com" "fatima@alustudent.com"
                  "george@alustudent.com" "hannah@alustudent.com"
                  "ibrahim@alustudent.com" "jasmine@alustudent.com")

    # Header
    echo "Email,Names,Attendance Count,Absence Count" > "$target"

    local i
    for (( i = 0; i < n; i++ )); do
        local idx=$(( i % 10 ))   # wrap around if n > 10
        echo "${emails[$idx]},${names[$idx]},0,0" >> "$target"
    done

    ok "Generated fresh roster with $n students (0 prior sessions)."

    # Fix config.json: fresh roster means session one → total_sessions: 1
    local cfg="$PROJECT_DIR/Helpers/config.json"
    sed -i 's/"total_sessions": *[0-9]*/"total_sessions": 1/' "$cfg"
    ok "Updated config.json: total_sessions = 1 (fresh roster → session 1)"
}

offer_threshold_update() {
    local cfg="$1"

    read -rp "Update attendance alert thresholds? [y/N]: " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) info "Keeping default thresholds (warning=75, failure=50)."; return 0 ;;
    esac

    # --- Warning ---
    local new_warning
    read -rp "New warning threshold [default 75]: " new_warning
    new_warning="${new_warning:-75}"
    if ! [[ "$new_warning" =~ ^[0-9]+$ ]] || (( new_warning < 0 || new_warning > 100 )); then
        warn "Invalid warning value; keeping 75."
        new_warning=75
    fi

    # --- Failure ---
    local new_failure
    read -rp "New failure threshold [default 50]: " new_failure
    new_failure="${new_failure:-50}"
    if ! [[ "$new_failure" =~ ^[0-9]+$ ]] || (( new_failure < 0 || new_failure > 100 )); then
        warn "Invalid failure value; keeping 50."
        new_failure=50
    fi

    # --- Apply with sed, targeting only the exact lines ---
    # Use a distinctive pattern to avoid touching total_sessions
    sed -i -E "s/(\"warning\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${new_warning}/" "$cfg"
    sed -i -E "s/(\"failure\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${new_failure}/" "$cfg"

    ok "Updated thresholds: warning=$new_warning, failure=$new_failure"
}

#feature 2 run application
feature_run() {
    if [[ -z "$PROJECT_NAME" ]]; then
        # Ask which project to run
        read -rp "Enter project name to run (without 'attendance_tracker_'): " user_input
        PROJECT_NAME="attendance_tracker_${user_input}"
        PROJECT_DIR="$SCRIPT_DIR/$PROJECT_NAME"
    fi

    if [[ ! -d "$PROJECT_DIR" ]]; then
        error "Project not found: $PROJECT_DIR"
        return 1
    fi

    if [[ ! -f "$PROJECT_DIR/attendance_checker.py" ]]; then
        error "attendance_checker.py not found in $PROJECT_DIR"
        return 1
    fi

    info "Launching application in $PROJECT_NAME ..."
    echo
    ( cd "$PROJECT_DIR" && python3 attendance_checker.py )
}
#feature archive logs
feature_archive() {
    if [[ -z "$PROJECT_NAME" ]]; then
        read -rp "Enter project name to archive (without 'attendance_tracker_'): " user_input
        PROJECT_NAME="attendance_tracker_${user_input}"
        PROJECT_DIR="$SCRIPT_DIR/$PROJECT_NAME"
    fi

    local reports_dir="$PROJECT_DIR/reports"
    if [[ ! -d "$reports_dir" ]]; then
        error "No reports/ directory in $PROJECT_NAME — has the app been run?"
        return 1
    fi

    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local archives_dir="$PROJECT_DIR/archives"
    local attendance_src="$reports_dir/attendance.log"
    local absent_src="$reports_dir/absent.log"
    local archived_any=0

    #attendance.log
    if [[ -f "$attendance_src" ]]; then
        mkdir -p "$archives_dir/attendance"
        local dest="$archives_dir/attendance/attendance_${timestamp}.log"
        cp "$attendance_src" "$dest"
        ok "Archived: $dest"
        archived_any=1
    else
        warn "No attendance.log found (reports/attendance.log missing)."
    fi

    #absent.log
    if [[ -f "$absent_src" ]]; then
        mkdir -p "$archives_dir/absent"
        local dest="$archives_dir/absent/absent_${timestamp}.log"
        cp "$absent_src" "$dest"
        ok "Archived: $dest"
        archived_any=1
    else
        warn "No absent.log found (nobody was absent, or run hasn't produced one)."
    fi

    if (( archived_any )); then
        ok "Archiving complete."
    else
        warn "Nothing was archived — no log files present."
    fi
}

#main menu

show_menu() {
    echo
    echo "=========================================="
    echo "  Attendance Tracker — Deploy Agent"
    echo "=========================================="
    echo "  1) Deploy the application"
    echo "  2) Run the application"
    echo "  3) Archive the log files"
    echo "  4) Exit"
    echo "=========================================="
}

main() {
    while true; do
        show_menu
        read -rp "Choose an option [1-4]: " choice

        case "$choice" in
            1) feature_deploy ;;
            2) feature_run ;;
            3) feature_archive ;;
            4) info "Goodbye."; exit 0 ;;
            *) warn "Invalid option; please choose 1-4." ;;
        esac

        echo
        read -rp "Press Enter to return to the menu..." _
    done
}

main "$@"
