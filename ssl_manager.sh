#!/bin/bash
#===============================================================================
# ssl_manager.sh - SSL/TLS Certificate Manager for Let's Encrypt
# Author: Mikhail Miasnikou
# Description: Automated SSL certificate management with monitoring and alerts
#===============================================================================

set -euo pipefail

# Configuration
CERT_DIR="/etc/letsencrypt/live"
RENEWAL_THRESHOLD_DAYS=30
LOG_FILE="/var/log/ssl_manager.log"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
EMAIL=""
WEBROOT="/var/www/html"
PREFERRED_CHALLENGES="http"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
            -d text="🔐 $(hostname): ${message}" \
            -d parse_mode="HTML" > /dev/null 2>&1 || true
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
}

check_certbot() {
    if ! command -v certbot &> /dev/null; then
        echo -e "${RED}Error: certbot is not installed${NC}"
        echo "Install with: apt install certbot python3-certbot-nginx"
        exit 1
    fi
}

# Get certificate expiry date
get_cert_expiry() {
    local domain="$1"
    local cert_file="${CERT_DIR}/${domain}/fullchain.pem"
    
    if [[ -f "$cert_file" ]]; then
        openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2
    else
        echo "NOT_FOUND"
    fi
}

# Get days until expiry
get_days_until_expiry() {
    local domain="$1"
    local cert_file="${CERT_DIR}/${domain}/fullchain.pem"
    
    if [[ -f "$cert_file" ]]; then
        local expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
        local now_epoch=$(date +%s)
        local days=$(( (expiry_epoch - now_epoch) / 86400 ))
        echo "$days"
    else
        echo "-1"
    fi
}

# Check certificate validity
check_cert_valid() {
    local domain="$1"
    local cert_file="${CERT_DIR}/${domain}/fullchain.pem"
    
    if [[ -f "$cert_file" ]]; then
        openssl x509 -checkend 0 -noout -in "$cert_file" 2>/dev/null
        return $?
    fi
    return 1
}

# Get certificate info
get_cert_info() {
    local domain="$1"
    local cert_file="${CERT_DIR}/${domain}/fullchain.pem"
    
    if [[ -f "$cert_file" ]]; then
        echo -e "${CYAN}Certificate: ${domain}${NC}"
        echo "  Issuer:  $(openssl x509 -issuer -noout -in "$cert_file" 2>/dev/null | cut -d= -f2-)"
        echo "  Valid from: $(openssl x509 -startdate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
        echo "  Valid until: $(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
        
        local days=$(get_days_until_expiry "$domain")
        if [[ $days -lt 0 ]]; then
            echo -e "  Status: ${RED}EXPIRED${NC}"
        elif [[ $days -lt $RENEWAL_THRESHOLD_DAYS ]]; then
            echo -e "  Status: ${YELLOW}Expires in $days days${NC}"
        else
            echo -e "  Status: ${GREEN}Valid ($days days remaining)${NC}"
        fi
        
        # Show SANs
        echo "  Domains: $(openssl x509 -text -noout -in "$cert_file" 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/DNS://g' | tr -d ' ')"
        echo ""
    else
        echo -e "${RED}Certificate not found: ${domain}${NC}"
    fi
}

# List all certificates
list_certificates() {
    echo -e "${BLUE}=== SSL Certificates on $(hostname) ===${NC}"
    echo ""
    
    if [[ ! -d "$CERT_DIR" ]]; then
        echo "No certificates found (directory does not exist)"
        return
    fi
    
    local cert_count=0
    local expiring_soon=0
    local expired=0
    
    for domain_dir in "$CERT_DIR"/*/; do
        if [[ -d "$domain_dir" ]]; then
            local domain=$(basename "$domain_dir")
            get_cert_info "$domain"
            ((cert_count++))
            
            local days=$(get_days_until_expiry "$domain")
            if [[ $days -lt 0 ]]; then
                ((expired++))
            elif [[ $days -lt $RENEWAL_THRESHOLD_DAYS ]]; then
                ((expiring_soon++))
            fi
        fi
    done
    
    echo -e "${BLUE}=== Summary ===${NC}"
    echo "Total certificates: $cert_count"
    echo -e "Expiring soon (<${RENEWAL_THRESHOLD_DAYS} days): ${YELLOW}$expiring_soon${NC}"
    echo -e "Expired: ${RED}$expired${NC}"
}

# Check all certificates and alert
check_certificates() {
    local issues=()
    
    log "INFO" "Checking all certificates..."
    
    if [[ ! -d "$CERT_DIR" ]]; then
        log "WARN" "Certificate directory does not exist"
        return
    fi
    
    for domain_dir in "$CERT_DIR"/*/; do
        if [[ -d "$domain_dir" ]]; then
            local domain=$(basename "$domain_dir")
            local days=$(get_days_until_expiry "$domain")
            
            if [[ $days -lt 0 ]]; then
                log "ERROR" "Certificate EXPIRED: $domain"
                issues+=("❌ $domain: EXPIRED")
            elif [[ $days -lt $RENEWAL_THRESHOLD_DAYS ]]; then
                log "WARN" "Certificate expiring soon: $domain ($days days)"
                issues+=("⚠️ $domain: $days days left")
            else
                log "INFO" "Certificate OK: $domain ($days days)"
            fi
        fi
    done
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        local message="Certificate issues found:\n"
        for issue in "${issues[@]}"; do
            message+="\n$issue"
        done
        send_telegram "$message"
    fi
}

# Request new certificate
request_certificate() {
    local domain="$1"
    local extra_domains="${2:-}"
    
    log "INFO" "Requesting certificate for: $domain"
    
    local domain_args="-d $domain"
    if [[ -n "$extra_domains" ]]; then
        for d in $extra_domains; do
            domain_args+=" -d $d"
        done
    fi
    
    local email_arg=""
    if [[ -n "$EMAIL" ]]; then
        email_arg="--email $EMAIL"
    else
        email_arg="--register-unsafely-without-email"
    fi
    
    # Try webroot first, then standalone
    if [[ -d "$WEBROOT" ]]; then
        certbot certonly --webroot -w "$WEBROOT" $domain_args $email_arg --agree-tos --non-interactive 2>&1 | tee -a "$LOG_FILE"
    else
        certbot certonly --standalone $domain_args $email_arg --agree-tos --non-interactive 2>&1 | tee -a "$LOG_FILE"
    fi
    
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        log "INFO" "Certificate obtained successfully for: $domain"
        send_telegram "✅ New certificate obtained: $domain"
    else
        log "ERROR" "Failed to obtain certificate for: $domain"
        send_telegram "❌ Failed to obtain certificate: $domain"
        return 1
    fi
}

# Renew all certificates
renew_certificates() {
    local force="${1:-false}"
    
    log "INFO" "Starting certificate renewal..."
    
    local renew_args="--non-interactive"
    if $force; then
        renew_args+=" --force-renewal"
    fi
    
    certbot renew $renew_args 2>&1 | tee -a "$LOG_FILE"
    
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        log "INFO" "Certificate renewal completed"
        
        # Reload services
        reload_services
        
        send_telegram "✅ Certificate renewal completed"
    else
        log "ERROR" "Certificate renewal failed"
        send_telegram "❌ Certificate renewal failed"
        return 1
    fi
}

# Reload web services after renewal
reload_services() {
    log "INFO" "Reloading web services..."
    
    # Nginx
    if systemctl is-active --quiet nginx; then
        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            log "INFO" "Nginx reloaded"
        else
            log "ERROR" "Nginx config test failed, not reloading"
        fi
    fi
    
    # Apache
    if systemctl is-active --quiet apache2; then
        if apache2ctl configtest 2>/dev/null; then
            systemctl reload apache2
            log "INFO" "Apache reloaded"
        else
            log "ERROR" "Apache config test failed, not reloading"
        fi
    fi
    
    # HAProxy
    if systemctl is-active --quiet haproxy; then
        systemctl reload haproxy
        log "INFO" "HAProxy reloaded"
    fi
}

# Revoke certificate
revoke_certificate() {
    local domain="$1"
    local cert_file="${CERT_DIR}/${domain}/fullchain.pem"
    
    if [[ ! -f "$cert_file" ]]; then
        log "ERROR" "Certificate not found: $domain"
        return 1
    fi
    
    echo -e "${YELLOW}WARNING: This will revoke the certificate for $domain${NC}"
    read -p "Are you sure? (yes/no): " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        certbot revoke --cert-path "$cert_file" --non-interactive 2>&1 | tee -a "$LOG_FILE"
        certbot delete --cert-name "$domain" --non-interactive 2>&1 | tee -a "$LOG_FILE"
        log "INFO" "Certificate revoked and deleted: $domain"
        send_telegram "🗑️ Certificate revoked: $domain"
    else
        echo "Aborted"
    fi
}

# Test certificate
test_certificate() {
    local domain="$1"
    local port="${2:-443}"
    
    echo -e "${BLUE}Testing SSL for: $domain:$port${NC}"
    echo ""
    
    # Check if port is open
    if ! timeout 5 bash -c "echo >/dev/tcp/$domain/$port" 2>/dev/null; then
        echo -e "${RED}Cannot connect to $domain:$port${NC}"
        return 1
    fi
    
    # Get certificate from server
    echo "Fetching certificate from server..."
    local server_cert=$(echo | openssl s_client -servername "$domain" -connect "$domain:$port" 2>/dev/null)
    
    if [[ -z "$server_cert" ]]; then
        echo -e "${RED}Failed to get certificate${NC}"
        return 1
    fi
    
    echo "$server_cert" | openssl x509 -noout -text 2>/dev/null | head -20
    
    # Check expiry
    local expiry=$(echo "$server_cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    echo ""
    echo "Expiry: $expiry"
    
    # SSL Labs grade (simplified check)
    echo ""
    echo "Quick security checks:"
    echo "$server_cert" | grep -q "TLSv1.3" && echo "  ✅ TLS 1.3 supported" || echo "  ⚠️ TLS 1.3 not detected"
    
    # Check certificate chain
    echo ""
    echo "Certificate chain:"
    echo | openssl s_client -servername "$domain" -connect "$domain:$port" -showcerts 2>/dev/null | grep -E "^ [0-9]+ s:|^ +i:"
}

# Install certbot hook for auto-renewal
install_hook() {
    local hook_file="/etc/letsencrypt/renewal-hooks/post/reload-services.sh"
    
    mkdir -p "$(dirname "$hook_file")"
    
    cat > "$hook_file" << 'HOOK'
#!/bin/bash
# Auto-generated by ssl_manager.sh

# Reload Nginx
if systemctl is-active --quiet nginx; then
    nginx -t && systemctl reload nginx
fi

# Reload Apache
if systemctl is-active --quiet apache2; then
    apache2ctl configtest && systemctl reload apache2
fi

# Reload HAProxy
if systemctl is-active --quiet haproxy; then
    systemctl reload haproxy
fi

# Log
echo "$(date): Services reloaded after certificate renewal" >> /var/log/ssl_manager.log
HOOK

    chmod +x "$hook_file"
    log "INFO" "Installed renewal hook: $hook_file"
}

# Setup cron for automatic checks
setup_cron() {
    local cron_file="/etc/cron.d/ssl-manager"
    
    cat > "$cron_file" << EOF
# SSL Certificate monitoring
# Generated by ssl_manager.sh

# Check certificates daily at 6 AM
0 6 * * * root $(readlink -f "$0") check >> /var/log/ssl_manager.log 2>&1

# Attempt renewal twice daily (certbot handles duplicate runs)
0 0,12 * * * root certbot renew --quiet --post-hook "$(readlink -f "$0") reload"
EOF

    chmod 644 "$cron_file"
    log "INFO" "Installed cron job: $cron_file"
}

show_help() {
    cat << EOF
Usage: $(basename "$0") COMMAND [OPTIONS]

Commands:
    list                    List all certificates with status
    check                   Check certificates and send alerts
    info DOMAIN             Show detailed info for a certificate
    request DOMAIN [ALT]    Request new certificate (ALT = additional domains)
    renew [--force]         Renew all certificates
    revoke DOMAIN           Revoke and delete certificate
    test DOMAIN [PORT]      Test SSL connection (default port 443)
    reload                  Reload web services
    install-hook            Install post-renewal hook
    setup-cron              Setup automatic checks via cron

Options:
    -e, --email EMAIL       Email for Let's Encrypt notifications
    -w, --webroot PATH      Webroot for HTTP challenge
    -t, --threshold DAYS    Alert threshold (default: $RENEWAL_THRESHOLD_DAYS)
    -h, --help              Show this help

Examples:
    $(basename "$0") list
    $(basename "$0") request example.com "www.example.com"
    $(basename "$0") test example.com
    $(basename "$0") renew --force
    $(basename "$0") check

EOF
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    local command="${1:-}"
    shift || true
    
    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--email)
                EMAIL="$2"
                shift 2
                ;;
            -w|--webroot)
                WEBROOT="$2"
                shift 2
                ;;
            -t|--threshold)
                RENEWAL_THRESHOLD_DAYS="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done
    
    case "$command" in
        list|ls)
            list_certificates
            ;;
        check)
            check_root
            check_certificates
            ;;
        info)
            get_cert_info "${1:-}"
            ;;
        request|new)
            check_root
            check_certbot
            request_certificate "$@"
            ;;
        renew)
            check_root
            check_certbot
            if [[ "${1:-}" == "--force" ]]; then
                renew_certificates true
            else
                renew_certificates false
            fi
            ;;
        revoke|delete)
            check_root
            check_certbot
            revoke_certificate "${1:-}"
            ;;
        test)
            test_certificate "${1:-}" "${2:-443}"
            ;;
        reload)
            check_root
            reload_services
            ;;
        install-hook)
            check_root
            install_hook
            ;;
        setup-cron)
            check_root
            setup_cron
            ;;
        ""|help|-h|--help)
            show_help
            ;;
        *)
            echo "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
