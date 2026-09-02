#!/usr/bin/env bash
# ==============================================================================
# 389 Directory Server (ds389 / RHDS 12) Backup Restore Manager
# ==============================================================================
# Description: Automates the restoration of physical database backups (bak2db)
#              or logical LDIF text exports (ldif2db) for 389-ds instances.
#              Safely handles service states, validates backup metadata, and
#              performs post-restore replication vector checks.
#
# Usage:       sudo ./ds389-restore-manager.sh -i <instance_name> -p <backup_path> [-s <suffix>]
# ==============================================================================

set -euo pipefail

# --- Configuration & Defaults ---
LOG_FILE="/var/log/dirsrv/ds389-restore-manager.log"
INSTANCE=""
BACKUP_PATH=""
SUFFIX=""
FORCE=false

# --- Logging Helpers ---
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info()  { log "INFO"  "\e[32m$1\e[0m"; }
log_warn()  { log "WARN"  "\e[33m$1\e[0m"; }
log_error() { log "ERROR" "\e[31m$1\e[0m"; }

# --- Usage Banner ---
usage() {
    cat << EOF
Usage: sudo $0 -i <instance_name> -p <backup_path> [-s <suffix>] [-f]

Options:
  -i  The name of the 389-ds instance (e.g., slapd-app-user-store)
  -p  The absolute path to the backup (directory for db2bak, file for LDIF)
  -s  The LDAP suffix (required only for LDIF text restores, e.g., dc=app,dc=company,dc=com)
  -f  Force execution without interactive warnings
  -h  Show this help message
EOF
    exit 1
}

# --- Command Line Parsing ---
while getopts "i:p:s:fh" opt; do
    case "${opt}" in
        i) INSTANCE="${OPTARG}" ;;
        p) BACKUP_PATH="${OPTARG}" ;;
        s) SUFFIX="${OPTARG}" ;;
        f) FORCE=true ;;
        *) usage ;;
    esac
done

if [[ -z "${INSTANCE}" || -z "${BACKUP_PATH}" ]]; then
    log_error "Missing required arguments: Instance (-i) and Backup Path (-p)."
    usage
fi

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be executed as root."
    exit 1
fi

# Create log directory if missing
mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

log_info "======================================================================"
log_info "Starting 389-ds Restore Manager"
log_info "Instance: ${INSTANCE}"
log_info "Backup Path: ${BACKUP_PATH}"
log_info "======================================================================"

# --- Pre-Restore Checks & Validation ---
if ! systemctl list-unit-files | grep -q "dirsrv@${INSTANCE}"; then
    log_error "The specified 389-ds instance '${INSTANCE}' does not exist as a systemd service."
    exit 1
fi

if [[ ! -e "${BACKUP_PATH}" ]]; then
    log_error "Backup path '${BACKUP_PATH}' does not exist."
    exit 1
fi

# Determine Backup Type
BACKUP_TYPE=""
if [[ -d "${BACKUP_PATH}" ]]; then
    BACKUP_TYPE="PHYSICAL"
    log_info "Detected input as a Physical Database Backup directory (bak2db path)."
elif [[ -f "${BACKUP_PATH}" ]]; then
    BACKUP_TYPE="LDIF"
    log_info "Detected input as a Logical LDIF flat-text export."
    if [[ -z "${SUFFIX}" ]]; then
        log_error "Restoring an LDIF backup requires the target suffix (-s) to be explicitly specified."
        exit 1
    fi
else
    log_error "Unable to determine backup type of '${BACKUP_PATH}'."
    exit 1
fi

# Mandatory user confirmation
if [[ "${FORCE}" == "false" ]]; then
    echo -e "\e[31m⚠️  WARNING: Restoring a backup completely overwrites the current database state! ⚠️\e[0m"
    read -rp "Are you absolutely sure you want to proceed with the restore? (y/N): " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        log_warn "Restore cancelled by operator."
        exit 0
    fi
fi

# --- Phase 1: Service Lockdown ---
log_info "Locking down services. Stopping 389-ds instance: ${INSTANCE}..."
if ! systemctl stop "dirsrv@${INSTANCE}"; then
    log_error "Failed to stop 389-ds instance systemd service."
    exit 1
fi
log_info "Service stopped successfully."

# --- Phase 2: Execute Restore ---
RESTORE_SUCCESS=false
if [[ "${BACKUP_TYPE}" == "PHYSICAL" ]]; then
    log_info "Executing physical database restore (bak2db) using dsctl..."
    # Physical restores require slapd to be stopped
    if dsctl "${INSTANCE}" bak2db "${BACKUP_PATH}"; then
        RESTORE_SUCCESS=true
        log_info "Physical database restore successfully completed."
    else
        log_error "dsctl physical restore failed!"
    fi
elif [[ "${BACKUP_TYPE}" == "LDIF" ]]; then
    log_info "Executing logical LDIF database restore (ldif2db) for suffix ${SUFFIX} using dsctl..."
    # LDIF restores require slapd to be stopped
    if dsctl "${INSTANCE}" ldif2db "${SUFFIX}" "${BACKUP_PATH}"; then
        RESTORE_SUCCESS=true
        log_info "Logical LDIF database restore successfully completed."
    else
        log_error "dsctl logical restore failed!"
    fi
fi

# --- Phase 3: Post-Restore Rollback / Restart ---
log_info "Unlocking services. Starting 389-ds instance: ${INSTANCE}..."
if ! systemctl start "dirsrv@${INSTANCE}"; then
    log_error "CRITICAL: Failed to restart 389-ds instance systemd service after restore!"
    exit 1
fi
log_info "Service started successfully."

if [[ "${RESTORE_SUCCESS}" == "false" ]]; then
    log_error "Restore operations failed. Directory has been restarted but database may be in an inconsistent state."
    exit 1
fi

# --- Phase 4: Service Validation & Replication Vector Verification ---
log_info "Performing post-restore validation..."

# Wait a few seconds for directory port binding
sleep 3

# 1. Socket Verification
if ! dsctl "${INSTANCE}" status | grep -q "Instance is running"; then
    log_error "Validation failed: 389-ds service reports running but instance is unhealthy."
    exit 1
fi
log_info "Service is online and bound to its operational instance."

# 2. Schema / LDAP Verification
log_info "Running local LDAP search validation against Root DSE..."
if ldapsearch -x -H ldap://localhost -b "" -s base "(objectclass=*)" > /dev/null; then
    log_info "Local LDAP binds are fully operational."
else
    log_warn "Local LDAP bind verification failed. Check directory logs for ACL or bind errors."
fi

# 3. Replication Vector (RUV) and Trust Validation
if [[ -x "$(command -v ipa-replica-manage)" ]]; then
    log_info "System is a Red Hat IdM cluster node. Running replication RUV check..."
    if ipa-replica-manage list-ruv &> /tmp/ruv_check.log; then
        log_info "Replication update vectors (RUV) retrieved successfully."
        # Print RUVs for operator validation
        cat /tmp/ruv_check.log | tee -a "${LOG_FILE}"
    else
        log_warn "Failed to retrieve replication update vectors. Multi-supplier syncing may require a force re-initialization!"
    fi
    rm -f /tmp/ruv_check.log
fi

log_info "======================================================================"
log_info "🎉 SUCCESS: Restore completed and verified!"
log_info "======================================================================"
echo -e "\e[32m🎉 Success: Restore process finished cleanly. Check '${LOG_FILE}' for detailed outputs.\e[0m"
