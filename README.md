# Aspach - Advanced Smart Partitioned Archiver

A professional, zero-local-storage Linux backup solution designed to **end my own backup nightmare** by synchronizing local directories to Google Drive with smart recursive partitioning.

## Features

- **Zero-Local-Storage Architecture**: Compresses and uploads on-the-fly. Temporary files are deleted immediately after upload to save local disk space.
- **Recursive Smart Partitioning**: Automatically splits large folders into smaller archives based on a configurable threshold (e.g., 10GB) to handle massive datasets gracefully.
- **Parallel Processing**: Supports multiple parallel jobs for both **Backup** and **Restore** operations, utilizing modern multi-core CPUs.
- **Inventory-Based Change Detection**: Uses a deterministic state hash (based on file names, sizes, and timestamps) to re-upload only the changed partitions.
- **Hidden File Support (dotglob)**: Correctly handles and backs up hidden files (`.env`, `.git`, etc.) even when partitioning is active.
- **Smart Grouping (MISC)**: Groups small files and sub-folders into a single `_MISC` archive to prevent file clutter on the remote storage.
- **Automatic Remote Archiving**: Leverages rclone's `--backup-dir` to move old versions to a timestamped folder instead of deleting them.
- **Aggressive Cleanup**: Advanced signal handling (`SIGINT`, `SIGTERM`) ensures all background processes (rclone, tar) are terminated and temporary files are wiped on exit.

## Local File Structure

By default, the script manages its state in `~/.aspach/`:

- **`staging/`**: Temporary workspace where archives are created. Files are prefixed with the instance PID (`aspach_tmp_$$_*`) for safe multi-instance execution and cleanup.
- **`logs/`**: Stores timestamped log files (`backup_*.log` or `restore_*.log`) to track execution history.
- **`inventory.txt`**: The "brain" of the script. Stores MD5 state hashes to detect changes and avoid redundant uploads.

## Prerequisites

- **Bash 4.3+**: Required for parallel job control (`wait -n`).
- **rclone**: Configured with a valid remote.
- **tar**: For archiving.
- **zstd** (Recommended): Significantly faster and better compression (falls back to `gzip` if not found).

## Installation

Simply copy `aspach.sh` to your system and ensure it has execution permissions:

```bash
chmod +x aspach.sh
```

## Usage

### Backup Mode (PC -> Remote)
```bash
./aspach.sh -s /path/to/source -r remote_name:backup_folder
```

### Restore Mode (Remote -> PC)
```bash
./aspach.sh -d /path/to/destination -r remote_name:backup_folder
```

### Mandatory Parameters
- `-s <path>`: Source directory to backup.
- `-d <path>`: Destination directory for restoration.
- `-r <remote>`: Rclone remote target (e.g., `gdrive:backups`).

### Optional Parameters
- `-g <num>`: Split threshold in GB (Default: 10).
- `-j <num>`: Number of parallel jobs (Default: 2).
- `-t <path>`: Staging directory for temporary files (Default: `~/.aspach/staging`).
- `-l <path>`: Log directory (Default: `~/.aspach/logs`).
- `-i <file>`: Inventory file to track state (Default: `~/.aspach/inventory.txt`).
- `-T <num>`: Rclone parallel transfers (Default: 8).
- `-C <num>`: Rclone parallel checkers (Default: 8).
- `-n`: Dry-run mode (Simulate without actual upload/download).
- `-y`: Skip all interactive confirmations.

## Logic & Structure

1. **Analysis**: The script scans the source layout, including hidden files.
2. **Partitioning**: Large folders are recursed. Small items are grouped into `_MISC`.
3. **Hashing**: Each partition is hashed deterministically. Unchanged parts are skipped.
4. **Execution**: Changed partitions are archived and piped to rclone in parallel.
5. **Cleanup**: On success or interrupt, all child processes are killed and staging files are wiped.

---
*named after the peaceful town of Aspach.*
