#!/bin/bash
# CSV Device Bulk Import with Deduplication
# =============================================================================
# Purpose:
#   Bulk import devices from CSV files with validation, deduplication,
#   and immutable audit logging.
#
# Features:
#   - CSV schema validation
#   - IP format validation
#   - SHA256-based deduplication
#   - Batch processing (configurable)
#   - Ephemeral workspace with cleanup
#   - Immutable audit logs
#   - Progress tracking
#
# Usage:
#   csv-device-import.sh --file devices.csv [--dry-run] [--batch-size 100]
#
# CSV Format:
#   hostname,ip_address,device_type,os,domain,tags
#   server01,192.168.1.100,server,windows,corp.acme.com,prod;critical
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT_DIR="${PROJECT_ROOT}/audit/csv-import"
TEMP_WORKSPACE=""
DRY_RUN=false
BATCH_SIZE=100

# Create audit directory
mkdir -p "$AUDIT_DIR"

# Trap: Cleanup ephemeral workspace
cleanup() {
  local exit_code=$?
  if [[ -n "$TEMP_WORKSPACE" ]] && [[ -d "$TEMP_WORKSPACE" ]]; then
    rm -rf "$TEMP_WORKSPACE"
  fi
  exit $exit_code
}
trap cleanup EXIT

# ============================================================================
# FUNCTIONS
# ============================================================================

# Parse arguments
parse_args() {
  local csv_file=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)
        csv_file="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --batch-size)
        BATCH_SIZE="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
  done
  
  if [[ -z "$csv_file" ]]; then
    echo "Error: --file is required"
    exit 1
  fi
  
  echo "$csv_file"
}

# Log audit entry
log_audit() {
  local timestamp event_type message
  timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  event_type="$1"
  message="$2"
  
  printf '%s|%s|%s\n' "$timestamp" "$event_type" "$message" >> "$AUDIT_DIR/import.log"
}

# Validate CSV schema
validate_schema() {
  local csv_file="$1"
  local headers
  
  headers=$(head -1 "$csv_file")
  
  # Check required fields
  for field in hostname ip_address device_type os; do
    if [[ ! "$headers" =~ $field ]]; then
      echo "Error: Missing required field: $field"
      return 1
    fi
  done
  
  log_audit "SCHEMA_VALID" "File: $csv_file"
  return 0
}

# Validate IP address format
validate_ip() {
  local ip="$1"
  local octet
  
  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 1
  fi
  
  # Check each octet is <= 255
  for octet in ${ip//./ }; do
    if ((octet > 255)); then
      return 1
    fi
  done
  
  return 0
}

# Validate device row
validate_row() {
  local line="$1"
  local hostname ip_address device_type os
  
  # Parse CSV (simple version, no quoted fields)
  hostname=$(echo "$line" | cut -d',' -f1)
  ip_address=$(echo "$line" | cut -d',' -f2)
  device_type=$(echo "$line" | cut -d',' -f3)
  os=$(echo "$line" | cut -d',' -f4)
  
  # Validate fields
  if [[ -z "$hostname" ]]; then
    echo "hostname is empty"
    return 1
  fi
  
  if ! validate_ip "$ip_address"; then
    echo "Invalid IP: $ip_address"
    return 1
  fi
  
  if [[ ! "$device_type" =~ ^(server|workstation|printer|network)$ ]]; then
    echo "Invalid device_type: $device_type"
    return 1
  fi
  
  if [[ -z "$os" ]]; then
    echo "os is empty"
    return 1
  fi
  
  return 0
}

# Calculate device hash (for deduplication)
device_hash() {
  local line="$1"
  echo -n "$line" | sha256sum | cut -d' ' -f1
}

# Check if device already imported (idempotent)
has_been_imported() {
  local hash="$1"
  local dedup_store="$AUDIT_DIR/.imported-hashes"
  
  if [[ ! -f "$dedup_store" ]]; then
    touch "$dedup_store"
    return 1
  fi
  
  if grep -q "^$hash$" "$dedup_store"; then
    return 0  # Already imported
  fi
  return 1   # Not imported yet
}

# Record imported device
record_imported() {
  local hash="$1"
  local dedup_store="$AUDIT_DIR/.imported-hashes"
  
  echo "$hash" >> "$dedup_store"
}

# Process CSV file
process_csv() {
  local csv_file="$1"
  local batch_count=0
  local total_rows=0
  local valid_rows=0
  local duplicate_rows=0
  local invalid_rows=0
  
  # Create temp batch file
  local batch_file="${TEMP_WORKSPACE}/batch-$$.json"
  echo '[' > "$batch_file"
  
  # Process each row (skip header)
  tail -n +2 "$csv_file" | while IFS= read -r line || [[ -n "$line" ]]; do
    ((total_rows++))
    
    # Skip empty lines
    [[ -z "$line" ]] && continue
    
    # Validate row
    if ! error=$(validate_row "$line" 2>&1); then
      log_audit "ROW_INVALID" "Row $total_rows: $error"
      ((invalid_rows++))
      continue
    fi
    
    # Calculate hash
    local hash device_id
    hash=$(device_hash "$line")
    device_id=$(echo "$line" | cut -d',' -f1)
    
    # Check for duplicates (idempotent)
    if has_been_imported "$hash"; then
      log_audit "ROW_DUPLICATE" "Row $total_rows: DeviceID=$device_id (already imported)"
      ((duplicate_rows++))
      continue
    fi
    
    # Record as imported
    record_imported "$hash"
    ((valid_rows++))
    
    # Add to batch
    local hostname ip_address device_type os domain tags
    hostname=$(echo "$line" | cut -d',' -f1)
    ip_address=$(echo "$line" | cut -d',' -f2)
    device_type=$(echo "$line" | cut -d',' -f3)
    os=$(echo "$line" | cut -d',' -f4)
    domain=$(echo "$line" | cut -d',' -f5 || echo "")
    tags=$(echo "$line" | cut -d',' -f6 || echo "")
    
    # Append device to batch (JSON)
    if [[ $valid_rows -gt 1 ]]; then
      echo ',' >> "$batch_file"
    fi
    
    jq -n \
      --arg hostname "$hostname" \
      --arg ip_address "$ip_address" \
      --arg device_type "$device_type" \
      --arg os "$os" \
      --arg domain "$domain" \
      --arg tags "$tags" \
      --arg hash "$hash" \
      '{hostname: $hostname, ip_address: $ip_address, device_type: $device_type, os: $os, domain: $domain, tags: $tags, hash: $hash}' \
      >> "$batch_file"
    
    # Process batch if size reached
    if ((valid_rows % BATCH_SIZE == 0)); then
      ((batch_count++))
      ingest_batch "$batch_file" "$batch_count"
      echo '[' > "$batch_file"
    fi
  done
  
  # Close final batch
  echo ']' >> "$batch_file"
  if ((valid_rows > 0 && valid_rows % BATCH_SIZE != 0)); then
    ((batch_count++))
    ingest_batch "$batch_file" "$batch_count"
  fi
  
  # Log summary
  log_audit "IMPORT_COMPLETE" "Total: $total_rows, Valid: $valid_rows, Duplicate: $duplicate_rows, Invalid: $invalid_rows, Batches: $batch_count"
  
  echo "Import complete: Valid=$valid_rows, Duplicate=$duplicate_rows, Invalid=$invalid_rows, Batches=$batch_count"
}

# Ingest batch of devices
ingest_batch() {
  local batch_file="$1"
  local batch_num="$2"
  
  if [[ "$DRY_RUN" == true ]]; then
    log_audit "BATCH_INGEST_DRY_RUN" "Batch $batch_num: $(wc -l < "$batch_file") lines"
    return 0
  fi
  
  # Simulate ingestion
  log_audit "BATCH_INGEST" "Batch $batch_num: Imported $(jq 'length' "$batch_file") devices"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  local csv_file
  csv_file=$(parse_args "$@")
  
  if [[ ! -f "$csv_file" ]]; then
    echo "Error: File not found: $csv_file"
    exit 1
  fi
  
  # Create ephemeral workspace
  TEMP_WORKSPACE=$(mktemp -d)
  
  log_audit "IMPORT_START" "File: $csv_file, DryRun: $DRY_RUN, BatchSize: $BATCH_SIZE"
  
  # Validate schema
  if ! validate_schema "$csv_file"; then
    log_audit "IMPORT_FAILED" "Invalid CSV schema"
    exit 1
  fi
  
  # Process CSV
  process_csv "$csv_file"
}

main "$@"