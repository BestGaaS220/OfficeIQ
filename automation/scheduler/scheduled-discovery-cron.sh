#!/bin/bash
# Scheduled On-Premise Device Discovery Scanner
# =============================================================================
# Purpose:
#   Run automated discovery scans on fixed schedule (hourly/daily/weekly)
#   with immutable audit logging and ephemeral workspace management.
#
# Features:
#   - Ephemeral temp workspace with trap cleanup
#   - Idempotent execution with SHA256 deduplication
#   - Immutable audit logs for compliance
#   - Auto-remediation: Automatic domain joins
#   - Health checks and webhook triggers
#   - Metrics collection and monitoring
#
# Usage:
#   scheduled-discovery-cron.sh [hourly|daily|weekly]
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/scheduler"
AUDIT_DIR="${PROJECT_ROOT}/audit/discovery"
TEMP_WORKSPACE=""
DEDUP_STORE="${AUDIT_DIR}/.dedup-hashes"

# Create directories
mkdir -p "$LOG_DIR" "$AUDIT_DIR"
touch "$DEDUP_STORE"

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

# Log entry with immutable audit trail
log_audit() {
  local timestamp event_type message
  timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  event_type="$1"
  message="$2"
  
  # Immutable append-only log
  printf '%s|%s|%s\n' "$timestamp" "$event_type" "$message" >> "$AUDIT_DIR/audit.log"
}

# Check if device already processed (idempotent)
has_been_processed() {
  local device_id="$1"
  local current_hash="$2"
  
  if grep -q "^$device_id:$current_hash$" "$DEDUP_STORE" 2>/dev/null; then
    return 0  # Already processed
  fi
  return 1   # Not processed yet
}

# Record device processing (immutable)
record_processing() {
  local device_id="$1"
  local device_hash="$2"
  
  # Append to dedup store (immutable)
  printf '%s:%s\n' "$device_id" "$device_hash" >> "$DEDUP_STORE"
}

# Run discovery scan
run_discovery() {
  local schedule="$1"
  local timestamp devices_file results_file
  
  timestamp=$(date +'%Y%m%d_%H%M%S')
  TEMP_WORKSPACE=$(mktemp -d)
  devices_file="${TEMP_WORKSPACE}/devices.json"
  results_file="${TEMP_WORKSPACE}/results.json"
  
  log_audit "SCAN_START" "Schedule: $schedule"
  
  # Run discovery scanner
  if bash "$PROJECT_ROOT/automation/scanners/onprem-device-discovery.sh" \
    --output "$devices_file" \
    --timeout 300 \
    2>"${TEMP_WORKSPACE}/scanner.err"; then
    
    log_audit "SCAN_COMPLETE" "Devices discovered: $(jq 'length' "$devices_file" 2>/dev/null || echo 0)"
    
    # Process each device (idempotent)
    process_devices "$devices_file" "$results_file"
    
  else
    log_audit "SCAN_FAILED" "Error: $(tail -1 "${TEMP_WORKSPACE}/scanner.err" || echo 'Unknown')"
    return 1
  fi
}

# Process discovered devices
process_devices() {
  local devices_file="$1"
  local results_file="$2"
  local device_count=0
  local joined_count=0
  
  # Create results array
  echo '[]' > "$results_file"
  
  # Process each device (using jq for JSON parsing)
  jq -c '.[]' "$devices_file" | while read -r device; do
    local device_id hostname device_hash
    device_id=$(echo "$device" | jq -r '.device_id')
    hostname=$(echo "$device" | jq -r '.hostname')
    device_hash=$(echo "$device" | sha256sum | cut -d' ' -f1)
    
    ((device_count++))
    
    # Check if already processed (idempotent)
    if has_been_processed "$device_id" "$device_hash"; then
      log_audit "SKIP_DUPLICATE" "Device: $hostname (hash: $device_hash)"
      continue
    fi
    
    # Record processing
    record_processing "$device_id" "$device_hash"
    log_audit "DEVICE_INGESTED" "Device: $hostname (ID: $device_id)"
    
    # Trigger domain join (auto-remediation)
    if trigger_domain_join "$device"; then
      ((joined_count++))
      log_audit "DOMAIN_JOIN_TRIGGERED" "Device: $hostname"
    fi
  done
  
  log_audit "DEVICES_PROCESSED" "Total: $device_count, Joined: $joined_count"
}

# Trigger automatic domain joining
trigger_domain_join() {
  local device="$1"
  local hostname
  hostname=$(echo "$device" | jq -r '.hostname')
  
  # Call orchestrator for domain join
  if bash "$PROJECT_ROOT/automation/orchestrator/onprem-discovery-domain-join-orchestrator.sh" \
    --device-id "$(echo "$device" | jq -r '.device_id')" \
    --hostname "$hostname" \
    --domain "$(echo "$device" | jq -r '.domain // "corp.acme.com"')" \
    --dry-run false \
    2>&1 | grep -q "SUCCESS"; then
    return 0
  fi
  return 1
}

# Send webhook notification
send_webhook_notification() {
  local event_type="$1"
  local data="$2"
  local webhook_url webhook_payload
  
  webhook_url="${WEBHOOK_URL:-}"
  [[ -z "$webhook_url" ]] && return 0  # Skip if not configured
  
  webhook_payload=$(jq -n \
    --arg event "$event_type" \
    --argjson data "$data" \
    '{event: $event, timestamp: now, data: $data}')
  
  curl -s -X POST "$webhook_url" \
    -H 'Content-Type: application/json' \
    -d "$webhook_payload" || true
}

# Collect metrics
collect_metrics() {
  local schedule="$1"
  local metrics_file
  metrics_file="${LOG_DIR}/metrics-${schedule}-$(date +'%Y%m%d').json"
  
  jq -n \
    --arg schedule "$schedule" \
    --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg audit_entries "$(wc -l < "$AUDIT_DIR/audit.log" || echo 0)" \
    --arg dedup_count "$(wc -l < "$DEDUP_STORE" || echo 0)" \
    '{schedule: $schedule, timestamp: $timestamp, audit_entries: $audit_entries, dedup_hashes: $dedup_count}' \
    >> "$metrics_file"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  local schedule="${1:-hourly}"
  
  # Validate schedule
  case "$schedule" in
    hourly|daily|weekly) ;;
    *) echo "Invalid schedule: $schedule"; exit 1 ;;
  esac
  
  log_audit "SCHEDULER_START" "Schedule: $schedule"
  
  # Run discovery
  run_discovery "$schedule"
  
  # Collect metrics
  collect_metrics "$schedule"
  
  # Send notification
  send_webhook_notification "discovery_scan_complete" "$(jq -n --arg schedule "$schedule" '{schedule: $schedule}')"
  
  log_audit "SCHEDULER_SUCCESS" "Schedule: $schedule completed"
}

main "${1:-hourly}"