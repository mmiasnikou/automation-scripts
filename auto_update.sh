#!/bin/bash
#===============================================================================
# auto_update.sh - Automated System Update with Safety Checks
# Author: Mikhail Miasnikou
# Description: Safe system updates with pre-checks, logging, and rollback support
#===============================================================================

set -euo pipefail

# Configuration
LOG_DIR="/var/log/auto_update"
LOG_FILE="${LOG_DIR}/update_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/run/auto_update.lock"
MAX_LOG_DAYS=30
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
REBOOT_REQUIRED_FILE="/var/run/reboot-required"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

send_telegram() {
    local message="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="🖥️ $(hostname): ${message}" \
            -d parse_mode="HTML" > /dev/null 2>&1 || true
    fi
}

cleanup() {
    rm -f "$LOCK_FILE"
    log "INFO" "Lock file removed, exiting"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
}

check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}Error: Another update process is running (PID: $pid)${NC}"
            exit 1
        else
            log "WARN" "Stale lock file found, removing"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap cleanup EXIT
}

check_disk_space() {
    local min_space_mb=1024
    local available_mb=$(df -BM /var | awk 'NR==2 {gsub("M",""); print $4}')
    
    if [[ $available_mb -lt $min_space_mb ]]; then
        log "ERROR" "Insufficient disk space: ${available_mb}MB available, ${min_space_mb}MB required"
        send_telegram "❌ Update failed: Low disk space (${available_mb}MB)"
        exit 1
    fi
    log "INFO" "Disk space check passed: ${available_mb}MB available"
}

check_network() {
    local test_hosts=("archive.ubuntu.com" "security.ubuntu.com" "8.8.8.8")
    
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 5 "$host" > /dev/null 2>&1; then
            log "INFO" "Network check passed (reached $host)"
            return 0
        fi
    done
    
    log "ERROR" "Network check failed: Cannot reach update servers"
    send_telegram "❌ Update failed: Network unreachable"
    exit 1
}

check_running_services() {
    local critical_services=("docker" "mysql" "postgresql" "nginx" "apache2")
    local running=()
    
    for service in "${critical_services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            running+=("$service")
        fi
    done
    
    if [[ ${#running[@]} -gt 0 ]]; then
        log "INFO" "Running critical services: ${running[*]}"
    fi
}

create_package_snapshot() {
    local snapshot_file="${LOG_DIR}/packages_$(date +%Y%m%d_%H%M%S).list"
    dpkg --get-selections > "$snapshot_file"
    log "INFO" "Package snapshot saved: $snapshot_file"
    echo "$snapshot_file"
}

get_pending_updates() {
    apt-get update -qq 2>/dev/null
    local updates=$(apt-get -s upgrade 2>/dev/null | grep -c "^Inst" || echo "0")
    local security=$(apt-get -s upgrade 2>/dev/null | grep -c "^Inst.*security" || echo "0")
    echo "$updates $security"
}

perform_update() {
    local update_type="${1:-safe}"
    
    log "INFO" "Starting package list update..."
    if ! apt-get update -qq 2>&1 | tee -a "$LOG_FILE"; then
        log "ERROR" "Failed to update package lists"
        return 1
    fi
    
    case "$update_type" in
        safe)
            log "INFO" "Performing safe upgrade (no removals)..."
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" 2>&1 | tee -a "$LOG_FILE"
            ;;
        full)
            log "INFO" "Performing full upgrade..."
            DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" 2>&1 | tee -a "$LOG_FILE"
            ;;
        security)
            log "INFO" "Performing security updates only..."
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                -o Dir::Etc::SourceList=/etc/apt/sources.list.d/security.list 2>&1 | tee -a "$LOG_FILE"
            ;;
    esac
    
    return ${PIPESTATUS[0]}
}

cleanup_packages() {
    log "INFO" "Cleaning up unused packages..."
    apt-get autoremove -y 2>&1 | tee -a "$LOG_FILE"
    apt-get autoclean -y 2>&1 | tee -a "$LOG_FILE"
}

cleanup_old_logs() {
    log "INFO" "Removing logs older than ${MAX_LOG_DAYS} days..."
    find "$LOG_DIR" -name "*.log" -type f -mtime +${MAX_LOG_DAYS} -delete 2>/dev/null || true
    find "$LOG_DIR" -name "*.list" -type f -mtime +${MAX_LOG_DAYS} -delete 2>/dev/null || true
}

check_reboot_required() {
    if [[ -f "$REBOOT_REQUIRED_FILE" ]]; then
        log "WARN" "System reboot is required to complete updates"
        send_telegram "⚠️ Update completed, reboot required"
        return 0
    fi
    return 1
}

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -t, --type TYPE     Update type: safe, full, security (default: safe)
    -c, --check         Check for updates without installing
    -n, --dry-run       Simulate update (no changes)
    -r, --reboot        Auto-reboot if required
    -q, --quiet         Minimal output
    -h, --help          Show this help

Examples:
    $(basename "$0")                    # Safe update
    $(basename "$0") -t full            # Full dist-upgrade
    $(basename "$0") -t security        # Security updates only
    $(basename "$0") -c                 # Check pending updates
    $(basename "$0") -t full -r         # Full update with auto-reboot

EOF
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    local update_type="safe"
    local check_only=false
    local dry_run=false
    local auto_reboot=false
    local quiet=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--type)
                update_type="$2"
                shift 2
                ;;
            -c|--check)
                check_only=true
                shift
                ;;
            -n|--dry-run)
                dry_run=true
                shift
                ;;
            -r|--reboot)
                auto_reboot=true
                shift
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    check_root
    mkdir -p "$LOG_DIR"
    
    if $check_only; then
        echo -e "${BLUE}Checking for updates...${NC}"
        read updates security <<< $(get_pending_updates)
        echo -e "${GREEN}Pending updates: $updates (security: $security)${NC}"
        exit 0
    fi
    
    check_lock
    
    log "INFO" "========== Starting system update =========="
    log "INFO" "Update type: $update_type"
    log "INFO" "Hostname: $(hostname)"
    log "INFO" "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    
    # Pre-update checks
    check_disk_space
    check_network
    check_running_services
    
    # Get pending updates count
    read updates security <<< $(get_pending_updates)
    log "INFO" "Pending updates: $updates (security: $security)"
    
    if [[ $updates -eq 0 ]]; then
        log "INFO" "System is up to date, nothing to do"
        send_telegram "✅ System is up to date"
        exit 0
    fi
    
    send_telegram "🔄 Starting update: $updates packages ($security security)"
    
    # Create snapshot before update
    local snapshot=$(create_package_snapshot)
    
    if $dry_run; then
        log "INFO" "Dry run mode - simulating update..."
        apt-get -s upgrade 2>&1 | tee -a "$LOG_FILE"
        log "INFO" "Dry run completed"
        exit 0
    fi
    
    # Perform update
    if perform_update "$update_type"; then
        log "INFO" "Update completed successfully"
        cleanup_packages
        cleanup_old_logs
        
        # Check if reboot required
        if check_reboot_required && $auto_reboot; then
            log "WARN" "Auto-reboot enabled, rebooting in 60 seconds..."
            send_telegram "🔄 Rebooting system in 60 seconds"
            sleep 60
            reboot
        fi
        
        send_telegram "✅ Update completed: $updates packages updated"
    else
        log "ERROR" "Update failed!"
        log "INFO" "Package snapshot for rollback: $snapshot"
        send_telegram "❌ Update failed! Check logs: $LOG_FILE"
        exit 1
    fi
    
    log "INFO" "========== Update finished =========="
}

main "$@"
