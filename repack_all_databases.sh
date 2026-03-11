#!/bin/bash
# ============================================================
#  repack_all_databases.sh
#  pg_repack – Reclaim unused space across all PostgreSQL databases
#
#  Usage : ./repack_all_databases.sh
#  Cron  : 0 2 * * 0 /path/to/repack_all_databases.sh
# ============================================================

set -euo pipefail

# -------------------- Configuration -------------------------
PGUSER="${PGUSER:-postgres}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PARALLEL_JOBS=2                          # Number of parallel workers
LOG_DIR="/var/log/pg_repack"
LOG_FILE="${LOG_DIR}/repack_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/tmp/pg_repack.lock"
RETAIN_LOGS_DAYS=30                      # Auto-delete logs older than N days
# ------------------------------------------------------------

# -------------------- Functions -----------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cleanup() {
    rm -f "$LOCK_FILE"
    log "Lock file removed. Script finished."
}

check_prerequisites() {
    if ! command -v pg_repack &>/dev/null; then
        log "ERROR: pg_repack binary not found in PATH."
        exit 1
    fi

    if ! command -v psql &>/dev/null; then
        log "ERROR: psql binary not found in PATH."
        exit 1
    fi
}

rotate_logs() {
    if [ -d "$LOG_DIR" ]; then
        find "$LOG_DIR" -name "repack_*.log" -type f -mtime +${RETAIN_LOGS_DAYS} -delete 2>/dev/null || true
        log "Old logs (>${RETAIN_LOGS_DAYS} days) cleaned up."
    fi
}
# ------------------------------------------------------------

# -------------------- Lock Guard ----------------------------
if [ -f "$LOCK_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Another instance is already running (lock: $LOCK_FILE). Exiting."
    exit 1
fi
trap cleanup EXIT
touch "$LOCK_FILE"
# ------------------------------------------------------------

# -------------------- Main ----------------------------------
mkdir -p "$LOG_DIR"

log "=========================================="
log "pg_repack – Full Instance Repack Started"
log "Host: ${PGHOST}  Port: ${PGPORT}  User: ${PGUSER}"
log "Parallel Jobs: ${PARALLEL_JOBS}"
log "=========================================="

check_prerequisites
rotate_logs

# Get list of all user databases (exclude templates & postgres)
DATABASES=$(psql -U "$PGUSER" -h "$PGHOST" -p "$PGPORT" -Atc \
    "SELECT datname FROM pg_database
     WHERE datistemplate = false
       AND datname NOT IN ('postgres')
     ORDER BY datname;")

if [ -z "$DATABASES" ]; then
    log "No user databases found. Nothing to do."
    exit 0
fi

TOTAL=0
SUCCESS=0
FAILED=0

for DB in $DATABASES; do
    TOTAL=$((TOTAL + 1))
    log "--------------------------------------"
    log "Starting repack: $DB"
    log "--------------------------------------"

    # Ensure the pg_repack extension exists in this database
    psql -U "$PGUSER" -h "$PGHOST" -p "$PGPORT" -d "$DB" -c \
        "CREATE EXTENSION IF NOT EXISTS pg_repack;" 2>&1 | tee -a "$LOG_FILE"

    # Run pg_repack
    if pg_repack -U "$PGUSER" -h "$PGHOST" -p "$PGPORT" -d "$DB" -j "$PARALLEL_JOBS" 2>&1 | tee -a "$LOG_FILE"; then
        SUCCESS=$((SUCCESS + 1))
        log "✔  Completed successfully: $DB"
    else
        FAILED=$((FAILED + 1))
        log "✘  Failed: $DB"
    fi

    echo "" >> "$LOG_FILE"
done

log "=========================================="
log "pg_repack – Summary"
log "  Total databases : $TOTAL"
log "  Succeeded       : $SUCCESS"
log "  Failed          : $FAILED"
log "=========================================="

if [ "$FAILED" -gt 0 ]; then
    log "WARNING: $FAILED database(s) had errors. Review the log: $LOG_FILE"
    exit 1
fi

log "All databases repacked successfully."
exit 0
