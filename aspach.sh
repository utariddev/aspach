#!/bin/bash

# --- DEFAULTS ---
# SOURCE_DIR must be provided by user

# Define Base Config Directory
BASE_DIR="${HOME}/.aspach"

STAGING_DIR="${STAGING_DIR:-${BASE_DIR}/staging}"
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"
INVENTORY_FILE="${INVENTORY_FILE:-${BASE_DIR}/inventory.txt}"

# RCLONE_REMOTE must be provided by user
DRY_RUN="${DRY_RUN:-false}"
SUCCESSFUL_EXIT=false

# LOG_FILE is set after backup vs restore mode is known
LOG_FILE=""
PID_DIR="${LOG_DIR}/active_pids"
MODE="backup"
RESTORE_DIR=""

# 1. Configuration Constants
ASSUME_YES="${ASSUME_YES:-false}"
SPLIT_THRESHOLD_GB="${SPLIT_THRESHOLD_GB:-10}" # Partition folders larger than this
MAX_JOBS="${MAX_JOBS:-2}"
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-8}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "BACKUP (PC -> Google Drive):"
    echo "  -s <path>    Source directory to back up"
    echo "  -r <remote>  Rclone remote (e.g., gdrive:backup)"
    echo ""
    echo "RESTORE (Google Drive -> PC, extract archives):"
    echo "  -d <path>    Destination directory to restore into"
    echo "  -r <remote>  Same remote used for backup"
    echo ""
    echo "OPTIONAL PARAMETERS (with default values):"
    echo "  -g <num>     Split threshold in GB (backup only)   [Default: 10]"
    echo "  -j <num>     Parallel compression jobs (backup)    [Default: 2]"
    echo "  -t <path>    Staging directory                     [Default: ~/.aspach/staging]"
    echo "  -l <path>    Log directory                         [Default: ~/.aspach/logs]"
    echo "  -i <file>    Inventory file (backup only)          [Default: ~/.aspach/inventory.txt]"
    echo "  -T <num>     Rclone parallel transfers             [Default: 8]"
    echo "  -C <num>     Rclone parallel checkers              [Default: 8]"
    echo "  -n           Dry-run (Simulation) mode             [Default: false]"
    echo "  -y           Assume Yes (Skip confirmations)       [Default: false]"
    echo "  -h           Show this help message"
    echo ""
    exit 1
}

# 2. Parse Command Line Arguments
while getopts "s:t:r:i:j:l:g:T:C:nyd:h" opt; do
    case $opt in
        s) SOURCE_DIR="$OPTARG" ;;
        d) RESTORE_DIR="$OPTARG" ;;
        t) STAGING_DIR="$OPTARG" ;;
        r) RCLONE_REMOTE="$OPTARG" ;;
        i) INVENTORY_FILE="$OPTARG" ;;
        j) MAX_JOBS="$OPTARG" ;;
        l) LOG_DIR="$OPTARG" ;;
        g) SPLIT_THRESHOLD_GB="$OPTARG" ;;
        T) RCLONE_TRANSFERS="$OPTARG" ;;
        C) RCLONE_CHECKERS="$OPTARG" ;;
        n) DRY_RUN=true ;;
        y) ASSUME_YES=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -n "$RESTORE_DIR" ] && [ -n "$SOURCE_DIR" ]; then
    echo "[ERR] Cannot use -s (backup) and -d (restore) together." >&2
    exit 1
fi
if [ -n "$RESTORE_DIR" ]; then
    MODE=restore
elif [ -n "$SOURCE_DIR" ]; then
    MODE=backup
else
    echo "[ERR] Specify -s <source> for backup or -d <dest> for restore." >&2
    exit 1
fi
LOG_FILE="$LOG_DIR/${MODE}_$(date +%Y%m%d_%H%M%S).log"

check_halt() {
    [ -f "$HALT_FILE" ] && exit 1
}

mark_backup_failed() {
    touch "$BACKUP_FAIL_MARKER" 2>/dev/null
}

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # If LOG_FILE is not defined yet, just echo to console
    if [ -z "$LOG_FILE" ]; then
        echo "[$timestamp] $@"
    else
        echo "[$timestamp] $@" | tee -a "$LOG_FILE"
    fi
}

# Guard for recursion in cleanup
CLEANUP_RUNNING=false

cleanup() {
    [ "$CLEANUP_RUNNING" = true ] && return
    CLEANUP_RUNNING=true

    # Handle successful exit gracefully without emergency warnings
    if [ "$SUCCESSFUL_EXIT" = true ]; then
        rm -rf "$PID_DIR" 2>/dev/null
        if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
            rm -f "$STAGING_DIR"/*_tmp.* "$STAGING_DIR"/*.tar.zst "$STAGING_DIR"/*.tar.gz >/dev/null 2>&1
        fi
        rm -f "$HALT_FILE" 2>/dev/null
        rm -f "$BACKUP_FAIL_MARKER" 2>/dev/null
        rm -f "${INVENTORY_FILE}.lock" 2>/dev/null
        return
    fi

    # Create HALT_FILE immediately to stop new processes
    touch "$HALT_FILE" 2>/dev/null

    log "[INFO] Emergency stop triggered. Halted all operations."
    log "[INFO] Cleaning up all processes..."
    
    # 1. Kill background PIDs tracked in PID_DIR
    if [ -d "$PID_DIR" ]; then
        log "[INFO] Reading PIDs from $PID_DIR..."
        local pids_to_kill=$(ls "$PID_DIR" 2>/dev/null)
        for pid in $pids_to_kill; do
            log "[INFO] Killing subshell PID: $pid and its children..."
            pkill -9 -P "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
        done
        rm -rf "$PID_DIR"
    fi

    # 2. Kill all rclone processes started by this script (targeted)
    # We use -f to match the script's remote to avoid killing unrelated rclones
    if [ -n "$RCLONE_REMOTE" ]; then
        log "[INFO] Performing targeted pkill for rclone on $RCLONE_REMOTE..."
        pkill -9 -f "rclone.*$RCLONE_REMOTE" 2>/dev/null
    fi

    # 3. Final safety kill for any direct children
    pkill -9 -P $$ 2>/dev/null

    # 4. Remove temp files (including the halt file)
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        log "[INFO] Removing temporary files from $STAGING_DIR..."
        rm -f "$STAGING_DIR"/*_tmp.* "$STAGING_DIR"/*.tar.zst "$STAGING_DIR"/*.tar.gz >/dev/null 2>&1
    fi
    rm -f "$HALT_FILE" 2>/dev/null
    rm -f "${INVENTORY_FILE}.lock" 2>/dev/null

    log "[INFO] Cleanup complete."
}

# Register cleanup to run on script exit or interrupt
trap cleanup EXIT INT TERM

confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    read -p "$1 [y/N]: " resp
    if [[ "$resp" == "y" || "$resp" == "Y" ]]; then return 0; else return 1; fi
}

# --- PRE-FLIGHT ---
# Dependency check
check_dependencies() {
    local missing_deps=()
    local cmd
    for cmd in rclone tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    if [ "$MODE" = backup ]; then
        if ! command -v md5sum >/dev/null 2>&1; then
            missing_deps+=("md5sum")
        fi
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "[ERR] Missing required dependencies: ${missing_deps[*]}" >&2
        exit 1
    fi
}
check_dependencies

# Ensure directories exist
mkdir -p "$STAGING_DIR" "$LOG_DIR" "$(dirname "$INVENTORY_FILE")" "$PID_DIR"

# Reset files for a fresh start
HALT_FILE="${LOG_DIR}/.halt_$$"
BACKUP_FAIL_MARKER="${LOG_DIR}/.backup_failed_$$"
rm -rf "$PID_DIR"/* "$HALT_FILE" "$BACKUP_FAIL_MARKER"
rm -f "${LOG_DIR}/.halt_*" 2>/dev/null  # Cleanup orphans from previous crashes
[ "$MODE" = backup ] && touch "$INVENTORY_FILE"

# PRE-FLIGHT LOGGING
log "--------------------------------------------------------"
if [ "$MODE" = restore ]; then
    log "RESTORE PROCESS STARTED"
else
    log "BACKUP PROCESS STARTED"
fi
log "--------------------------------------------------------"
log "WARNING: NO WARRANTY - Use this script at your own risk."
log "Log File  : $LOG_FILE"
log "Mode      : $MODE"
[ "$MODE" = backup ] && log "PID Dir   : $PID_DIR"

# --- REMOTE VALIDATION ---
if [ -z "$RCLONE_REMOTE" ]; then
    echo "[ERR] RCLONE_REMOTE is missing!"; rclone listremotes | sed 's/^/  - /'; exit 1
fi

RCLONE_REMOTE="${RCLONE_REMOTE%/}"

REMOTE_NAME="${RCLONE_REMOTE%%:*}"
if ! rclone listremotes | grep -Eq "^${REMOTE_NAME}:[[:space:]]*$"; then
    echo "[ERR] Remote '${REMOTE_NAME}:' not found!"; rclone listremotes | sed 's/^/  - /'; exit 1
fi

REMOTE_CURRENT="$RCLONE_REMOTE/current"

if [ "$MODE" = restore ]; then
    log "Remote    : $RCLONE_REMOTE"
    log "Restore to: $RESTORE_DIR"
    if [ "$DRY_RUN" = true ]; then log "MODE      : TEST (DRY-RUN)"; fi
    log "--------------------------------------------------------"
else
    # --- BACKUP-ONLY REMOTE SETUP ---
    log "[INFO] Verifying destination '$REMOTE_CURRENT'..."
    REMOTE_CONTENT=$(rclone lsf "$REMOTE_CURRENT" --max-depth 1 2>/dev/null)
    if [ -n "$REMOTE_CONTENT" ]; then
        log "[WARNING] Destination folder is NOT empty!"
        if ! confirm "Proceed regardless?"; then exit 1; fi
    fi

    log "[INFO] Ensuring remote target folder exists..."
    rclone mkdir "$REMOTE_CURRENT" 2>/dev/null

    log "Source    : $SOURCE_DIR"
    log "Remote    : $RCLONE_REMOTE"
    log "Threshold : Split at ${SPLIT_THRESHOLD_GB}GB"
    if [ "$DRY_RUN" = true ]; then log "MODE      : TEST (DRY-RUN)"; fi
    log "--------------------------------------------------------"
fi

# Tool Check (backup compression + restore extract)
if command -v zstd >/dev/null 2>&1; then
    COMPRESS_CMD="tar --mtime=2020-01-01 --owner=0 --group=0 --numeric-owner -I zstd -cf"
    EXT="tar.zst"
    HAS_ZSTD=true
else
    COMPRESS_CMD="tar --mtime=2020-01-01 --owner=0 --group=0 --numeric-owner -czf"
    EXT="tar.gz"
    HAS_ZSTD=false
fi

get_items_state_hash() {
    local parent="$1"
    shift
    local items=("$@")
    local full_paths=()
    for item in "${items[@]}"; do
        full_paths+=("$parent/$item")
    done
    find "${full_paths[@]}" -type f -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1
}

inventory_get_stored_hash() {
    local key="$1"
    awk -v key="$key" '
        {
            idx = index($0, "\t")
            if (idx == 0) next
            if (substr($0, idx + 1) == key) {
                print substr($0, 1, idx - 1)
                exit
            }
        }
    ' "$INVENTORY_FILE"
}

update_inventory() {
    local key="$1"
    local hash="$2"
    (
        flock -x 200
        # Format: "<hash><TAB><key>" (key may contain spaces)
        awk -v key="$key" '
            {
                idx = index($0, "\t")
                if (idx > 0 && substr($0, idx + 1) == key) next
                print
            }
        ' "$INVENTORY_FILE" > "${INVENTORY_FILE}.tmp" 2>/dev/null
        printf '%s\t%s\n' "$hash" "$key" >> "${INVENTORY_FILE}.tmp"
        mv "${INVENTORY_FILE}.tmp" "$INVENTORY_FILE"
    ) 200>"${INVENTORY_FILE}.lock"
}

extract_archive() {
    local archive="$1"
    local dest="$2"

    case "$archive" in
        *.tar.zst)
            if [ "$HAS_ZSTD" != true ]; then
                log "[ERR] zstd is required to extract: $(basename "$archive")"
                return 1
            fi
            tar -I zstd -xf "$archive" -C "$dest"
            ;;
        *.tar.gz)
            tar -xzf "$archive" -C "$dest"
            ;;
        *)
            log "[ERR] Unsupported archive type: $(basename "$archive")"
            return 1
            ;;
    esac
}

run_restore() {
    local remote_current="$REMOTE_CURRENT"
    local archives=()
    local arch staging_path restore_failures=0

    mkdir -p "$RESTORE_DIR" "$STAGING_DIR"

    if [ -n "$(ls -A "$RESTORE_DIR" 2>/dev/null)" ]; then
        log "[WARNING] Restore destination is not empty: $RESTORE_DIR"
        if ! confirm "Proceed? Existing files may be overwritten."; then
            return 1
        fi
    fi

    log "[INFO] Listing archives in $remote_current ..."
    mapfile -t archives < <(rclone lsf "$remote_current" 2>/dev/null | grep -E '\.tar\.(zst|gz)$' || true)
    archives=("${archives[@]%/}")

    if [ ${#archives[@]} -eq 0 ]; then
        log "[ERR] No backup archives found in $remote_current"
        mark_backup_failed
        return 1
    fi

    log "[INFO] Found ${#archives[@]} archive(s) to restore."

    for arch in "${archives[@]}"; do
        check_halt
        log "[>] Restoring: $arch"

        if [ "$DRY_RUN" = true ]; then
            log "[DRY] Would download and extract: $arch -> $RESTORE_DIR"
            continue
        fi

        staging_path="$STAGING_DIR/$arch"
        if ! rclone copyto "$remote_current/$arch" "$staging_path" \
            -P --transfers "$RCLONE_TRANSFERS" --checkers "$RCLONE_CHECKERS"; then
            log "[ERR] Download failed: $arch"
            mark_backup_failed
            ((restore_failures++)) || true
            continue
        fi

        if ! extract_archive "$staging_path" "$RESTORE_DIR"; then
            log "[ERR] Extract failed: $arch"
            mark_backup_failed
            rm -f "$staging_path"
            ((restore_failures++)) || true
            continue
        fi

        rm -f "$staging_path"
        log "[OK] Restored: $arch"
    done

    if [ "$restore_failures" -gt 0 ]; then
        return 1
    fi
    log "[INFO] All archives extracted under: $RESTORE_DIR"
    log "[INFO] Note: file contents match backup; timestamps were normalized to 2020-01-01 during backup."
    return 0
}

# Core function to handle an individual "Partition" (One or more items)
process_partition() {
    check_halt
    local parent_dir="$1"    # The parent directory (e.g. /home/user/Source)
    local archive_label="$2" # Label for inventory/filename (e.g. Photos_2023)
    shift 2
    local items=("$@")       # List of items relative to parent_dir

    local archive_path="$STAGING_DIR/${archive_label}_tmp.$EXT"
    
    # 1. Change Detection
    local current_hash=$(get_items_state_hash "$parent_dir" "${items[@]}")
    local stored_hash
    stored_hash=$(inventory_get_stored_hash "$archive_label")
    
    if [ "$current_hash" == "$stored_hash" ]; then
        log "[-] Skip (No changes): $archive_label"
        return 0
    fi

    # 2. Size Detection (Sum the items)
    local total_size_hr=$(du -sch "${items[@]/#/$parent_dir/}" 2>/dev/null | tail -n1 | cut -f1)
    log "[*] Processing: $archive_label ($total_size_hr) [${#items[@]} items]"
    if [ -n "$stored_hash" ]; then
        log "[INFO] Previous version found. Archiving to old_versions/"
    fi

    if [ "$DRY_RUN" = true ]; then
        log "[DRY] Would upload: $archive_label"
        return 0
    fi

    # 3. Compress
    log "[>] Compressing: $archive_label..."
    $COMPRESS_CMD "$archive_path" -C "$parent_dir" "${items[@]}"
    
    if [ $? -ne 0 ]; then
        log "[ERR] Compression failed: $archive_label"
        rm -f "$archive_path"
        mark_backup_failed
        return 1
    fi

    # 4. Upload
    log "[^] Uploading: $archive_label..."
    local old_path="$RCLONE_REMOTE/old_versions/$(date '+%Y%m%d-%H%M')"
    # Use an array to prevent word splitting on paths containing spaces or special characters
    local r_flags=(
        -P -v
        --backup-dir "$old_path"
        --checksum
        --drive-chunk-size 128M
        --transfers "$RCLONE_TRANSFERS"
        --checkers "$RCLONE_CHECKERS"
        --drive-acknowledge-abuse
    )

    rclone copyto "$archive_path" "$REMOTE_CURRENT/$archive_label.$EXT" "${r_flags[@]}"

    if [ $? -eq 0 ]; then
        log "[OK] Success: $archive_label"
        update_inventory "$archive_label" "$current_hash"
        rm -f "$archive_path"
        return 0
    fi

    log "[ERR] Upload failed: $archive_label"
    rm -f "$archive_path"
    mark_backup_failed
    return 1
}

# Recursive function to determine if a folder should be split or treated as one
recursive_process_folder() {
    check_halt
    local dir="$1"
    local label="$2"
    local folder_name=$(basename "$dir")
    local parent_dir=$(dirname "$dir")
    local folder_size_bytes=$(du -sb "$dir" | cut -f1)

    if [ "$folder_size_bytes" -gt $((SPLIT_THRESHOLD_GB * 1024 * 1024 * 1024)) ]; then
        local folder_size_hr=$(du -sh "$dir" | cut -f1)
        log "[INFO] Partitioning large folder: $label ($folder_size_hr)"
        
        local small_items=()
        local big_item_found=false

        # Iterate over all items (files and folders)
        for item in "$dir"/*; do
            [ -e "$item" ] || continue
            local item_name=$(basename "$item")
            local item_size=$(du -sb "$item" | cut -f1)

            if [ -d "$item" ] && [ "$item_size" -gt $((SPLIT_THRESHOLD_GB * 1024 * 1024 * 1024)) ]; then
                # Big sub-directory: Recurse
                big_item_found=true
                recursive_process_folder "$item" "${label}_${item_name}"
            else
                # Small sub-directory or a file: Collect for grouping
                small_items+=("$folder_name/$item_name")
            fi
        done
        
        # Process all collected small items together as a MISC partition
        if [ ${#small_items[@]} -gt 0 ]; then
            if [ "$big_item_found" = true ]; then
                process_partition "$parent_dir" "${label}_MISC" "${small_items[@]}"
            else
                # If everything was small but the total was somehow large (edge case)
                # Just zip the whole folder normally
                process_partition "$parent_dir" "$label" "$folder_name"
            fi
        fi
    else
        # Small enough to zip as one
        process_partition "$parent_dir" "$label" "$folder_name"
    fi
}

# Archive loose files sitting directly under SOURCE_DIR
process_source_root_files() {
    check_halt
    local item root_files=()
    shopt -s dotglob nullglob
    for item in "$SOURCE_DIR"/*; do
        [[ -e "$item" && ! -d "$item" ]] && root_files+=("$(basename "$item")")
    done
    shopt -u dotglob nullglob
    [ ${#root_files[@]} -eq 0 ] && return 0
    log "[INFO] Backing up ${#root_files[@]} file(s) from source root as _ROOT"
    process_partition "$SOURCE_DIR" "_ROOT" "${root_files[@]}"
}

# --- RESTORE MAIN ---
if [ "$MODE" = restore ]; then
    run_restore
    BACKUP_HAD_FAILURES=false
    [ -f "$BACKUP_FAIL_MARKER" ] && BACKUP_HAD_FAILURES=true
    rm -f "$BACKUP_FAIL_MARKER"

    log "--------------------------------------------------------"
    if [ "$BACKUP_HAD_FAILURES" = true ]; then
        log "RESTORE PROCESS COMPLETED WITH ERRORS."
    else
        log "RESTORE PROCESS COMPLETED."
    fi
    log "--------------------------------------------------------"
    SUCCESSFUL_EXIT=true
    [ "$BACKUP_HAD_FAILURES" = true ] && exit 1
    exit 0
fi

# --- BACKUP MAIN ---
# --- SOURCE LAYOUT CHECK ---
has_subdir=false
has_root_files=false
shopt -s dotglob nullglob
for f in "$SOURCE_DIR"/*; do
    [ -d "$f" ] && has_subdir=true
    [[ -e "$f" && ! -d "$f" ]] && has_root_files=true
    [ "$has_subdir" = true ] && [ "$has_root_files" = true ] && break
done
shopt -u dotglob nullglob
if [ "$has_subdir" = false ] && [ "$has_root_files" = false ]; then
    log "[ERR] Source is empty: $SOURCE_DIR"
    log "[ERR] Nothing to back up (no files or subdirectories at source root)."
    SUCCESSFUL_EXIT=true
    exit 1
fi

# --- MAIN LOOP ---
JOB_COUNT=0
shopt -s dotglob
for f in "$SOURCE_DIR"/*/; do
    check_halt
    [ -e "$f" ] || continue
    f=${f%/}
    folder_name=$(basename "$f")
    # Call the recursive processor (Starts at level 0)
    (
        recursive_process_folder "$f" "$folder_name"
        rm -f "$PID_DIR/$BASHPID" 2>/dev/null
    ) &
    # Track PID for reliable cleanup
    touch "$PID_DIR/$!"
    
    ((JOB_COUNT++))
    if [ "$JOB_COUNT" -ge "$MAX_JOBS" ]; then
        wait -n; ((JOB_COUNT--))
    fi
done
shopt -u dotglob
wait

process_source_root_files

BACKUP_HAD_FAILURES=false
[ -f "$BACKUP_FAIL_MARKER" ] && BACKUP_HAD_FAILURES=true
rm -f "$BACKUP_FAIL_MARKER"

log "--------------------------------------------------------"
if [ "$BACKUP_HAD_FAILURES" = true ]; then
    log "BACKUP PROCESS COMPLETED WITH ERRORS."
else
    log "BACKUP PROCESS COMPLETED."
fi
log "--------------------------------------------------------"
SUCCESSFUL_EXIT=true
[ "$BACKUP_HAD_FAILURES" = true ] && exit 1
