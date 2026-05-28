#!/bin/bash

# Parallel backup jobs use "wait -n" (added in Bash 4.3).
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "[ERR] aspach.sh requires Bash 4.3 or newer." >&2
    echo "      Current: Bash ${BASH_VERSION}" >&2
    echo "      Reason: parallel backup uses 'wait -n' (not available before 4.3)." >&2
    exit 1
fi

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

if [[ "$STAGING_DIR" == "/" || "$STAGING_DIR" == "$HOME" || "$STAGING_DIR" == "/tmp" ]]; then
    echo "[ERR] Cannot use '$STAGING_DIR' as a staging directory!" >&2
    exit 1
fi

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

    # On successful exit, only clean up temporary locks and files
    if [ "$SUCCESSFUL_EXIT" = true ]; then
        rm -f "$HALT_FILE" "${INVENTORY_FILE}.lock" "$BACKUP_FAIL_MARKER" 2>/dev/null
        if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
            # Only remove temp files created by this specific script instance
            rm -f "$STAGING_DIR"/aspach_tmp_${$}_* 2>/dev/null
        fi
        return
    fi

    # EMERGENCY CLEANUP (Ctrl+C or Error state)
    # 1. Ignore new signals to prevent infinite loops and self-termination
    trap '' INT TERM EXIT

    touch "$HALT_FILE" 2>/dev/null
    log "[INFO] Emergency stop triggered. Halted all operations."

    # 2. Perform file cleanup FIRST so no garbage is left on disk even if the script dies [1]
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        log "[INFO] Removing temporary backup archives..."
        rm -f "$STAGING_DIR"/aspach_tmp_${$}_* 2>/dev/null
    fi
    rm -f "$HALT_FILE" "${INVENTORY_FILE}.lock" "$BACKUP_FAIL_MARKER" 2>/dev/null

    # 3. Send TERM signal to the entire process group.
    # Since the parent script now ignores TERM (trap ''), it won't die, but all child processes (rclone/tar) will.
    log "[INFO] Sending termination signal to all background jobs..."
    kill -TERM -$$ 2>/dev/null
    sleep 1

    # 4. Forcefully terminate any surviving child processes.
    # pkill -9 -P $$ only kills direct child processes of this script, not the parent itself.
    pkill -9 -P $$ 2>/dev/null

    log "[INFO] Cleanup complete."
    exit 1
}

# Signal Handlers
# When a signal is caught, set the successful exit flag to false and exit.
# The exit command automatically triggers the EXIT trap (cleanup).
trap 'SUCCESSFUL_EXIT=false; exit 1' INT TERM
trap cleanup EXIT

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
mkdir -p "$STAGING_DIR" "$LOG_DIR" "$(dirname "$INVENTORY_FILE")"

# Reset files for a fresh start
HALT_FILE="${LOG_DIR}/.halt_$$"
BACKUP_FAIL_MARKER="${LOG_DIR}/.backup_failed_$$"
rm -f "$HALT_FILE" "$BACKUP_FAIL_MARKER"
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

# --- REMOTE VALIDATION ---
if [ -z "$RCLONE_REMOTE" ]; then
    echo "[ERR] RCLONE_REMOTE is missing!"; rclone listremotes | sed 's/^/  - /'; exit 1
fi

RCLONE_REMOTE="${RCLONE_REMOTE%/}"

REMOTE_NAME="${RCLONE_REMOTE%%:*}"
if ! rclone listremotes | grep -Fxq "${REMOTE_NAME}:"; then
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
    # Subshell isolation prevents cd side-effects. %p with cd ensures relative paths with empty-P safety.
    (
        cd "$parent" || exit 1
        find "${items[@]}" -type f -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1
    )
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
        # Format: "<hash><TAB><key>"
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

    # Fail-fast check for zstd before downloading anything
    if [ "$HAS_ZSTD" != true ]; then
        for arch in "${archives[@]}"; do
            if [[ "$arch" == *.tar.zst ]]; then
                log "[ERR] One or more archives require 'zstd' to extract, but 'zstd' is missing."
                log "[ERR] Please install 'zstd' and try again to prevent mid-run failures."
                return 1
            fi
        done
    fi

    log "[INFO] Found ${#archives[@]} archive(s) to restore."

    # Run restore jobs in parallel using MAX_JOBS pool
    local JOB_COUNT=0
    for arch in "${archives[@]}"; do
        check_halt
        log "[>] Restoring: $arch"

        if [ "$DRY_RUN" = true ]; then
            log "[DRY] Would download and extract: $arch -> $RESTORE_DIR"
            continue
        fi

        # Use unique prefix to prevent staging directory leaks on emergency stop [1]
        staging_path="$STAGING_DIR/aspach_tmp_${$}_restore_$arch"

        (
            if ! rclone copyto "$remote_current/$arch" "$staging_path" \
                -P --transfers "$RCLONE_TRANSFERS" --checkers "$RCLONE_CHECKERS" >/dev/null 2>&1; then
                log "[ERR] Download failed: $arch"
                mark_backup_failed
                exit 1
            fi

            if ! extract_archive "$staging_path" "$RESTORE_DIR" >/dev/null 2>&1; then
                log "[ERR] Extract failed: $arch"
                mark_backup_failed
                rm -f "$staging_path"
                exit 1
            fi

            rm -f "$staging_path"
            log "[OK] Restored: $arch"
        ) &

        ((JOB_COUNT++))
        if [ "$JOB_COUNT" -ge "$MAX_JOBS" ]; then
            wait -n || ((restore_failures++))
            ((JOB_COUNT--))
        fi
    done
    wait

    # Check for any failures registered during background parallel jobs
    if [ -f "$BACKUP_FAIL_MARKER" ]; then
        restore_failures=1
    fi

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
    local archive_label="$1" # Label for inventory/filename (e.g. saraybosna@vidya59)
    shift
    local items=("$@")       # List of items relative to SOURCE_DIR

    local archive_path="$STAGING_DIR/aspach_tmp_${$}_${archive_label}.$EXT"
    
    # 1. Change Detection (Using SOURCE_DIR as base)
    local current_hash=$(get_items_state_hash "$SOURCE_DIR" "${items[@]}")
    local stored_hash
    stored_hash=$(inventory_get_stored_hash "$archive_label")
    
    if [ "$current_hash" == "$stored_hash" ]; then
        log "[-] Skip (No changes): $archive_label"
        return 0
    fi

    # 2. Size Detection
    local total_size_hr=$(du -sch "${items[@]/#/$SOURCE_DIR/}" 2>/dev/null | tail -n1 | cut -f1)
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
    $COMPRESS_CMD "$archive_path" -C "$SOURCE_DIR" "${items[@]}"
    
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
    
    # Calculate relative path from SOURCE_DIR
    local rel_path="${dir#$SOURCE_DIR/}"
    
    # Mathematically escape '@' and replace '/' with '@' to prevent collisions
    local escaped_path="${rel_path//@/@@}"
    local label="${escaped_path//\//@}"
    
    local folder_name=$(basename "$dir")
    local folder_size_bytes=$(du -sb "$dir" | cut -f1)

    if [ "$folder_size_bytes" -gt $((SPLIT_THRESHOLD_GB * 1024 * 1024 * 1024)) ]; then
        local folder_size_hr=$(du -sh "$dir" | cut -f1)
        log "[INFO] Partitioning large folder: $label ($folder_size_hr)"
        
        local small_items=()
        local big_item_found=false

        # Save current dotglob state and enable it to include hidden files
        local dotglob_saved
        dotglob_saved=$(shopt -p dotglob)
        shopt -s dotglob

        declare -A item_sizes
        while read -r size path; do
            item_sizes["$path"]=$size
        done < <(du -sb "$dir"/* 2>/dev/null)

        # Iterate over all items (including hidden files and folders)
        for item in "$dir"/*; do
            [ -e "$item" ] || continue
            local item_name=$(basename "$item")
            local item_size=${item_sizes["$item"]:-0}
            local item_rel_path="${item#$SOURCE_DIR/}"

            if [ -d "$item" ] && [ "$item_size" -gt $((SPLIT_THRESHOLD_GB * 1024 * 1024 * 1024)) ]; then
                # Big sub-directory
                big_item_found=true
                recursive_process_folder "$item"
            else
                # Small sub-directory or a file: Collect using its relative path to SOURCE_DIR
                small_items+=("$item_rel_path")
            fi
        done
        
        # Restore original dotglob state safely
        eval "$dotglob_saved"

        # Process all collected small items together as a MISC partition
        if [ ${#small_items[@]} -gt 0 ]; then
            if [ "$big_item_found" = true ]; then
                process_partition "${label}_MISC" "${small_items[@]}"
            else
                process_partition "$label" "$rel_path"
            fi
        fi
    else
        # Small enough to zip as one
        process_partition "$label" "$rel_path"
    fi
}

# Archive loose files sitting directly under SOURCE_DIR
process_source_root_files() {
    check_halt
    local item root_files=()
    
    # Save original shell options safely
    local shopt_saved
    shopt_saved=$(shopt -p dotglob nullglob)
    shopt -s dotglob nullglob
    
    for item in "$SOURCE_DIR"/*; do
        [[ -e "$item" && ! -d "$item" ]] && root_files+=("$(basename "$item")")
    done
    
    # Restore original shell options immediately after the loop
    eval "$shopt_saved"
    
    [ ${#root_files[@]} -eq 0 ] && return 0
    log "[INFO] Backing up ${#root_files[@]} file(s) from source root as _ROOT"
    process_partition "_ROOT" "${root_files[@]}"
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

# 1. Source Directory Existence Check
if [ ! -d "$SOURCE_DIR" ]; then
    log "[ERR] SOURCE_DIR '$SOURCE_DIR' does not exist or is not a directory!"
    SUCCESSFUL_EXIT=true # Prevent emergency warnings during clean exit
    exit 1
fi

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

#Run root files backup in parallel alongside other folder jobs
if [ "$has_root_files" = true ]; then
    process_source_root_files &
    ((JOB_COUNT++))
fi

for f in "$SOURCE_DIR"/*/; do
    check_halt
    [ -e "$f" ] || continue
    f=${f%/}
    # Call the recursive processor
    recursive_process_folder "$f" &
    
    ((JOB_COUNT++))
    if [ "$JOB_COUNT" -ge "$MAX_JOBS" ]; then
        wait -n; ((JOB_COUNT--))
    fi
done
shopt -u dotglob
wait

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