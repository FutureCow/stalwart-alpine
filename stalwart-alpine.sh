#!/bin/sh
#
# Stalwart Mail Server - install script for Alpine Linux
#
# Rewritten for Alpine Linux (musl libc, apk, OpenRC) based on the
# community-scripts/ProxmoxVED scripts:
#   - ct/stalwart.sh
#   - install/stalwart-install.sh
# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ) — rewritten for Alpine by Frans Hettinga
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/stalwartlabs/stalwart
#
# Usage:
#   ./stalwart-alpine.sh            # install (or reinstall)
#   ./stalwart-alpine.sh update     # update Stalwart to the latest release
#
# The musl build is used (statically linked) so no gcompat is required.

set -e

# --- Configuration ---------------------------------------------------------
STALWART_DIR="/opt/stalwart"
STALWART_DATA="/opt/stalwart_data"
STALWART_USER="stalwart"
STALWART_GROUP="stalwart"
STALWART_REPO="stalwartlabs/stalwart"
STALWART_URL="https://github.com/${STALWART_REPO}"
ADMIN_PORT=8080

# --- Colors / messages -----------------------------------------------------
if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_NC=''
fi

msg_info()  { printf "${C_BLUE}[INFO]${C_NC} %s\n" "$1"; }
msg_ok()    { printf "${C_GREEN}[ OK ]${C_NC} %s\n" "$1"; }
msg_warn()  { printf "${C_YELLOW}[WARN]${C_NC} %s\n" "$1"; }
msg_error() { printf "${C_RED}[ERR ]${C_NC} %s\n" "$1"; }

error_exit() {
    msg_error "$1"
    exit 1
}

# --- Prerequisites ---------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || error_exit "Run as root (sudo su - or root shell)."
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  STALWART_ARCH="x86_64" ;;
        aarch64|arm64) STALWART_ARCH="aarch64" ;;
        *) error_exit "Unsupported architecture: $(uname -m) (supported: x86_64, aarch64)" ;;
    esac
    STALWART_ASSET="stalwart-${STALWART_ARCH}-unknown-linux-musl.tar.gz"
    msg_info "Architecture: ${STALWART_ARCH} (musl build)"
}

install_deps() {
    msg_info "Installing dependencies (apk)"
    apk add --no-cache curl ca-certificates tar libcap >/dev/null 2>&1
    msg_ok "Dependencies installed"
}

# --- Download & deploy -----------------------------------------------------
download_stalwart() {
    local dest="$1"
    local url="${STALWART_URL}/releases/latest/download/${STALWART_ASSET}"
    local tmp
    tmp="$(mktemp -d)"

    msg_info "Downloading ${STALWART_ASSET}"
    curl -fsSL -o "${tmp}/stalwart.tar.gz" "${url}" \
        || error_exit "Download failed: ${url}"
    msg_ok "Downloaded (${STALWART_ASSET})"

    msg_info "Extracting to ${dest}"
    tar --no-same-owner -xzf "${tmp}/stalwart.tar.gz" -C "${tmp}"
    mkdir -p "${dest}"
    # The archive contains the binary at its root
    cp -f "${tmp}"/stalwart "${dest}/stalwart" 2>/dev/null \
        || find "${tmp}" -name stalwart -type f -exec cp -f {} "${dest}/stalwart" \;
    chmod +x "${dest}/stalwart"
    rm -rf "${tmp}"
    msg_ok "Deployed to ${dest}/stalwart"
}

setup_dirs() {
    msg_info "Configuring Stalwart"
    mkdir -p "${STALWART_DATA}/etc" "${STALWART_DATA}/data" "${STALWART_DATA}/logs"

    if [ ! -f "${STALWART_DATA}/etc/stalwart.env" ]; then
        cat <<EOF >"${STALWART_DATA}/etc/stalwart.env"
# Uncomment and edit an entry to override its default.
# Apply changes with: rc-service stalwart restart

#STALWART_HOSTNAME=mail.example.com
#STALWART_PUBLIC_URL=https://mail.example.com
#STALWART_RECOVERY_MODE=true
#STALWART_RECOVERY_ADMIN=admin:changeme
EOF
        chmod 600 "${STALWART_DATA}/etc/stalwart.env"
    fi

    chown -R "${STALWART_USER}:${STALWART_GROUP}" "${STALWART_DATA}"
    msg_ok "Configured Stalwart"
}

setup_user() {
    if ! getent passwd "${STALWART_USER}" >/dev/null 2>&1; then
        msg_info "Creating user ${STALWART_USER}"
        addgroup -S "${STALWART_GROUP}" 2>/dev/null || true
        adduser -S -H -D -G "${STALWART_GROUP}" -s /sbin/nologin "${STALWART_USER}"
        msg_ok "User ${STALWART_USER} created"
    fi
}

# Allow binding to privileged ports (25, 80, 443, ...) as non-root
set_netcap() {
    if command -v setcap >/dev/null 2>&1; then
        setcap 'cap_net_bind_service=+ep' "${STALWART_DIR}/stalwart" 2>/dev/null \
            && msg_ok "setcap cap_net_bind_service applied" \
            || msg_warn "setcap failed - port 25/80/443 binding needs root (or use >1024 ports)"
    else
        msg_warn "setcap not available - port 25/80/443 binding needs root"
    fi
}

# --- OpenRC service --------------------------------------------------------
create_service() {
    msg_info "Creating OpenRC service"
    cat >/etc/init.d/stalwart <<'EOF'
#!/sbin/openrc-run

name="stalwart"
description="Stalwart Mail Server"
command="/opt/stalwart/stalwart"
command_args="--config=/opt/stalwart_data/etc/config.json"
command_user="stalwart:stalwart"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
directory="/opt/stalwart_data"
output_log="/opt/stalwart_data/logs/stalwart.log"
error_log="/opt/stalwart_data/logs/stalwart.err"
rc_ulimit="-n 65536"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner stalwart:stalwart \
        /opt/stalwart_data /opt/stalwart_data/etc \
        /opt/stalwart_data/data /opt/stalwart_data/logs
    if [ -f /opt/stalwart_data/etc/stalwart.env ]; then
        . /opt/stalwart_data/etc/stalwart.env
        export STALWART_HOSTNAME STALWART_PUBLIC_URL \
               STALWART_RECOVERY_MODE STALWART_RECOVERY_ADMIN
    fi
}
EOF
    chmod +x /etc/init.d/stalwart
    rc-update add stalwart default >/dev/null 2>&1
    msg_ok "OpenRC service created"
}

start_service() {
    msg_info "Starting Stalwart"
    rc-service stalwart start
    msg_ok "Stalwart started"
}

show_summary() {
    local ip
    ip="$(detect_ip)"
    [ -z "$ip" ] && ip="<server-ip>"

    printf "\n"
    msg_ok "Stalwart setup completed successfully!"
    printf "\n"
    printf "${C_GREEN}Access it using the following URL:${C_NC}\n"
    printf "  ${C_BLUE}http://%s:%s/admin${C_NC}\n" "$ip" "$ADMIN_PORT"
    printf "${C_YELLOW}The bootstrap admin password was printed to the service log:${C_NC}\n"
    printf "  ${C_BLUE}grep -A8 'bootstrap mode' /opt/stalwart_data/logs/stalwart.log${C_NC}\n"
    printf "\n"
    printf "Manage the service with: rc-service stalwart {start|stop|restart|status}\n"
    printf "Edit settings in:        ${STALWART_DATA}/etc/stalwart.env (then restart)\n"
}

# Alpine busybox hostname -i/-I werken niet (geen reverse lookup, geen -I optie).
# iproute2 (ip) zit standaard in basis-Alpine en is betrouwbaar.
detect_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {print $2}' | cut -d/ -f1 | head -n1
    elif command -v hostname >/dev/null 2>&1; then
        hostname -i 2>/dev/null | awk '{print $1}'
    fi
}

# --- Update ----------------------------------------------------------------
do_update() {
    require_root
    detect_arch
    [ -f "${STALWART_DIR}/stalwart" ] || error_exit "No Stalwart installation found in ${STALWART_DIR}"

    msg_info "Stopping service"
    rc-service stalwart stop

    download_stalwart "${STALWART_DIR}"
    set_netcap
    chown root:root "${STALWART_DIR}/stalwart"

    msg_info "Starting service"
    rc-service stalwart start
    msg_ok "Updated successfully!"
}

# --- Main ------------------------------------------------------------------
main() {
    require_root
    detect_arch

    case "$1" in
        update) do_update ;;
        *) install ;;
    esac
}

install() {
    msg_info "=== Stalwart Mail Server - Alpine Linux install ==="
    install_deps
    setup_user
    download_stalwart "${STALWART_DIR}"
    set_netcap
    setup_dirs
    create_service
    start_service
    show_summary
}

main "$@"
