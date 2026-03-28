# Aspach - Advanced Smart Partitioned Archiver

A professional, zero-local-storage Linux backup solution designed to **end my own backup nightmare** by synchronizing local directories to Google Drive with smart recursive partitioning.

## 🚀 Features

- **Zero-Local-Storage Architecture**: Compresses and uploads on-the-fly. Temporary files are deleted immediately after upload.
- **Recursive Smart Partitioning**: Automatically splits large folders into smaller archives based on a configurable threshold (e.g., 10GB).
- **Inventory-Based Change Detection**: Uses a deterministic state hash (based on file names, sizes, and timestamps) to only re-upload changed partitions.
- **Smart Grouping (MISC)**: Groups small files and sub-folders into a single `_MISC` archive to prevent file clutter on the remote.
- **Hard-Kill Signal Handling**: Responds instantly to `Ctrl+C` by terminating all background tasks and child processes (rclone, tar, etc.).
- **Automatic Remote Archiving**: Leverages rclone's `--backup-dir` to move old versions of files to a dated archive folder instead of deleting them.
- **Parallel Processing**: Supports multiple parallel compression and transfer jobs.

## 📁 Local File Structure

By default, the script manages its state and temporary files in `~/.aspach/`:

- **`staging/`**: Temporary workspace where archives are created before being uploaded. Files are deleted automatically after each transfer.
- **`logs/`**: Stores timestamped log files (`backup_YYYYMMDD_HHMMSS.log`) to track execution history.
- **`inventory.txt`**: The "brain" of the script. Stores the MD5 state hashes of your partitions to detect changes and avoid redundant uploads.
- **`active_pids.txt`**: A temporary file used to track active background processes (subshells/rclone) for clean termination.
- **`.halt_PID`**: An atomic signal file created during an emergency stop (`Ctrl+C`) to instantly prevent any new processes from starting.

## 📋 Prerequisites

- **rclone**: Configured with a remote (e.g., Google Drive).
- **tar**: For archiving.
- **zstd** (Optional): Faster and better compression (falls back to `gzip` if not found).

## 🛠️ Installation

Simply copy `aspach.sh` to your system and ensure it has execution permissions:

```bash
chmod +x aspach.sh
```

## 📖 Usage

### Basic Command

```bash
./aspach.sh -s /path/to/source -r remote_name:backup_folder
```

### Mandatory Parameters

- `-s <path>`: Source directory to backup.
- `-r <remote>`: Rclone remote target (e.g., `gdrive:backups`).

### Optional Parameters

- `-g <num>`: Split threshold in GB (Default: 10). Folders larger than this will be partitioned.
- `-j <num>`: Number of parallel compression jobs (Default: 2).
- `-t <path>`: Staging directory for temporary files (Default: `~/.aspach/staging`).
- `-l <path>`: Log directory (Default: `~/.aspach/logs`).
- `-i <file>`: Inventory file to track state (Default: `~/.aspach/inventory.txt`).
- `-T <num>`: Rclone parallel transfers (Default: 8).
- `-C <num>`: Rclone parallel checkers (Default: 8).
- `-n`: Dry-run mode (Simulate without uploading).
- `-y`: Skip all interactive confirmations.

## 📂 Logic & Structure

1. **Analysis**: The script scans the source directory.
2. **Partitioning**: If a folder exceeds the threshold, it is recursed. Items smaller than the threshold are grouped into a `_MISC` archive.
3. **Hashing**: Each partition is hashed. If the hash matches the inventory, the upload is skipped.
4. **Execution**: Changed partitions are zipped and piped to rclone sequentially (or in parallel depending on `-j`).
5. **Cleanup**: Temporary zip files are removed, and the inventory is updated.
