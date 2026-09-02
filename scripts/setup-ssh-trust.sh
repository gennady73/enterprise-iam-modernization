#!/usr/bin/env bash
# =============================================================================
# Script Name:  setup-ssh-trust.sh
# Description:  Automates SSH key generation, host key scanning, and key 
#               propagation (ssh-copy-id) across all inventory hosts defined
#               in hosts.ini to prepare for passwordless Ansible automation.
# Version:      1.0.0
# Author:       Gemini Notebook
# Requirements: OpenSSH client, bash, and a valid hosts.ini file.
# =============================================================================

set -euo pipefail

# --- COLOR SCHEME ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- LOGGING ---
log_info() { echo -e "$(date '+%F %T') [${GREEN}INFO${NC}] - $1"; }
log_warn() { echo -e "$(date '+%F %T') [${YELLOW}WARN${NC}] - $1"; }
log_error() { echo -e "$(date '+%F %T') [${RED}ERROR${NC}] - $1" >&2; }

# --- DEFAULT INVENTORY PATH ---
INVENTORY_FILE="${1:-hosts.ini}"

# --- CHECK PRIVILEGES ---
# This script runs in user space to set up keys for the current deployer user.
# Do not run as root unless your Ansible deployer user is root.
if [[ $EUID -eq 0 ]]; then
    log_warn "Running as root. SSH keys will be generated and distributed for the root account."
fi

# --- VALIDATE INVENTORY FILE ---
if [[ ! -f "${INVENTORY_FILE}" ]]; then
    log_error "Inventory file '${INVENTORY_FILE}' not found!"
    echo "Usage: $0 [/path/to/hosts.ini]"
    exit 1
fi

log_info "Reading inventory file: ${INVENTORY_FILE}"

# --- PARSE INVENTORY ---
# Dynamically extract ansible_user, ansible_ssh_private_key_file, and host definitions.
SSH_USER=$(grep -E "^ansible_user\s*=" "${INVENTORY_FILE}" | cut -d'=' -f2 | tr -d ' ' || true)
SSH_KEY_PATH=$(grep -E "^ansible_ssh_private_key_file\s*=" "${INVENTORY_FILE}" | cut -d'=' -f2 | tr -d ' ' || true)

# Default Fallbacks if not defined in the INVENTORY_FILE variables
SSH_USER="${SSH_USER:-admin_provisioner}"
SSH_KEY_PATH="${SSH_KEY_PATH:-~/.ssh/id_rsa_provisioner}"

# Expand tilde in key path
eval SSH_KEY_PATH="${SSH_KEY_PATH}"
SSH_PUB_KEY_PATH="${SSH_KEY_PATH}.pub"

log_info "Parsed Configuration:"
echo "  - Deployer SSH User: ${SSH_USER}"
echo "  - Private Key Path:  ${SSH_KEY_PATH}"
echo "  - Public Key Path:   ${SSH_PUB_KEY_PATH}"

# --- MANAGE SSH KEYPAIR ---
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    log_warn "Target private key '${SSH_KEY_PATH}' does not exist."
    read -rp "Would you like to generate a new secure 4096-bit RSA keypair now? (y/N): " gen_key
    if [[ "${gen_key}" =~ ^[Yy]$ ]]; then
        mkdir -p "$(dirname "${SSH_KEY_PATH}")"
        chmod 700 "$(dirname "${SSH_KEY_PATH}")"
        ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -q
        log_info "Secure keypair successfully generated."
    else
        log_error "Private key is required to proceed. Exiting."
        exit 1
    fi
fi

if [[ ! -f "${SSH_PUB_KEY_PATH}" ]]; then
    log_info "Extracting public key from existing private key..."
    ssh-keygen -y -f "${SSH_KEY_PATH}" > "${SSH_PUB_KEY_PATH}"
    chmod 644 "${SSH_PUB_KEY_PATH}"
fi

# --- EXTRACT TARGET HOSTS AND IPS ---
log_info "Extracting target hosts and IP addresses..."

# Parse hosts, filtering out comments, empty lines, and group headers.
# This extracts the actual hostname/FQDN and the ansible_host=IP value.
mapfile -t INVENTORY_ENTRIES < <(grep -E "^[a-zA-Z0-9.-]+" "${INVENTORY_FILE}" | grep -v "=" | grep -v "\[" || true)
mapfile -t INLINE_HOSTS < <(grep -E "^[a-zA-Z0-9.-]+\s+ansible_host=" "${INVENTORY_FILE}" || true)

# Combine and unique all targets
declare -A HOSTS_MAP

for entry in "${INVENTORY_ENTRIES[@]}"; do
    host=$(echo "${entry}" | awk '{print $1}')
    if [[ -n "${host}" ]]; then
        HOSTS_MAP["${host}"]="${host}"
    fi
done

for entry in "${INLINE_HOSTS[@]}"; do
    host=$(echo "${entry}" | awk '{print $1}')
    ip=$(echo "${entry}" | grep -oE "ansible_host=[0-9.]+" | cut -d'=' -f2 || true)
    if [[ -n "${host}" ]]; then
        HOSTS_MAP["${host}"]="${host}"
    fi
    if [[ -n "${ip}" ]]; then
        HOSTS_MAP["${ip}"]="${ip}"
    fi
done

log_info "Found ${#HOSTS_MAP[@]} unique network endpoints to trust."

# --- START SSH-AGENT FOR CONVENIENCE ---
log_info "Configuring SSH key agent session..."
eval "$(ssh-agent -s)"
ssh-add "${SSH_KEY_PATH}"

# --- PROCESS ENDPOINTS ---
SUCCESS_COUNT=0
FAILED_COUNT=0
declare -a FAILED_HOSTS

for target in "${!HOSTS_MAP[@]}"; do
    echo -e "\n----------------------------------------------------------------------"
    log_info "Processing Endpoint: ${target}"
    echo "----------------------------------------------------------------------"

    # 1. Host Key Scanning (Populate known_hosts to prevent dynamic prompts)
    log_info "Scanning host keys for ${target}..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/known_hosts
    chmod 600 ~/.ssh/known_hosts

    # Temp key-scan to check online state
    if ! KEY_SCAN_DATA=$(ssh-keyscan -T 5 "${target}" 2>/dev/null) || [[ -z "${KEY_SCAN_DATA}" ]]; then
        log_error "Target endpoint '${target}' is offline or port 22 is closed."
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_HOSTS+=("${target} (Offline/Timeout)")
        continue
    fi

    # Remove stale entries and append fresh scan
    ssh-keygen -R "${target}" &>/dev/null || true
    echo "${KEY_SCAN_DATA}" >> ~/.ssh/known_hosts

    # 2. Distribute Public Key using ssh-copy-id
    log_info "Copying public key to ${target} as user '${SSH_USER}'..."
    echo "Enter password for '${SSH_USER}@${target}' if prompted:"
    
    if ssh-copy-id -i "${SSH_PUB_KEY_PATH}" "${SSH_USER}@${target}" &>/dev/null; then
        log_info "SSH trust successfully established with ${target}!"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        # Fallback manual distribution attempt
        log_warn "ssh-copy-id failed. Attempting manual key append..."
        PUB_KEY_CONTENT=$(cat "${SSH_PUB_KEY_PATH}")
        if ssh -o BatchMode=no "${SSH_USER}@${target}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${PUB_KEY_CONTENT}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" &>/dev/null; then
            log_info "Manual SSH trust successfully established with ${target}!"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            log_error "Failed to establish trust with ${target}."
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAILED_HOSTS+=("${target} (Auth Refused/Password incorrect)")
        fi
    fi
done

# --- PRINT RUN SUMMARY ---
echo -e "\n======================================================================"
log_info "SSH Trust Establishment Run Summary"
echo "======================================================================"
echo "  - Total Endpoints Scanned: $((${SUCCESS_COUNT} + ${FAILED_COUNT}))"
echo "  - Successful Trusts:       ${SUCCESS_COUNT}"
echo "  - Failed Endpoints:        ${FAILED_COUNT}"

if [[ ${FAILED_COUNT} -gt 0 ]]; then
    echo -e "\n${RED}Failed Targets:${NC}"
    for f_host in "${FAILED_HOSTS[@]}"; do
        echo "  - ${f_host}"
    done
    exit 2
else
    echo -e "\n${GREEN}All host endpoints have been successfully trusted!${NC}"
    log_info "Ansible can now run passwordless tasks against your entire hosts.ini inventory."
fi
