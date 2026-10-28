#!/usr/bin/env bash
# frappe_smart_restore.sh
# Automated Frappe/ERPNext Backup Restore Script with Unattended Execution

set -e
set -o pipefail

LOG_FILE="restore_$(date +%Y%m%d_%H%M%S).log"

# --- UX / UI Colors ---
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

log() {
    local level="$1"
    shift
    local color=""
    case "$level" in
        INFO) color="${C_CYAN}" ;;
        WARN) color="${C_YELLOW}" ;;
        ERROR) color="${C_RED}" ;;
        SUCCESS) color="${C_GREEN}" ;;
    esac

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Print colored output to stderr (>&2) for the user to see, keeping stdout clean
    echo -e "${color}${timestamp} [${level}] $*${C_RESET}" >&2
    # Write plain text to the log file
    echo "${timestamp} [${level}] $*" >> "$LOG_FILE"
}

run_cmd() {
    log "INFO" "Executing: $*"
    if ! "$@"; then
        log "ERROR" "Command failed: $*"
        return 1
    fi
}

print_banner() {
    echo -e "\n${C_BOLD}${C_CYAN}==============================================================${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}    Frappe Smart Restore - Automated Backup Recovery Tool     ${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}==============================================================${C_RESET}\n"
}

find_bench_root() {
    local current_dir="$PWD"
    while [[ "$current_dir" != "/" ]]; do
        if [[ -d "$current_dir/apps" && -d "$current_dir/sites" && -d "$current_dir/env" && -f "$current_dir/sites/common_site_config.json" ]]; then
            echo "$current_dir"
            return 0
        fi
        current_dir=$(dirname "$current_dir")
    done
    return 1
}

select_site() {
    local bench_root="$1"
    local dry_run="$2"
    local sites_dir="$bench_root/sites"

    local -a valid_sites=()
    for site in "$sites_dir"/*; do
        local basename
        basename=$(basename "$site")
        if [[ -d "$site" && -f "$site/site_config.json" && ! "$basename" =~ ^(assets|common_site_config\.json|apps\.txt|currentsite\.txt)$ ]]; then
            valid_sites+=("$basename")
        fi
    done

    if [[ ${#valid_sites[@]} -eq 0 ]]; then
        log "ERROR" "No valid sites found."
        exit 1
    elif [[ ${#valid_sites[@]} -eq 1 ]]; then
        log "INFO" "Auto-selected site: ${valid_sites[0]}"
        echo "${valid_sites[0]}"
    else
        log "INFO" "Multiple sites detected:" >&2
        local i=1
        for s in "${valid_sites[@]}"; do
            echo -e "  ${C_BOLD}${i})${C_RESET} $s" >&2
            ((i++))
        done
        if [[ "$dry_run" == "1" ]]; then
            echo "${valid_sites[0]}"
            return
        fi
        echo "" >&2
        read -r -p "Select site number: " choice >&2
        local idx=$((choice - 1))
        if [[ -n "${valid_sites[$idx]}" ]]; then
            echo "${valid_sites[$idx]}"
        else
            log "ERROR" "Invalid selection"
            exit 1
        fi
    fi
}

detect_backup() {
    local work_dir="$1"
    local latest_db
    
    # Catch standard Frappe backups OR the exact custom database.sql.gz
    latest_db=$(ls -1 "$work_dir"/*-database.sql.gz "$work_dir"/*-database.sql "$work_dir"/database.sql.gz 2>/dev/null | sort -r | head -n 1)
    
    if [[ -z "$latest_db" ]]; then
        log "ERROR" "No database backup found."
        exit 1
    fi

    local timestamp
    local public_file
    local private_file

    # If it has a standard timestamp, extract it and find matching files
    if [[ "$latest_db" =~ ([0-9]{8}_[0-9]{6}) ]]; then
        timestamp="${BASH_REMATCH[1]}"
        public_file=$(ls -1 "$work_dir"/*"${timestamp}"*-public-files.tar* "$work_dir"/*"${timestamp}"*-files.tar* "$work_dir"/*"${timestamp}"*-files.tgz 2>/dev/null | head -n 1 || true)
        private_file=$(ls -1 "$work_dir"/*"${timestamp}"*-private-files.tar* "$work_dir"/*"${timestamp}"*-private-files.tgz 2>/dev/null | head -n 1 || true)
    else
        # If no timestamp exists (e.g., exact 'database.sql.gz'), assign a generic name
        timestamp="custom_backup"
    fi

    # Fallback: If public/private files still aren't found, look for exact public.tgz / private.tgz
    if [[ -z "$public_file" || ! -f "$public_file" ]]; then
        public_file=$(ls -1 "$work_dir"/public.tgz 2>/dev/null | head -n 1 || true)
    fi
    if [[ -z "$private_file" || ! -f "$private_file" ]]; then
        private_file=$(ls -1 "$work_dir"/private.tgz 2>/dev/null | head -n 1 || true)
    fi

    echo "$latest_db|$public_file|$private_file|$timestamp"
}

detect_apps_in_backup() {
    local db_file="$1"
    local cat_cmd="cat"
    [[ "$db_file" == *.gz ]] && cat_cmd="zcat"

    $cat_cmd "$db_file" | grep -a "'installed_apps'" | grep -oP '\[.*?\]' | head -n 1 | tr -d '\[\]"'\''\\' | tr ',' '\n' | grep -v -i -e "^frappe$" -e "^erpnext$" -e "^$" || true
}

create_dummy_app() {
    local bench_root="$1"
    local app_name="$2"
    local apps_dir="$bench_root/apps"
    local app_dir="$apps_dir/$app_name"

    log "INFO" "Scaffolding dummy app: ${C_BOLD}$app_name${C_RESET}"
    mkdir -p "$app_dir/$app_name/$app_name"

    cat > "$app_dir/setup.py" <<EOF
from setuptools import setup
setup(name='$app_name', version='0.0.1')
EOF

    cat > "$app_dir/$app_name/hooks.py" <<EOF
app_name = '$app_name'
app_title = '$app_name'
app_publisher = 'Dummy'
app_description = 'Dummy'
app_icon = 'octicon octicon-file-directory'
app_color = 'grey'
app_email = 'dummy@example.com'
app_license = 'MIT'
EOF

    touch "$app_dir/$app_name/__init__.py"

    cd "$bench_root"
    ./env/bin/python -m pip install -e "$app_dir" > /dev/null
    echo "$app_name" >> "$bench_root/sites/apps.txt"
}

cleanup_dummy_app() {
    local bench_root="$1"
    local app_name="$2"

    log "INFO" "Cleaning up dummy app: ${C_BOLD}$app_name${C_RESET}"
    cd "$bench_root"
    ./env/bin/python -m pip uninstall -y "$app_name" > /dev/null || true
    sed -i "/^${app_name}$/d" "$bench_root/sites/apps.txt"
    rm -rf "$bench_root/apps/$app_name"
}

main() {
    print_banner

    if [[ $EUID -eq 0 ]]; then
        log "WARN" "You are running this script as root! It is highly recommended to run this as your frappe/erpnext user."
        read -r -p "Are you sure you want to continue as root? [y/N]: " root_confirm
        if [[ ! "$root_confirm" =~ ^[Yy]$ ]]; then
            log "INFO" "Aborted by user."
            exit 1
        fi
    fi

    local dry_run=0
    [[ "$1" == "--dry-run" ]] && dry_run=1

    local work_dir="$PWD"
    local bench_root
    bench_root=$(find_bench_root) || { log "ERROR" "Must run inside a Frappe bench. Navigate to your bench directory first."; exit 1; }

    log "INFO" "Detected bench: ${C_BOLD}$bench_root${C_RESET}"
    local site
    site=$(select_site "$bench_root" "$dry_run")

    local backup_info
    backup_info=$(detect_backup "$work_dir")
    IFS='|' read -r db_file pub_file priv_file timestamp <<< "$backup_info"

    # Preflight Check
    local -a bench_apps=($(ls -1 "$bench_root/apps" | grep -v '^\.'))
    local -a backup_apps=($(detect_apps_in_backup "$db_file"))
    local -a missing_apps=()
    local -a app_removal_choices=()

    for b_app in "${backup_apps[@]}"; do
        local found=0
        for bch_app in "${bench_apps[@]}"; do
            [[ "$b_app" == "$bch_app" ]] && found=1
        done
        [[ $found -eq 0 ]] && missing_apps+=("$b_app")
    done

    echo -e "\n${C_BOLD}=== PRE-RESTORE REPORT ===${C_RESET}"
    echo -e "${C_BOLD}Target Site:${C_RESET}   $site"
    echo -e "${C_BOLD}Timestamp:${C_RESET}     $timestamp"
    echo -e "${C_BOLD}Database:${C_RESET}      $db_file"
    echo -e "${C_BOLD}Public Files:${C_RESET}  ${pub_file:-None}"
    echo -e "${C_BOLD}Private Files:${C_RESET} ${priv_file:-None}"

    if [[ ${#missing_apps[@]} -gt 0 ]]; then
        echo -e "${C_BOLD}Missing Apps:${C_RESET}  ${C_RED}${missing_apps[*]}${C_RESET}"
    else
        echo -e "${C_BOLD}Missing Apps:${C_RESET}  ${C_GREEN}None detected${C_RESET}"
    fi
    echo -e "${C_BOLD}==========================${C_RESET}\n"

    if [[ "$dry_run" == "1" ]]; then
        log "SUCCESS" "Dry-run finished. No changes were made."
        exit 0
    fi

    # ---------------------------------------------------------
    # UPFRONT INTERACTIVE MENUS - NO WAITING LATER
    # ---------------------------------------------------------
    if [[ ${#missing_apps[@]} -gt 0 ]]; then
        echo -e "${C_YELLOW}Missing applications detected in the backup that are not installed on your bench.${C_RESET}"
        echo -e "Options:"
        echo -e "  ${C_BOLD}1)${C_RESET} Abort the restoration process."
        echo -e "  ${C_BOLD}2)${C_RESET} Continue using temporary dummy apps (Recommended to safely pass migrations)."
        echo -e "  ${C_BOLD}3)${C_RESET} Continue without resolving (High risk of migration failure)."
        echo ""
        read -r -p "Select [1]: " choice
        choice=${choice:-1}

        if [[ "$choice" == "1" ]]; then
            log "INFO" "Aborted by user."
            exit 0
        elif [[ "$choice" == "2" ]]; then
            echo -e "\n${C_BOLD}=== PRE-CONFIGURE APP REMOVAL STRATEGY ===${C_RESET}"
            echo -e "To prevent waiting later, please select the cleanup strategy for each app now.\n"

            for i in "${!missing_apps[@]}"; do
                app="${missing_apps[$i]}"
                echo -e "${C_CYAN}How would you like to handle the missing app: ${C_BOLD}$app${C_RESET} after restoration?"
                echo -e "  ${C_BOLD}1)${C_RESET} Uninstall the app (${C_RED}WARNING: Deletes DocTypes and data permanently${C_RESET})"
                echo -e "  ${C_BOLD}2)${C_RESET} Remove from registry only (${C_GREEN}Safe: Leaves tables and data intact${C_RESET})"
                echo -e "  ${C_BOLD}3)${C_RESET} Skip this app"
                read -r -p "Select strategy [2]: " rm_choice
                rm_choice=${rm_choice:-2}

                if [[ "$rm_choice" == "1" ]]; then
                    echo -e "${C_YELLOW}You selected Option 1. This may cause permanent data loss for $app.${C_RESET}"
                    read -r -p "Are you absolutely sure you want to proceed? [y/N]: " confirm
                    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                        log "INFO" "Aborted by user."
                        exit 1
                    fi
                elif [[ "$rm_choice" != "2" && "$rm_choice" != "3" ]]; then
                    log "ERROR" "Invalid choice."
                    exit 1
                fi

                # Save choice for later unattended execution
                app_removal_choices[$i]=$rm_choice

                # Scaffold the dummy app immediately
                create_dummy_app "$bench_root" "$app"
                echo ""
            done

            echo -e "${C_GREEN}All options configured. Restoration will now proceed unattended.${C_RESET}\n"

        elif [[ "$choice" != "3" ]]; then
            log "ERROR" "Invalid choice."
            exit 1
        fi
    fi
    # ---------------------------------------------------------

    cd "$bench_root"

    log "INFO" "Taking safety backup of current site state..."
    bench --site "$site" backup

    log "INFO" "Restoring database..."
    local -a restore_args=("bench" "--site" "$site" "restore" "$db_file")
    [[ -n "$pub_file" ]] && restore_args+=("--with-public-files" "$pub_file")
    [[ -n "$priv_file" ]] && restore_args+=("--with-private-files" "$priv_file")

    run_cmd "${restore_args[@]}"

    log "INFO" "Running First Migration (Skipping failing patches)..."
    run_cmd bench --site "$site" migrate --skip-failing || log "WARN" "First migration registered warnings."

    # Execute Pre-Configured App Removals automatically
    if [[ "$choice" == "2" && ${#missing_apps[@]} -gt 0 ]]; then
        echo -e "\n${C_BOLD}=== EXECUTING PRE-CONFIGURED APP REMOVAL ===${C_RESET}"

        for i in "${!missing_apps[@]}"; do
            app="${missing_apps[$i]}"
            rm_choice="${app_removal_choices[$i]}"

            if [[ "$rm_choice" == "1" ]]; then
                log "INFO" "Uninstalling $app..."
                echo "yes" | bench --site "$site" uninstall-app "$app"
            elif [[ "$rm_choice" == "2" ]]; then
                log "INFO" "Safely removing $app from installed-apps registry..."
                echo "from frappe.installer import remove_from_installed_apps; remove_from_installed_apps('$app'); frappe.db.commit()" | bench --site "$site" console
            elif [[ "$rm_choice" == "3" ]]; then
                log "WARN" "Skipping cleanup for $app."
            fi
        done

        log "INFO" "Running Second Migration (Finalizing schema)..."
        run_cmd bench --site "$site" migrate

        for app in "${missing_apps[@]}"; do
            cleanup_dummy_app "$bench_root" "$app"
        done
    fi

    log "SUCCESS" "Site restoration and migration completed successfully! Log saved to $LOG_FILE."
}

main "$@"
