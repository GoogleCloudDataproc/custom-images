#!/bin/bash
#
# Dual-mode audit and diagnostic tool for GCE image customization.
# 
# Workstation Mode: Copies itself to the active GCE builder VM, executes
#                   remotely, and prints the captured JSON state report.
# Guest Mode:       Runs locally on the GCE VM, performs parallel probes,
#                   and outputs a structured JSON report to stdout.

set -euo pipefail

# --- Environment Detection ---
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_JSON="${SCRIPT_DIR}/../../env.json"

# If env.json exists two levels up from the script, we are on the Workstation.
# On the VM, the script is copied to /tmp, so this file will not exist.
if [[ -f "${ENV_JSON}" ]]; then
  ROLE="workstation"
else
  ROLE="guest"
fi

# ==========================================
# GUEST MODE: Run Parallel Probes on the VM
# ==========================================
if [[ "${ROLE}" == "guest" ]]; then
  MDS_PREFIX="http://metadata.google.internal/computeMetadata/v1"
  AUDIT_TEMP_DIR=$(mktemp -d)
  PIDS=()

  # Helper to run a probe in the background and save JSON fragment
  run_probe() {
    local -r key="$1"
    shift
    (
      "$@" > "${AUDIT_TEMP_DIR}/${key}.json" 2> "${AUDIT_TEMP_DIR}/${key}.err"
    ) &
    PIDS+=( $! )
  }

  # Probe 1: GCE Metadata Attributes
  probe_metadata() {
    local -r attributes=(
      "http-proxy"
      "https-proxy"
      "proxy-uri"
      "no-proxy"
      "dataproc-cluster-name"
      "http-proxy-pem-uri"
      "universe-domain"
      "custom-sources-path"
      "project-id"
    )
    echo -n "{"
    local first=true
    for attr in "${attributes[@]}"; do
      local val
      val=$(curl -s -f -H "Metadata-Flavor: Google" "${MDS_PREFIX}/instance/attributes/${attr}" || echo "")
      if [[ -z "${val}" ]]; then
        val=$(curl -s -f -H "Metadata-Flavor: Google" "${MDS_PREFIX}/project/attributes/${attr}" || echo "")
      fi
      
      if [[ -n "${val}" ]]; then
        if [[ "${first}" == "true" ]]; then first=false; else echo -n ","; fi
        # Escape newlines and quotes in the value for safe JSON
        local escaped_val
        escaped_val=$(echo -n "${val}" | jq -R .)
        echo -n "\"${attr}\": ${escaped_val}"
      fi
    done
    echo -n "}"
  }
  run_probe "metadata" probe_metadata

  # Probe 2: Network Connectivity (Direct vs Proxy)
  probe_network() {
    local http_proxy_val
    http_proxy_val=$(curl -s -f -H "Metadata-Flavor: Google" "${MDS_PREFIX}/instance/attributes/http-proxy" || echo "")
    if [[ -z "${http_proxy_val}" ]]; then
      http_proxy_val=$(curl -s -f -H "Metadata-Flavor: Google" "${MDS_PREFIX}/instance/attributes/proxy-uri" || echo "")
    fi

    local direct_gcs="fail"
    local proxy_gcs="fail"
    local direct_ext="fail"
    local proxy_ext="fail"

    # Test direct GCS (should succeed if PGA is active, even without proxy/NAT)
    if curl -s -f -o /dev/null --connect-timeout 3 "https://storage.googleapis.com" &>/dev/null; then
      direct_gcs="success"
    fi

    # Test direct external (should fail in isolated network)
    if curl -s -f -o /dev/null --connect-timeout 3 "https://www.google.com" &>/dev/null; then
      direct_ext="success"
    fi

    # Test via proxy (if proxy metadata exists)
    if [[ -n "${http_proxy_val}" ]]; then
      if curl -s -f -x "http://${http_proxy_val}" -o /dev/null --connect-timeout 3 "https://storage.googleapis.com" &>/dev/null; then
        proxy_gcs="success"
      fi
      if curl -s -f -x "http://${http_proxy_val}" -o /dev/null --connect-timeout 3 "https://www.google.com" &>/dev/null; then
        proxy_ext="success"
      fi
    fi

    cat <<EOF
{
  "direct_gcs_connectivity": "${direct_gcs}",
  "proxy_gcs_connectivity": "${proxy_gcs}",
  "direct_external_connectivity": "${direct_ext}",
  "proxy_external_connectivity": "${proxy_ext}"
}
EOF
  }
  run_probe "network" probe_network

  # Probe 3: OS & System State
  probe_system() {
    local os_id="unknown"
    if [[ -f /etc/os-release ]]; then
      os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | xargs)
    fi

    local systemd_pid1="false"
    if [[ -d /run/systemd/system ]]; then
      systemd_pid1="true"
    fi

    local java_home=""
    if [[ -f /etc/environment ]]; then
      java_home=$(awk -F= '/^JAVA_HOME=/ {print $2}' /etc/environment || echo "")
    fi

    cat <<EOF
{
  "os_id": "${os_id}",
  "systemd_is_pid1": "${systemd_pid1}",
  "java_home": "${java_home}"
}
EOF
  }
  run_probe "system" probe_system

  # Wait for all parallel probes to finish
  for pid in "${PIDS[@]}"; do
    wait "${pid}" || true
  done

  # Assemble the final JSON report
  echo -n "{"
  echo -n "\"metadata\": $(cat "${AUDIT_TEMP_DIR}/metadata.json"),"
  echo -n "\"network\": $(cat "${AUDIT_TEMP_DIR}/network.json"),"
  echo -n "\"system\": $(cat "${AUDIT_TEMP_DIR}/system.json")"
  echo "}"

  # Cleanup
  rm -rf "${AUDIT_TEMP_DIR}"
  exit 0
fi

# ==========================================
# HOST MODE: Run on Developer Workstation
# ==========================================
if [[ "${ROLE}" == "workstation" ]]; then
  # SCRIPT_DIR and ENV_JSON are defined globally at the top of the script
  if [[ ! -f "${ENV_JSON}" ]]; then
    echo "ERROR: Configuration file ${ENV_JSON} not found." >&2
    exit 1
  fi

  # 1. Parse GCE Project and Zone from env.json
  PROJECT_ID=$(jq -r '.project_id // .PROJECT_ID // empty' "${ENV_JSON}")
  ZONE=$(jq -r '.zone // .ZONE // empty' "${ENV_JSON}")

  if [[ -z "${PROJECT_ID}" || -z "${ZONE}" ]]; then
    echo "ERROR: project_id or zone not defined in env.json." >&2
    exit 1
  fi

  echo "DEBUG: Workstation Mode - Querying GCE for active customization instance..." >&2

  # 2. Dynamically discover the active builder VM name
  # The builder VM name matches the pattern: dataproc-[version]-[timestamp]-install
  VM_NAME=$(gcloud compute instances list --project="${PROJECT_ID}" \
    --filter="name:dataproc-*-install AND zone:(${ZONE})" \
    --format="value(name)" | head -n 1)

  if [[ -z "${VM_NAME}" ]]; then
    echo "ERROR: No active GCE customization instance found in project ${PROJECT_ID} (zone ${ZONE})." >&2
    exit 1
  fi

  echo "DEBUG: Found active builder VM: ${VM_NAME}" >&2
  echo "DEBUG: Copying audit script to VM..." >&2

  # 3. SCP this script to the VM (using non-interactive batch mode)
  gcloud compute scp "${SCRIPT_DIR}/audit-image-customizer.sh" "${VM_NAME}:/tmp/audit-image-customizer.sh" \
    --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap --quiet \
    --ssh-flag="-o BatchMode=yes" --ssh-flag="-o ConnectTimeout=5" \
    --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" &>/dev/null

  echo "DEBUG: Executing audit script remotely on VM..." >&2

  # 4. SSH into the VM, run the script, and capture the JSON stdout
  set +e
  JSON_REPORT=$(gcloud compute ssh "${VM_NAME}" \
    --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap --quiet \
    --ssh-flag="-o BatchMode=yes" --ssh-flag="-o ConnectTimeout=5" \
    --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
    --command="bash /tmp/audit-image-customizer.sh" 2>/dev/null)
  RETVAL=$?
  set -e

  # Clean up the script on the VM
  gcloud compute ssh "${VM_NAME}" \
    --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap --quiet \
    --ssh-flag="-o BatchMode=yes" --ssh-flag="-o ConnectTimeout=5" \
    --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
    --command="rm -f /tmp/audit-image-customizer.sh" &>/dev/null || true

  if [[ ${RETVAL} -ne 0 || -z "${JSON_REPORT}" ]]; then
    echo "ERROR: Failed to execute remote audit on VM." >&2
    exit 1
  fi

  # 5. Output the pretty-printed JSON report to the developer
  echo "${JSON_REPORT}" | jq .
  exit 0
fi
