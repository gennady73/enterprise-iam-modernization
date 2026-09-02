#!/usr/bin/env bash
# ==============================================================================
# Script Name:  ds389-backup-manager.sh
# Description:  Automated production-grade backup, verification, and rotation
#               manager for 389 Directory Server (RHDS 12 / ds389).
# Version:      1.0.0
# Author:       Gemini Notebook
# Requirements: 389-ds-base package installed, root privileges, and systemd.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -o pipefail

# --- CONFIGURATION (Customize via Environment Variables or defaults) ---
INSTANCE_NAME="${DS_INSTANCE_NAME:-slapd-app-user-store}"
BACKUP_PARENT_DIR="${DS_BACKUP_DIR:-/var/lib/dirsrv/backups}"
RETENTION_DAYS="${DS_RETENTION_DAYS:-14}"
LOG_FILE="${DS_LOG_FILE:-/var/log/dirsrv/ds389-backup-manager.log}"
SUFFIX="${DS_SUFFIX:-dc=app,dc=company,dc=com}"

# --- COLOR SCHEME FOR LOGGING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- LOGGING FUNCTIONS ---
log_info() {
    local msg="$1"
    echo -e "$(date '+%F %T') [${GREEN}INFO${NC}] - ${msg}" | tee -a "${LOG_FILE}"
}

log_warn() {
    local msg="$1"
    echo -e "$(date '+%F %T') [${YELLOW}WARN${NC}] - ${msg}" | tee -a "${LOG_FILE}"
}

log_error() {
    local msg="$1"
    echo -e "$(date '+%F %T') [${RED}ERROR${NC}] - ${msg}" >&2 | tee -a "${LOG_FILE}"
}

# --- ROOT PRIVILEGES CHECK ---
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (or with sudo privileges)."
    exit 1
fi

# --- PREREQUISITES VALIDATION ---
log_info "Starting validation of 389-ds prerequisites..."

# Verify dsctl command exists
if ! command -v dsctl &> /dev/null; then
    log_error "The 'dsctl' administration tool could not be found. Is 389-ds installed?"
    exit 1
fi

# Verify the instance is valid and configured
if ! dsctl "${INSTANCE_NAME}" status &> /dev/null; then
    log_error "389-ds instance '${INSTANCE_NAME}' does not exist or cannot be reached."
    exit 1
fi

# Initialize Log File if not present
if [[ ! -f "${LOG_FILE}" ]]; then
    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"
    chown dirsrv:dirsrv "${LOG_FILE}" 2>/dev/null || true
fi

# Determine Backend Database Name dynamically
BACKEND_NAME=$(dsctl "${INSTANCE_NAME}" suffix list 2>/dev/null | grep -E "\(${SUFFIX}\)" | awk '{print $2}' | tr -d '()')
if [[ -z "${BACKEND_NAME}" ]]; then
    log_warn "Could not resolve backend name for suffix '${SUFFIX}'. Defaulting to 'userroot'."
    BACKEND_NAME="userroot"
fi

# Ensure backup parent directory exists with safe permissions
mkdir -p "${BACKUP_PARENT_DIR}"
chmod 700 "${BACKUP_PARENT_DIR}"
chown dirsrv:dirsrv "${BACKUP_PARENT_DIR}" 2>/dev/null || true

# --- INITIALIZE RUN VARIABLES ---
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="${BACKUP_PARENT_DIR}/ds_backup_${TIMESTAMP}"
LDIF_FILE="${RUN_DIR}/${INSTANCE_NAME}_backup_${TIMESTAMP}.ldif"
BAK_DIR="${RUN_DIR}/${INSTANCE_NAME}_db_bak"

mkdir -p "${RUN_DIR}"
chmod 700 "${RUN_DIR}"
chown dirsrv:dirsrv "${RUN_DIR}" 2>/dev/null || true

log_info "Backup run initiated. Destination directory: ${RUN_DIR}"

# ==============================================================================
# STEP 1: EXECUTE PORTABLE TEXT BACKUP (db2ldif)
# ==============================================================================
log_info "Executing LDIF database export for suffix '${SUFFIX}' (Backend: ${BACKEND_NAME})..."

# db2ldif can be run online safely. It exports to text LDIF format
if dsctl "${INSTANCE_NAME}" db2ldif "${BACKEND_NAME}" -o "${LDIF_FILE}" &>> "${LOG_FILE}"; then
    log_info "LDIF export successfully completed."
    chmod 600 "${LDIF_FILE}"
else
    log_error "LDIF export failed! Check the system and directory logs for details."
    exit 2
fi

# ==============================================================================
# STEP 2: EXECUTE PHYSICAL BINARY DATABASE BACKUP (db2bak)
# ==============================================================================
log_info "Executing binary database backup (db2bak)..."

# db2bak performs an online physical hot backup of the directory's Berkeley DB
if dsctl "${INSTANCE_NAME}" db2bak "${BAK_DIR}" &>> "${LOG_FILE}"; then
    log_info "Physical binary database backup successfully completed."
    chmod -R 700 "${BAK_DIR}"
else
    log_error "Physical binary database backup (db2bak) failed!"
    exit 2
fi

# ==============================================================================
# STEP 3: VERIFICATION AND INTEGRITY CHECKS
# ==============================================================================
log_info "Running validation and verification sweeps on backup assets..."

# Check file sizes
if [[ ! -f "${LDIF_FILE}" ]] || [[ ! -s "${LDIF_FILE}" ]]; then
    log_error "Verification Failed: LDIF export file is empty or missing!"
    exit 3
fi

LDIF_SIZE=$(du -sh "${LDIF_FILE}" | awk '{print $1}')
log_info "Verification Passed: Portable LDIF backup exists (${LDIF_SIZE})."

# Validate binary database directory files
if [[ ! -d "${BAK_DIR}" ]] || [[ -z "$(ls -A "${BAK_DIR}")" ]]; then
    log_error "Verification Failed: Binary database backup directory is empty or missing!"
    exit 3
fi

BAK_SIZE=$(du -sh "${BAK_DIR}" | awk '{print $1}')
log_info "Verification Passed: Binary database backup exists (${BAK_SIZE})."

# Ensure the live service is functional and responding post-backup
if dsctl "${INSTANCE_NAME}" status &>/dev/null; then
    log_info "Directory service status check: [${GREEN}OK${NC}] - Service is online."
else
    log_warn "Directory service status check: [${YELLOW}WARNING${NC}] - Instance seems offline or unresponsive post-backup."
fi

# ==============================================================================
# STEP 4: RETENTION POLICIES AND ROTATION
# ==============================================================================
log_info "Applying retention policies (Retention Period: ${RETENTION_DAYS} days)..."

# Find and log backup sets scheduled for deletion
OLD_BACKUPS=$(find "${BACKUP_PARENT_DIR}" -mindepth 1 -maxdepth 1 -type d -name "ds_backup_*" -mtime +"${RETENTION_DAYS}")

if [[ -n "${OLD_BACKUPS}" ]]; then
    log_info "The following obsolete backup sets are scheduled for deletion:"
    echo "${OLD_BACKUPS}" | while read -r old_dir; do
        log_info "  - Removing directory: ${old_dir}"
        rm -rf "${old_dir}"
    done
    log_info "Retention cleanup successfully completed."
else
    log_info "No obsolete backups found. Nothing to rotate."
fi

# ==============================================================================
# STEP 5: COMPILING DISK HEALTH REPORT
# ==============================================================================
DISK_USAGE=$(df -h "${BACKUP_PARENT_DIR}" | tail -n 1 | awk '{print $5}')
DISK_AVAIL=$(df -h "${BACKUP_PARENT_DIR}" | tail -n 1 | awk '{print $4}')

log_info "Disk Health Report: Backup partition is ${DISK_USAGE} full (${DISK_AVAIL} available)."
log_info "All tasks successfully executed. Backup run: [${GREEN}SUCCESS${NC}]."
exit 0
