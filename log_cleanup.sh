#!/bin/bash
#===============================================================================
# log_cleanup.sh - Log Rotation and Cleanup Utility
# Author: Mikhail Miasnikou
# Description: Automated log management with compression, rotation, and alerts
#===============================================================================

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/log_cleanup.conf"
DEFAULT_LOG_DIRS=("/var/log" "/home/*/logs" "/opt/*/logs")
ARCHIVE_DIR="/var/log/archive"
REPORT_FILE="/var/log/log_cleanup_report.txt"
MAX_AGE_DAYS=30
MAX_ARCHIVE_DAYS=90
MAX_LOG_SIZE_MB=100
COMPRESS_AFTER_DAYS=7
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
DELETED_COUNT=0
COMPRESSED_COUNT=0
TRUNCATED_COUNT=0
FREED_SPACE_KB=0

#-------------------------------------------------------------------------------
# Functions
#-------------------------------------------------------------------------------

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}"
    echo "${timestamp} [${level}] ${message}" >> "$REPORT_FILE"
}

send_telegram() {
    local message="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="🗑️ $(hostname): ${message}" \
            -d parse_mode="HTML" > /dev/null 2>&1 || true
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}Warning: Running without root privileges. Some logs may not be accessible.${NC}"
    fi
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log "INFO" "Loaded configuration from $CONFIG_FILE"
    fi
}

format_size() {
    local size_kb=$1
    if [[ $size_kb -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $size_kb/1048576}")GB"
    elif [[ $size_kb -ge 1024 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $size_kb/1024}")MB"
    else
        echo "${size_kb}KB"
    fi
}

get_file_size_kb() {
    local file="$1"
    stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null | awk '{print int($1/1024)}'
}

# Delete old log files
delete_old_logs() {
    local dir="$1"
    local max_days="$2"
    
    log "INFO" "Scanning $dir for logs older than $max_days days..."
    
    while IFS= read -r -d '' file; do
        local size_kb=$(get_file_size_kb "$file")
        if rm -f "$file" 2>/dev/null; then
            ((DELETED_COUNT++))
            ((FREED_SPACE_KB+=size_kb))
            log "INFO" "Deleted: $file ($(format_size $size_kb))"
        fi
    done < <(find "$dir" -type f \( -name "*.log" -o -name "*.log.*" -o -name "*.gz" \) -mtime +${max_days} -print0 2>/dev/null)
}

# Compress old uncompressed logs
compress_old_logs() {
    local dir="$1"
    local compress_days="$2"
    
    log "INFO" "Scanning $dir for logs to compress (older than $compress_days days)..."
    
    while IFS= read -r -d '' file; do
        # Skip already compressed files
        [[ "$file" == *.gz ]] && continue
        [[ "$file" == *.bz2 ]] && continue
        [[ "$file" == *.xz ]] && continue
        
        local original_size=$(get_file_size_kb "$file")
        
        if gzip -9 "$file" 2>/dev/null; then
            local new_size=$(get_file_size_kb "${file}.gz")
            local saved=$((original_size - new_size))
            ((COMPRESSED_COUNT++))
            ((FREED_SPACE_KB+=saved))
            log "INFO" "Compressed: $file (saved $(format_size $saved))"
        fi
    done < <(find "$dir" -type f -name "*.log.*" ! -name "*.gz" -mtime +${compress_days} -print0 2>/dev/null)
}

# Truncate large active logs
truncate_large_logs() {
    local dir="$1"
    local max_size_mb="$2"
    local max_size_bytes=$((max_size_mb * 1024 * 1024))
    
    log "INFO" "Scanning $dir for logs larger than ${max_size_mb}MB..."
    
    while IFS= read -r -d '' file; do
        # Skip rotated logs (with numbers or dates)
        [[ "$file" =~ \.[0-9]+$ ]] && continue
        [[ "$file" =~ \.[0-9]{8}$ ]] && continue
        
        local size_bytes=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
        
        if [[ $size_bytes -gt $max_size_bytes ]]; then
            local size_kb=$((size_bytes / 1024))
            
            # Archive last 1000 lines before truncating
            local archive_file="${ARCHIVE_DIR}/$(basename "$file")_$(date +%Y%m%d_%H%M%S).gz"
            tail -n 1000 "$file" | gzip > "$archive_file" 2>/dev/null
            
            # Truncate the file
            if truncate -s 0 "$file" 2>/dev/null; then
                ((TRUNCATED_COUNT++))
                ((FREED_SPACE_KB+=size_kb))
                log "WARN" "Truncated: $file (was $(format_size $size_kb)), archived tail to $archive_file"
            fi
        fi
    done < <(find "$dir" -type f -name "*.log" -size +${max_size_mb}M -print0 2>/dev/null)
}

# Clean journal logs
clean_journal() {
    if command -v journalctl &> /dev/null; then
        log "INFO" "Cleaning systemd journal..."
        
        local before_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.?\d*\s*[GMK]' | head -1)
        
        journalctl --vacuum-time=${MAX_AGE_DAYS}d 2>/dev/null || true
        journalctl --vacuum-size=500M 2>/dev/null || true
        
        local after_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.?\d*\s*[GMK]' | head -1)
        
        log "INFO" "Journal size: $before_size -> $after_size"
    fi
}

# Clean Docker logs
clean_docker_logs() {
    if command -v docker &> /dev/null; then
        log "INFO" "Cleaning Docker container logs..."
        
        local docker_log_dir="/var/lib/docker/containers"
        
        if [[ -d "$docker_log_dir" ]]; then
            while IFS= read -r -d '' logfile; do
                local size_kb=$(get_file_size_kb "$logfile")
                if [[ $size_kb -gt 102400 ]]; then  # > 100MB
                    if truncate -s 0 "$logfile" 2>/dev/null; then
                        ((TRUNCATED_COUNT++))
                        ((FREED_SPACE_KB+=size_kb))
                        log "INFO" "Truncated Docker log: $(basename $(dirname $logfile)) (was $(format_size $size_kb))"
                    fi
                fi
            done < <(find "$docker_log_dir" -name "*-json.log" -print0 2>/dev/null)
        fi
    fi
}

# Clean package manager cache
clean_package_cache() {
    log "INFO" "Cleaning package manager cache..."
    
    # APT cache
    if command -v apt-get &> /dev/null; then
        local before=$(du -sk /var/cache/apt/archives 2>/dev/null | cut -f1)
        apt-get clean 2>/dev/null || true
        local after=$(du -sk /var/cache/apt/archives 2>/dev/null | cut -f1)
        local freed=$((before - after))
        if [[ $freed -gt 0 ]]; then
            ((FREED_SPACE_KB+=freed))
            log "INFO" "APT cache cleaned: $(format_size $freed) freed"
        fi
    fi
    
    # YUM/DNF cache
    if command -v yum &> /dev/null; then
        yum clean all 2>/dev/null || true
        log "INFO" "YUM cache cleaned"
    fi
}

# Clean temporary files
clean_temp_files() {
    log "INFO" "Cleaning temporary files..."
    
    local temp_dirs=("/tmp" "/var/tmp")
    
    for dir in "${temp_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local before=$(du -sk "$dir" 2>/dev/null | cut -f1)
            find "$dir" -type f -atime +7 -delete 2>/dev/null || true
            find "$dir" -type d -empty -delete 2>/dev/null || true
            local after=$(du -sk "$dir" 2>/dev/null | cut -f1)
            local freed=$((before - after))
            if [[ $freed -gt 0 ]]; then
                ((FREED_SPACE_KB+=freed))
                log "INFO" "$dir cleaned: $(format_size $freed) freed"
            fi
        fi
    done
}

# Clean old archives
clean_old_archives() {
    if [[ -d "$ARCHIVE_DIR" ]]; then
        log "INFO" "Cleaning archives older than $MAX_ARCHIVE_DAYS days..."
        find "$ARCHIVE_DIR" -type f -mtime +${MAX_ARCHIVE_DAYS} -delete 2>/dev/null || true
    fi
}

# Generate disk usage report
generate_report() {
    log "INFO" "========================================="
    log "INFO" "           CLEANUP SUMMARY"
    log "INFO" "========================================="
    log "INFO" "Files deleted:    $DELETED_COUNT"
    log "INFO" "Files compressed: $COMPRESSED_COUNT"
    log "INFO" "Files truncated:  $TRUNCATED_COUNT"
    log "INFO" "Space freed:      $(format_size $FREED_SPACE_KB)"
    log "INFO" "========================================="
    
    # Current disk usage
    log "INFO" "Current disk usage:"
    df -h / /var /home 2>/dev/null | tee -a "$REPORT_FILE"
}

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -d, --dir DIR           Additional directory to clean
    -a, --max-age DAYS      Max age for log files (default: $MAX_AGE_DAYS)
    -s, --max-size MB       Max size for active logs (default: $MAX_LOG_SIZE_MB)
    -c, --compress-after    Compress logs after N days (default: $COMPRESS_AFTER_DAYS)
    -j, --journal           Also clean systemd journal
    -D, --docker            Also clean Docker logs
    -p, --packages          Also clean package cache
    -t, --temp              Also clean temp files
    -A, --all               Run all cleanup tasks
    -n, --dry-run           Show what would be done
    -q, --quiet             Minimal output
    -h, --help              Show this help

Examples:
    $(basename "$0")                    # Basic log cleanup
    $(basename "$0") -A                 # Full cleanup (all tasks)
    $(basename "$0") -j -D              # Logs + journal + Docker
    $(basename "$0") -d /opt/myapp/logs # Add custom directory
    $(basename "$0") -a 14 -s 50        # 14 days max, 50MB max size

EOF
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    local extra_dirs=()
    local clean_journal=false
    local clean_docker=false
    local clean_packages=false
    local clean_temp=false
    local dry_run=false
    local quiet=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)
                extra_dirs+=("$2")
                shift 2
                ;;
            -a|--max-age)
                MAX_AGE_DAYS="$2"
                shift 2
                ;;
            -s|--max-size)
                MAX_LOG_SIZE_MB="$2"
                shift 2
                ;;
            -c|--compress-after)
                COMPRESS_AFTER_DAYS="$2"
                shift 2
                ;;
            -j|--journal)
                clean_journal=true
                shift
                ;;
            -D|--docker)
                clean_docker=true
                shift
                ;;
            -p|--packages)
                clean_packages=true
                shift
                ;;
            -t|--temp)
                clean_temp=true
                shift
                ;;
            -A|--all)
                clean_journal=true
                clean_docker=true
                clean_packages=true
                clean_temp=true
                shift
                ;;
            -n|--dry-run)
                dry_run=true
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
    load_config
    mkdir -p "$ARCHIVE_DIR"
    
    # Initialize report
    echo "Log Cleanup Report - $(date)" > "$REPORT_FILE"
    echo "Host: $(hostname)" >> "$REPORT_FILE"
    echo "=========================================" >> "$REPORT_FILE"
    
    log "INFO" "Starting log cleanup..."
    log "INFO" "Max age: ${MAX_AGE_DAYS} days, Max size: ${MAX_LOG_SIZE_MB}MB"
    
    if $dry_run; then
        log "INFO" "DRY RUN MODE - No changes will be made"
    fi
    
    # Process default log directories
    for pattern in "${DEFAULT_LOG_DIRS[@]}"; do
        for dir in $pattern; do
            if [[ -d "$dir" ]]; then
                delete_old_logs "$dir" "$MAX_AGE_DAYS"
                compress_old_logs "$dir" "$COMPRESS_AFTER_DAYS"
                truncate_large_logs "$dir" "$MAX_LOG_SIZE_MB"
            fi
        done
    done
    
    # Process extra directories
    for dir in "${extra_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            delete_old_logs "$dir" "$MAX_AGE_DAYS"
            compress_old_logs "$dir" "$COMPRESS_AFTER_DAYS"
            truncate_large_logs "$dir" "$MAX_LOG_SIZE_MB"
        else
            log "WARN" "Directory not found: $dir"
        fi
    done
    
    # Optional cleanup tasks
    $clean_journal && clean_journal
    $clean_docker && clean_docker_logs
    $clean_packages && clean_package_cache
    $clean_temp && clean_temp_files
    
    # Clean old archives
    clean_old_archives
    
    # Generate report
    generate_report
    
    # Send notification if significant cleanup
    if [[ $FREED_SPACE_KB -gt 102400 ]]; then  # > 100MB
        send_telegram "Cleaned $(format_size $FREED_SPACE_KB) - Deleted: $DELETED_COUNT, Compressed: $COMPRESSED_COUNT, Truncated: $TRUNCATED_COUNT"
    fi
    
    log "INFO" "Cleanup completed!"
}

main "$@"
