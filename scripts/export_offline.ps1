# GraphKnow Offline Migration Export Script
# Exports all Docker images and volumes to a single archive
# Usage: .\export_offline.ps1 [-SkipStopContainers]

param(
    [switch]$SkipStopContainers  # Add this flag to skip stopping containers
)

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIG: Output directory for the backup
# ============================================================
# You can change this to any path you want
# Examples:
#   $OUTPUT_DIR = "D:\GitWorks\GraphKnow\Images"
#   $OUTPUT_DIR = ".\backup"
#   $OUTPUT_DIR = "C:\backups"
# ============================================================

# Default: Output to "Images" folder in project root
$PROJECT_ROOT = $PWD.Path
while ($PROJECT_ROOT -and -not (Test-Path (Join-Path $PROJECT_ROOT "docker-compose.yml"))) {
    $PROJECT_ROOT = Split-Path -Parent $PROJECT_ROOT
}
if (-not $PROJECT_ROOT) {
    Write-Error "Could not find project root (docker-compose.yml not found)"
    exit 1
}
# 输出文件路径，可自定义
# ======================================================
# 例如：$OUTPUT_DIR = "D:\GitWorks\GraphKnow\Images"
$OUTPUT_DIR = Join-Path $PROJECT_ROOT "Images"  # 当前目录下的文件夹

# ============================================================
# END CONFIG
# ============================================================
$BACKUP_NAME = "graphknow_offline_backup"
$TIMESTAMP = Get-Date -Format "yyyyMMdd_HHmmss"
$BACKUP_DIR = Join-Path $OUTPUT_DIR "$BACKUP_NAME`_$TIMESTAMP"

# Containers that need to be stopped for volume export
$CONTAINERS_TO_STOP = @(
    "graph",
    "milvus-etcd-dev", 
    "milvus-minio",
    "milvus",
    "postgres"
)

# Images to export (core services only)
$IMAGES = @(
    "graphknow-api",
    "graphknow-web",
    "neo4j:5.26",
    "quay.io/coreos/etcd:v3.5.5",
    "minio/minio:RELEASE.2023-03-20T20-16-18Z",
    "milvusdb/milvus:v2.5.6",
    "postgres:16"
)

# Config files to export
$CONFIG_FILES = @(
    "docker-compose.yml",
    ".env"
)

function Write-Step {
    param([string]$Message)
    Write-Host "`n[STEP] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# Check if running from project root
if (-not (Test-Path "docker-compose.yml")) {
    Write-Error "Please run this script from the project root directory"
    exit 1
}

# Check for 7-Zip
$sevenZip = $null
$sevenZipPaths = @(
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe"
)
foreach ($path in $sevenZipPaths) {
    if (Test-Path $path) {
        $sevenZip = $path
        break
    }
}

# Create output directory
Write-Step "Creating output directory: $BACKUP_DIR"
New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null

# Stop containers if not skipped
$containersWereRunning = @()
if (-not $SkipStopContainers) {
    Write-Step "Stopping containers for safe volume export..."
    
    foreach ($container in $CONTAINERS_TO_STOP) {
        $running = docker ps --filter "name=$container" --format "{{.Names}}" 2>$null
        if ($running -eq $container) {
            Write-Host "  Stopping: $container" -ForegroundColor Yellow
            docker stop $container 2>$null | Out-Null
            $containersWereRunning += $container
            Start-Sleep -Seconds 2
        }
    }
    Write-Success "Containers stopped"
} else {
    Write-Warning "Skipping container stop - volume export may be incomplete"
}

# 1. Export images
Write-Step "Exporting Docker images"

$imagesDir = Join-Path $BACKUP_DIR "images"
New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null

foreach ($image in $IMAGES) {
    $imageFileName = $image -replace '[/:]', '_'
    $imagePath = Join-Path $imagesDir "$imageFileName.tar"
    
    Write-Host "  Exporting: $image" -ForegroundColor Gray
    
    # Check if image exists
    $imageExists = docker images -q $image 2>$null
    if (-not $imageExists) {
        Write-Warning "  Image $image not found, skipping..."
        continue
    }
    
    # Export image
    docker save $image -o $imagePath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "  Failed to export $image"
    } else {
        $sizeMB = [math]::Round((Get-Item $imagePath).Length / 1MB, 2)
        Write-Host "    -> $imageFileName.tar ($sizeMB MB)" -ForegroundColor Green
    }
}

# 2. Export volumes
Write-Step "Exporting volumes"

$volumesDir = Join-Path $BACKUP_DIR "volumes"
New-Item -ItemType Directory -Path $volumesDir -Force | Out-Null

# Define volume exports
$volumeExports = @(
    @{LocalPath="docker\volumes\neo4j\data"; Name="neo4j_data"},
    @{LocalPath="docker\volumes\neo4j\logs"; Name="neo4j_logs"},
    @{LocalPath="docker\volumes\milvus\etcd"; Name="milvus_etcd"},
    @{LocalPath="docker\volumes\milvus\minio"; Name="milvus_minio"},
    @{LocalPath="docker\volumes\milvus\minio_config"; Name="milvus_minio_config"},
    @{LocalPath="docker\volumes\milvus\milvus"; Name="milvus_data"},
    @{LocalPath="docker\volumes\milvus\logs"; Name="milvus_logs"},
    @{LocalPath="docker\volumes\postgresql"; Name="postgres_data"}
)

foreach ($vol in $volumeExports) {
    $localPath = Join-Path $PROJECT_ROOT $vol.LocalPath
    $volName = $vol.Name
    $volZipPath = Join-Path $volumesDir "$volName.zip"
    
    if (Test-Path $localPath) {
        $items = Get-ChildItem -Path $localPath -Force -ErrorAction SilentlyContinue
        if ($items) {
            Write-Host "  Exporting: $volName" -ForegroundColor Gray
            
            if ($sevenZip) {
                # Use 7-Zip for better compression
                & $sevenZip a -tzip "$volZipPath" "$localPath\*" -mx=1 | Out-Null
                if (Test-Path $volZipPath) {
                    $sizeMB = [math]::Round((Get-Item $volZipPath).Length / 1MB, 2)
                    Write-Host "    -> $volName.zip ($sizeMB MB)" -ForegroundColor Green
                }
            } else {
                # Use PowerShell Compress-Archive
                try {
                    Compress-Archive -Path "$localPath\*" -DestinationPath $volZipPath -Force -CompressionLevel Optimal
                    $sizeMB = [math]::Round((Get-Item $volZipPath).Length / 1MB, 2)
                    Write-Host "    -> $volName.zip ($sizeMB MB)" -ForegroundColor Green
                } catch {
                    # If compression fails, try without compression
                    Write-Warning "  Compress-Archive failed, trying copy mode..."
                    $copyDir = Join-Path $volumesDir $volName
                    Copy-Item -Path $localPath -Destination $copyDir -Recurse -Force
                    $sizeMB = [math]::Round((Get-ChildItem $copyDir -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
                    Write-Host "    -> $volName/ ($sizeMB MB)" -ForegroundColor Green
                }
            }
        } else {
            Write-Warning "  Volume $volName is empty, skipping"
        }
    } else {
        Write-Warning "  Volume $volName not found, skipping"
    }
}

# Restart containers
if ($containersWereRunning.Count -gt 0) {
    Write-Step "Restarting containers..."
    foreach ($container in $containersWereRunning) {
        Write-Host "  Starting: $container" -ForegroundColor Yellow
        docker start $container 2>$null | Out-Null
    }
    Write-Success "Containers restarted"
}

# 3. Export config files
Write-Step "Exporting config files"

$configDir = Join-Path $BACKUP_DIR "config"
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

foreach ($config in $CONFIG_FILES) {
    $configPath = Join-Path $PROJECT_ROOT $config
    if (Test-Path $configPath) {
        Copy-Item -Path $configPath -Destination $configDir -Force
        Write-Host "  Copied: $config" -ForegroundColor Green
    } else {
        Write-Warning "  Config file $config not found, skipping"
    }
}

# 4. Create Windows import script
Write-Step "Creating Windows import script"

$importScript = @'
# GraphKnow Offline Deployment Script (Windows)
# Usage: Run as Administrator

$ErrorActionPreference = "Stop"

$PROJECT_ROOT = Split-Path -Parent $PSScriptRoot
$BACKUP_DIR = Split-Path -Parent $PSScriptRoot

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "GraphKnow Offline Deployment Script" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

# 1. Import images
Write-Host "`n[STEP 1/4] Importing Docker images..." -ForegroundColor Yellow
$imagesDir = Join-Path $BACKUP_DIR "images"
Get-ChildItem -Path $imagesDir -Filter "*.tar" | ForEach-Object {
    Write-Host "  Loading: $($_.Name)" -ForegroundColor Gray
    docker load -i $_.FullName
}

# 2. Restore volumes
Write-Host "`n[STEP 2/4] Restoring volumes..." -ForegroundColor Yellow
$volumesDir = Join-Path $BACKUP_DIR "volumes"
$projectVolumesDir = Join-Path $PROJECT_ROOT "docker\volumes"

# Create target directories
New-Item -ItemType Directory -Path "$projectVolumesDir\neo4j\data" -Force | Out-Null
New-Item -ItemType Directory -Path "$projectVolumesDir\neo4j\logs" -Force | Out-Null
New-Item -ItemType Directory -Path "$projectVolumesDir\milvus\etcd" -Force | Out-Null
New-Item -ItemType Directory -Path "$projectVolumesDir\milvus\minio" -Force | Out-Null
New-Item -ItemType Directory -Path "$projectVolumesDir\milvus\minio_config" -Force | Out-Null
New-Item -ItemType Directory -Path "$projectVolumesDir\milvus\milvus" -Force | Out-Null
New-Item -ItemType Directory -Path "$projectVolumesDir\milvus\logs" -Force | Out-Null
New-Item -ItemType Directory -Path "$projectVolumesDir\postgresql" -Force | Out-Null

Get-ChildItem -Path $volumesDir -Directory | ForEach-Object {
    $item = $_
    $volName = $item.Name
    $sourcePath = $item.FullName
    
    # Determine target directory based on volume name
    $targetDir = switch -Regex ($volName) {
        "neo4j_data" { Join-Path $projectVolumesDir "neo4j\data" }
        "neo4j_logs" { Join-Path $projectVolumesDir "neo4j\logs" }
        "milvus_etcd" { Join-Path $projectVolumesDir "milvus\etcd" }
        "milvus_minio_config" { Join-Path $projectVolumesDir "milvus\minio_config" }
        "milvus_minio" { Join-Path $projectVolumesDir "milvus\minio" }
        "milvus_data" { Join-Path $projectVolumesDir "milvus\milvus" }
        "milvus_logs" { Join-Path $projectVolumesDir "milvus\logs" }
        "postgres_data" { Join-Path $projectVolumesDir "postgresql" }
        default { $null }
    }
    
    if ($targetDir) {
        # Check if it's a zip file or a directory
        $zipFile = Get-ChildItem -Path $volumesDir -Filter "$volName.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($zipFile) {
            Write-Host "  Extracting: $volName -> $targetDir" -ForegroundColor Gray
            # Extract to temp then move contents
            $tempDir = Join-Path $projectVolumesDir "temp_$volName"
            Expand-Archive -Path $zipFile.FullName -DestinationPath $tempDir -Force
            
            # Move contents to target (handle the extra folder layer)
            $extractedContent = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
            if ($extractedContent) {
                Get-ChildItem -Path $extractedContent.FullName | Move-Item -Destination $targetDir -Force
            }
            Remove-Item -Recurse -Force $tempDir
        } else {
            # It's a directory copy
            Write-Host "  Copying: $volName -> $targetDir" -ForegroundColor Gray
            Get-ChildItem -Path $sourcePath | Move-Item -Destination $targetDir -Force
        }
    }
}

# 3. Copy config files
Write-Host "`n[STEP 3/4] Copying config files..." -ForegroundColor Yellow
$configDir = Join-Path $BACKUP_DIR "config"
Get-ChildItem -Path $configDir | ForEach-Object {
    $targetPath = Join-Path $PROJECT_ROOT $_.Name
    Copy-Item -Path $_.FullName -Destination $targetPath -Force
    Write-Host "  Copied: $($_.Name)" -ForegroundColor Green
}

# 4. Start services
Write-Host "`n[STEP 4/4] Starting services..." -ForegroundColor Yellow
Set-Location $PROJECT_ROOT
docker compose up -d

Write-Host "`n======================================" -ForegroundColor Green
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "Access at: http://localhost:5173" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Green
'@

$importScript | Out-File -FilePath (Join-Path $BACKUP_DIR "import_windows.ps1") -Encoding UTF8

# 5. Create Linux import script
$importScriptLinux = @'
#!/bin/bash
# GraphKnow Offline Deployment Script (Linux)
# Usage: bash import_linux.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$BACKUP_DIR")"

echo "======================================"
echo "GraphKnow Offline Deployment Script"
echo "======================================"

# 1. Import images
echo ""
echo "[STEP 1/4] Importing Docker images..."
IMAGES_DIR="$BACKUP_DIR/images"
for img in "$IMAGES_DIR"/*.tar; do
    if [ -f "$img" ]; then
        echo "  Loading: $(basename $img)"
        docker load -i "$img"
    fi
done

# 2. Restore volumes
echo ""
echo "[STEP 2/4] Restoring volumes..."
VOLUMES_DIR="$BACKUP_DIR/volumes"
PROJECT_VOLUMES_DIR="$PROJECT_ROOT/docker/volumes"

# Create target directories
mkdir -p "$PROJECT_VOLUMES_DIR/neo4j/data"
mkdir -p "$PROJECT_VOLUMES_DIR/neo4j/logs"
mkdir -p "$PROJECT_VOLUMES_DIR/milvus/etcd"
mkdir -p "$PROJECT_VOLUMES_DIR/milvus/minio"
mkdir -p "$PROJECT_VOLUMES_DIR/milvus/minio_config"
mkdir -p "$PROJECT_VOLUMES_DIR/milvus/milvus"
mkdir -p "$PROJECT_VOLUMES_DIR/milvus/logs"
mkdir -p "$PROJECT_VOLUMES_DIR/postgresql"

for item in "$VOLUMES_DIR"/*; do
    if [ -d "$item" ]; then
        vol_name=$(basename "$item")
        
        # Determine target directory based on volume name
        case $vol_name in
            "neo4j_data") target_dir="$PROJECT_VOLUMES_DIR/neo4j/data" ;;
            "neo4j_logs") target_dir="$PROJECT_VOLUMES_DIR/neo4j/logs" ;;
            "milvus_etcd") target_dir="$PROJECT_VOLUMES_DIR/milvus/etcd" ;;
            "milvus_minio_config") target_dir="$PROJECT_VOLUMES_DIR/milvus/minio_config" ;;
            "milvus_minio") target_dir="$PROJECT_VOLUMES_DIR/milvus/minio" ;;
            "milvus_data") target_dir="$PROJECT_VOLUMES_DIR/milvus/milvus" ;;
            "milvus_logs") target_dir="$PROJECT_VOLUMES_DIR/milvus/logs" ;;
            "postgres_data") target_dir="$PROJECT_VOLUMES_DIR/postgresql" ;;
            *) continue ;;
        esac
        
        echo "  Copying: $vol_name -> $target_dir"
        cp -r "$item/"* "$target_dir/"
    elif [ -f "$item" ]; then
        vol_name=$(basename "$item" .zip)
        
        # Determine target directory based on volume name
        case $vol_name in
            "neo4j_data") target_dir="$PROJECT_VOLUMES_DIR/neo4j/data" ;;
            "neo4j_logs") target_dir="$PROJECT_VOLUMES_DIR/neo4j/logs" ;;
            "milvus_etcd") target_dir="$PROJECT_VOLUMES_DIR/milvus/etcd" ;;
            "milvus_minio_config") target_dir="$PROJECT_VOLUMES_DIR/milvus/minio_config" ;;
            "milvus_minio") target_dir="$PROJECT_VOLUMES_DIR/milvus/minio" ;;
            "milvus_data") target_dir="$PROJECT_VOLUMES_DIR/milvus/milvus" ;;
            "milvus_logs") target_dir="$PROJECT_VOLUMES_DIR/milvus/logs" ;;
            "postgres_data") target_dir="$PROJECT_VOLUMES_DIR/postgresql" ;;
            *) continue ;;
        esac
        
        echo "  Extracting: $vol_name -> $target_dir"
        
        # Extract to temp then move contents
        temp_dir=$(mktemp -d)
        unzip -o "$item" -d "$temp_dir"
        
        # Move contents to target (handle the extra folder layer)
        first_dir=$(ls -1 "$temp_dir" | head -1)
        if [ -n "$first_dir" ] && [ -d "$temp_dir/$first_dir" ]; then
            cp -r "$temp_dir/$first_dir/"* "$target_dir/" 2>/dev/null || true
        fi
        rm -rf "$temp_dir"
    fi
done

# 3. Copy config files
echo ""
echo "[STEP 3/4] Copying config files..."
CONFIG_DIR="$BACKUP_DIR/config"
for cfg in "$CONFIG_DIR"/*; do
    if [ -f "$cfg" ]; then
        cp -f "$cfg" "$PROJECT_ROOT/"
        echo "  Copied: $(basename $cfg)"
    fi
done

# 4. Start services
echo ""
echo "[STEP 4/4] Starting services..."
cd "$PROJECT_ROOT"
docker compose up -d

echo ""
echo "======================================"
echo "Deployment complete!"
echo "Access at: http://localhost:5173"
echo "======================================"
'@

$importScriptLinux | Out-File -FilePath (Join-Path $BACKUP_DIR "import_linux.sh") -Encoding UTF8

# 6. Create final archive (without compression to avoid memory issues)
Write-Step "Creating final archive (directory mode)"

# Delete old backups (keep latest 3)
$oldBackups = Get-ChildItem -Path $OUTPUT_DIR -Filter "$BACKUP_NAME_*" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3
foreach ($old in $oldBackups) {
    Write-Host "  Removing old backup: $($old.Name)" -ForegroundColor Gray
    Remove-Item -Recurse -Force $old.FullName
}

# Calculate total size
$totalSize = (Get-ChildItem $BACKUP_DIR -Recurse | Measure-Object -Property Length -Sum).Sum
$totalSizeGB = [math]::Round($totalSize / 1GB, 2)

Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "Export complete!" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host "Backup directory: $BACKUP_DIR" -ForegroundColor Cyan
Write-Host "Total size: $totalSizeGB GB" -ForegroundColor Cyan
Write-Host ""
Write-Host "IMPORTANT: The backup is NOT compressed to avoid memory issues." -ForegroundColor Yellow
Write-Host "Please manually compress or transfer the folder:" -ForegroundColor White
Write-Host "  $BACKUP_DIR" -ForegroundColor Gray
Write-Host ""
Write-Host "Deployment instructions:" -ForegroundColor Yellow
Write-Host "  1. Transfer the entire folder to target machine" -ForegroundColor White
Write-Host "  2. Windows: Run import_windows.ps1 as Administrator" -ForegroundColor White
Write-Host "  3. Linux: Run bash import_linux.sh" -ForegroundColor White
Write-Host "======================================" -ForegroundColor Green
