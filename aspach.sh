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

# Define files upfront to avoid "tee" errors in early log calls
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).log"
PID_FILE="${LOG_DIR}/active_pids.txt"

# 1. Configuration Constants
ASSUME_YES="${ASSUME_YES:-false}"
LARGE_THRESHOLD_GB="${LARGE_THRESHOLD_GB:-50}"
SPLIT_THRESHOLD_GB="${SPLIT_THRESHOLD_GB:-10}" # Partition folders larger than this
MAX_JOBS="${MAX_JOBS:-2}"
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-8}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "MANDATORY PARAMETERS:"
    echo "  -s <path>    Source directory (Main folder to backup)"
    echo "  -r <remote>  Rclone remote target (e.g., gdrive:backup)"
    echo ""
    echo "OPTIONAL PARAMETERS (with default values):"
    echo "  -g <num>     Split threshold in GB              [Default: 10]"
    echo "  -j <num>     Parallel compression jobs          [Default: 2]"
    echo "  -t <path>    Staging directory                  [Default: ~/.aspach/staging]"
    echo "  -l <path>    Log directory                      [Default: ~/.aspach/logs]"
    echo "  -i <file>    Inventory file                     [Default: ~/.aspach/inventory.txt]"
    echo "  -T <num>     Rclone parallel transfers          [Default: 8]"
    echo "  -C <num>     Rclone parallel checkers           [Default: 8]"
    echo "  -n           Dry-run (Simulation) mode          [Default: false]"
    echo "  -y           Assume Yes (Skip confirmations)    [Default: false]"
    echo "  -h           Show this help message"
    echo ""
    exit 1
}

# 2. Parse Command Line Arguments
while getopts "s:t:r:i:j:l:g:T:C:nyh" opt; do
    case $opt in
        s) SOURCE_DIR="$OPTARG" ;;
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

# --- HELPER FUNCTIONS ---
check_halt() {
    [ -f "$HALT_FILE" ] && exit 1
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

    # Create HALT_FILE immediately to stop new processes
    touch "$HALT_FILE" 2>/dev/null

    log "[INFO] Emergency stop triggered. Halted all operations."
    log "[INFO] Cleaning up all processes..."
    
    # 1. Kill background PIDs tracked in PID_FILE
    if [ -f "$PID_FILE" ]; then
        log "[INFO] Reading PIDs from $PID_FILE..."
        local pids_to_kill=$(cat "$PID_FILE")
        for pid in $pids_to_kill; do
            log "[INFO] Killing subshell PID: $pid and its children..."
            pkill -9 -P "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
        done
        rm -f "$PID_FILE"
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
        rm -f "$STAGING_DIR"/*_tmp.* >/dev/null 2>&1
    fi
    rm -f "$HALT_FILE" 2>/dev/null
    
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
# Ensure directories exist
mkdir -p "$STAGING_DIR" "$LOG_DIR" "$(dirname "$INVENTORY_FILE")"

# Reset files for a fresh start
PID_FILE="${LOG_DIR}/active_pids.txt"
HALT_FILE="${LOG_DIR}/.halt_$$"
rm -f "$PID_FILE" "$HALT_FILE"
rm -f "${LOG_DIR}/.halt_*" 2>/dev/null  # Cleanup orphans from previous crashes
touch "$INVENTORY_FILE"

# PRE-FLIGHT LOGGING
log "--------------------------------------------------------"
log "BACKUP PROCESS STARTED"
log "--------------------------------------------------------"
log "WARNING: NO WARRANTY - Use this script at your own risk."
log "Log File  : $LOG_FILE"
log "PID File  : $PID_FILE"

# --- SOURCE & REMOTE VALIDATION ---
if [ -z "$SOURCE_DIR" ]; then echo "[ERR] SOURCE_DIR is missing!"; exit 1; fi
if [ -z "$RCLONE_REMOTE" ]; then
    echo "[ERR] RCLONE_REMOTE is missing!"; rclone listremotes | sed 's/^/  - /'; exit 1
fi

# Normalize Remote Path (Remove trailing slashes for consistency)
RCLONE_REMOTE="${RCLONE_REMOTE%/}"

REMOTE_NAME="${RCLONE_REMOTE%%:*}:"
if ! rclone listremotes | grep -Fxq "$REMOTE_NAME"; then
    echo "[ERR] Remote '$REMOTE_NAME' not found!"; rclone listremotes | sed 's/^/  - /'; exit 1
fi

# Target folder check
log "[INFO] Verifying destination '$RCLONE_REMOTE/current'..."
REMOTE_CONTENT=$(rclone lsf "$RCLONE_REMOTE/current" --max-depth 1 2>/dev/null)
if [ -n "$REMOTE_CONTENT" ]; then
    log "[WARNING] Destination folder is NOT empty!"
    if ! confirm "Proceed regardless?"; then exit 1; fi
fi

# PRE-CREATION: Create target folder upfront to prevent parallel race conditions (Duplicate 'current' folder fix)
log "[INFO] Ensuring remote target folder exists..."
rclone mkdir "$RCLONE_REMOTE/current" 2>/dev/null

log "Source    : $SOURCE_DIR"
log "Remote    : $RCLONE_REMOTE"
log "Threshold : Split at ${SPLIT_THRESHOLD_GB}GB"
if [ "$DRY_RUN" = true ]; then log "MODE      : TEST (DRY-RUN)"; fi
log "--------------------------------------------------------"

# Tool Check
if command -v zstd >/dev/null 2>&1; then
    COMPRESS_CMD="tar --mtime=2020-01-01 --owner=0 --group=0 --numeric-owner -I zstd -cf"
    EXT="tar.zst"
else
    COMPRESS_CMD="tar --mtime=2020-01-01 --owner=0 --group=0 --numeric-owner -czf"
    EXT="tar.gz"
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

update_inventory() {
    local key="$1"
    local hash="$2"
    grep -v "^$key:" "$INVENTORY_FILE" > "${INVENTORY_FILE}.tmp" 2>/dev/null
    echo "$key:$hash" >> "${INVENTORY_FILE}.tmp"
    mv "${INVENTORY_FILE}.tmp" "$INVENTORY_FILE"
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
    local stored_hash=$(grep "^$archive_label:" "$INVENTORY_FILE" | cut -d':' -f2)
    
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
        rm -f "$archive_path"; return 1
    fi

    # 4. Upload
    log "[^] Uploading: $archive_label..."
    local old_path="$RCLONE_REMOTE/old_versions/$(date '+%Y%m%d-%H%M')"
    # -P added for progress (shows transfer speed and ETA)
    local r_flags="-P -v --backup-dir $old_path --checksum --drive-chunk-size 128M --transfers $RCLONE_TRANSFERS --checkers $RCLONE_CHECKERS --drive-acknowledge-abuse"
    
    rclone copyto "$archive_path" "$RCLONE_REMOTE/current/$archive_label.$EXT" $r_flags

    if [ $? -eq 0 ]; then
        log "[OK] Success: $archive_label"
        update_inventory "$archive_label" "$current_hash"
    else
        log "[ERR] Upload failed: $archive_label"
    fi

    rm -f "$archive_path"
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

# --- MAIN LOOP ---
JOB_COUNT=0
for f in "$SOURCE_DIR"/*/; do
    check_halt
    [ -e "$f" ] || continue
    f=${f%/}
    folder_name=$(basename "$f")
    # Call the recursive processor (Starts at level 0)
    recursive_process_folder "$f" "$folder_name" &
    # Track PID for reliable cleanup
    echo $! >> "$PID_FILE"
    
    ((JOB_COUNT++))
    if [ "$JOB_COUNT" -ge "$MAX_JOBS" ]; then
        wait -n; ((JOB_COUNT--))
    fi
done
wait

log "--------------------------------------------------------"
log "BACKUP PROCESS COMPLETED."
log "--------------------------------------------------------"
