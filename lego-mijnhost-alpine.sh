#!/bin/sh
#
# lego + mijn.host - ACME/Let's Encrypt certificaten voor Stalwart op Alpine
#
# Haalt automatisch vernieuwde TLS-certificaten op via de mijn.host
# DNS-API (DNS-01 challenge) en laadt ze in Stalwart:
#   - lego CLI (go-acme/lego) met mijnhost DNS-provider
#   - stalwart-cli (stalwartlabs/cli) voor ReloadTlsCertificates
#
# Waarom dit script? Stalwart's ingebouwde ACME ondersteunt mijn.host
# niet als DNS-provider (70 providers, maar mijnhost ontbreekt). lego
# ondersteunt mijnhost wél sinds v4.18.0 (MIJNHOST_API_KEY).
#
# Usage:
#   ./lego-mijnhost-alpine.sh            # installeren + eerste certificaat-aanvraag
#   ./lego-mijnhost-alpine.sh renew      # renewals draaien (cron)
#   ./lego-mijnhost-alpine.sh cron       # cron-job installeren (maandelijks)
#   ./lego-mijnhost-alpine.sh install    # alleen binaries + config installeren
#
# Na installatie de certificaten in Stalwart koppelen:
#   Settings > TLS > Certificates > Nieuw Certificate-object met:
#     certificate:  File -> /etc/lego/certificates/<domein>.crt
#     privateKey:   File -> /etc/lego/certificates/<domein>.key
#
# License: MIT (zie https://github.com/FutureCow/stalwart-alpine)

set -e

# --- Configuratie ----------------------------------------------------------
LEGO_VERSION="${LEGO_VERSION:-latest}"
LEGO_DIR="/etc/lego"
LEGO_BIN="/usr/local/bin/lego"
CLI_BIN="/usr/local/bin/stalwart-cli"
ENV_FILE="${LEGO_DIR}/lego.env"
DOMAINS_FILE="${LEGO_DIR}/domains.conf"
CRON_SCHEDULE="0 3 1 * *"   # 1e van de maand, 03:00

# --- Kleuren / berichten ---------------------------------------------------
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
    [ "$(id -u)" -eq 0 ] || error_exit "Run as root."
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  LEGO_ARCH="amd64"; CLI_TARGET="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) LEGO_ARCH="arm64"; CLI_TARGET="aarch64-unknown-linux-musl" ;;
        *) error_exit "Unsupported architecture: $(uname -m) (supported: x86_64, aarch64)" ;;
    esac
    msg_info "Architecture: $(uname -m)"
}

# --- Installatie -----------------------------------------------------------
install_lego() {
    if [ -x "${LEGO_BIN}" ]; then
        msg_ok "lego al geïnstalleerd: $("${LEGO_BIN}" --version 2>/dev/null | head -n1)"
        return
    fi
    local ver url tmp
    if [ "${LEGO_VERSION}" = "latest" ]; then
        ver="$(curl -fsSL "https://api.github.com/repos/go-acme/lego/releases/latest" \
            | grep -o '"tag_name":[^,]*' | head -n1 | cut -d'"' -f4 | tr -d 'v')"
    else
        ver="${LEGO_VERSION}"
    fi
    [ -n "$ver" ] || error_exit "Kon lego-versie niet ophalen"

    tmp="$(mktemp -d)"
    url="https://github.com/go-acme/lego/releases/download/v${ver}/lego_v${ver}_linux_${LEGO_ARCH}.tar.gz"
    msg_info "Downloaden lego v${ver} (${LEGO_ARCH})"
    curl -fsSL -o "${tmp}/lego.tar.gz" "${url}" || error_exit "Download mislukt: ${url}"
    tar --no-same-owner -xzf "${tmp}/lego.tar.gz" -C "${tmp}" lego
    cp "${tmp}/lego" "${LEGO_BIN}"
    chmod +x "${LEGO_BIN}"
    rm -rf "${tmp}"
    msg_ok "lego geïnstalleerd: $("${LEGO_BIN}" --version 2>/dev/null | head -n1)"
}

install_cli() {
    if [ -x "${CLI_BIN}" ]; then
        msg_ok "stalwart-cli al geïnstalleerd: $("${CLI_BIN}" --version 2>/dev/null | head -n1)"
        return
    fi
    local tmp
    tmp="$(mktemp -d)"
    # .tar.xz archief: zorg dat xz beschikbaar is
    if ! command -v xz >/dev/null 2>&1; then
        msg_info "xz installeren (nodig voor stalwart-cli archief)"
        apk add --no-cache xz >/dev/null 2>&1
    fi
    msg_info "Downloaden stalwart-cli (${CLI_TARGET})"
    curl -fsSL -o "${tmp}/cli.tar.xz" \
        "https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-${CLI_TARGET}.tar.xz" \
        || error_exit "Download mislukt (stalwart-cli)"
    tar --no-same-owner -xJf "${tmp}/cli.tar.xz" -C "${tmp}"
    cp "${tmp}"/stalwart-cli-*/stalwart-cli "${CLI_BIN}"
    chmod +x "${CLI_BIN}"
    rm -rf "${tmp}"
    msg_ok "stalwart-cli geïnstalleerd: $("${CLI_BIN}" --version 2>/dev/null | head -n1)"
}

# --- Config ----------------------------------------------------------------
setup_config() {
    mkdir -p "${LEGO_DIR}"
    chmod 700 "${LEGO_DIR}"

    if [ ! -f "${ENV_FILE}" ]; then
        cat >"${ENV_FILE}" <<EOF
# mijn.host API-key (verplicht) - https://mijn.host/api/doc
MIJNHOST_API_KEY=

# Contact-e-mail voor Let's Encrypt (verplicht)
LEGO_EMAIL=

# Stalwart CLI verbinding (voor reload na renewal).
# Gebruik OF een API-key (STALWART_TOKEN, aanbevolen) OF user/password:
STALWART_URL=http://localhost:8080
#STALWART_TOKEN=
STALWART_USER=admin
STALWART_PASSWORD=

# Optioneel: ACME-server (test: https://acme-staging-v02.api.letsencrypt.org/directory)
#LEGO_SERVER=https://acme-v02.api.letsencrypt.org/directory
EOF
        chmod 600 "${ENV_FILE}"
        msg_warn "Vul ${ENV_FILE} in (MIJNHOST_API_KEY, LEGO_EMAIL + STALWART_TOKEN of STALWART_PASSWORD)"
    fi

    if [ ! -f "${DOMAINS_FILE}" ]; then
        cat >"${DOMAINS_FILE}" <<EOF
# Eén domein per regel. Wildcards: *.domein.nl (vereist DNS-01)
# mail.domein1.nl
# mail.domein2.nl
# *.domein3.nl
EOF
        msg_warn "Vul ${DOMAINS_FILE} in (één domein per regel)"
    fi
}

load_env() {
    # Source de env-file (alleen niet-commentaar regels)
    [ -f "${ENV_FILE}" ] || error_exit "Config ontbreekt: ${ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
    set +a
}

# --- Certificaten ----------------------------------------------------------
build_lego_args() {
    LEGO_ARGS="run --dns mijnhost --path ${LEGO_DIR} --email ${LEGO_EMAIL}"
    [ -n "${LEGO_SERVER:-}" ] && LEGO_ARGS="${LEGO_ARGS} --server ${LEGO_SERVER}"
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        case "$domain" in \#*) continue ;; esac
        LEGO_ARGS="${LEGO_ARGS} --domains ${domain}"
    done <"${DOMAINS_FILE}"
}

reload_stalwart() {
    msg_info "Stalwart TLS-certificaten herladen"
    if [ -n "${STALWART_TOKEN:-}" ]; then
        # Aanbevolen: API-key (Bearer token)
        "${CLI_BIN}" --url "${STALWART_URL}" \
            --api-key "${STALWART_TOKEN}" \
            create x:Action/ReloadTlsCertificates 2>&1 \
            | tail -n2 || msg_warn "Reload mislukt - controleer STALWART_TOKEN in ${ENV_FILE}"
    elif [ -n "${STALWART_PASSWORD:-}" ]; then
        # Fallback: basic auth (user/password)
        "${CLI_BIN}" --url "${STALWART_URL}" --user "${STALWART_USER}" \
            --password "${STALWART_PASSWORD}" \
            create x:Action/ReloadTlsCertificates 2>&1 \
            | tail -n2 || msg_warn "Reload mislukt - controleer STALWART_* in ${ENV_FILE}"
    else
        msg_warn "STALWART_TOKEN of STALWART_PASSWORD niet gezet - reload overgeslagen"
    fi
}

do_issue() {
    load_env
    build_lego_args
    msg_info "Certificaten aanvragen (DNS-01 via mijn.host)"
    # shellcheck disable=SC2086
    "${LEGO_BIN}" ${LEGO_ARGS} --deploy-hook "sh ${0} reload"
    msg_ok "Certificaten opgehaald in ${LEGO_DIR}/certificates/"
    show_summary
}

do_renew() {
    load_env
    build_lego_args
    msg_info "Renewals controleren"
    # lego v5: 'run' doet zowel eerste aanvraag als renewals (geen apart 'renew'-commando meer).
    # Domeinen zijn ook bij renewal verplicht.
    # shellcheck disable=SC2086
    "${LEGO_BIN}" ${LEGO_ARGS} --renew-days 30 \
        --deploy-hook "sh ${0} reload" || true
    msg_ok "Renew gedaan (lego vernieuwt alleen als nodig)"
}

do_reload() {
    load_env
    reload_stalwart
}

# --- Cron ------------------------------------------------------------------
install_cron() {
    load_env
    local cron_line="${CRON_SCHEDULE} root ${0} renew >> /var/log/lego-renew.log 2>&1"
    if [ -f /etc/crontabs/root ] && grep -qF "${0} renew" /etc/crontabs/root 2>/dev/null; then
        msg_ok "Cron-job bestaat al"
    else
        # Verwijder eventuele oude/andere lego-cronregels en voeg de juiste toe
        sed -i "/lego-mijnhost-alpine\.sh renew/d; /\/lego -cron/d" /etc/crontabs/root 2>/dev/null || true
        echo "${cron_line}" >>/etc/crontabs/root
        msg_ok "Cron-job toegevoegd: ${CRON_SCHEDULE} (maandelijks, 03:00)"
    fi
}

# --- Samenvatting ----------------------------------------------------------
show_summary() {
    printf "\n"
    msg_ok "Setup voltooid!"
    printf "\n"
    printf "${C_GREEN}Certificaten:${C_NC}\n"
    ls -1 "${LEGO_DIR}/certificates/" 2>/dev/null | grep -E "\.(crt|key)$" | sed 's/^/  /' || true
    printf "\n"
    printf "${C_YELLOW}Koppel ze in Stalwart:${C_NC}\n"
    printf "  Settings > TLS > Certificates > Certificate-object:\n"
    printf "    certificate:  File -> ${LEGO_DIR}/certificates/<domein>.crt\n"
    printf "    privateKey:   File -> ${LEGO_DIR}/certificates/<domein>.key\n"
    printf "\n"
    printf "Renewal (handmatig):  ${0} renew\n"
    printf "Cron installeren:     ${0} cron\n"
}

# --- Main ------------------------------------------------------------------
main() {
    require_root
    detect_arch

    case "$1" in
        install) install_lego; install_cli; setup_config; show_summary ;;
        renew)   do_renew ;;
        reload)  do_reload ;;
        cron)    install_cron ;;
        *)       install_lego; install_cli; setup_config; do_issue ;;
    esac
}

main "$@"
