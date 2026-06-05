#!/bin/bash

set -euo pipefail

# --- Metadata Helpers ---
function print_metadata_value() {
  local -r url="${1}"
  # print_metadata_value is a legacy wrapper around get_cached_state
  get_cached_state "${url}" ""
}

function print_metadata_value_if_exists() {
  local return_code=1
  local readonly url=$1
  print_metadata_value "${url}"
  return_code=$?
  return ${return_code}
}

# replicates /usr/share/google/get_metadata_value
function get_metadata_value() {
  local readonly varname=$1
  local -r MDS_PREFIX=http://metadata.google.internal/computeMetadata/v1
  # Print the instance metadata value.
  print_metadata_value_if_exists ${MDS_PREFIX}/instance/${varname}
  return_code=$?
  # If the instance doesn't have the value, try the project.
  if [[ ${return_code} != 0 ]]; then
    print_metadata_value_if_exists ${MDS_PREFIX}/project/${varname}
    return_code=$?
  fi
  return ${return_code}
}

function get_metadata_attribute() {
  local -r attribute_name="$1"
  local -r default_value="${2:-}"
  set +e
  get_metadata_value "attributes/${attribute_name}" || echo -n "${default_value}"
  set -e
}
# --- End Metadata Helpers ---

function initialize_guest_state() {
  local -r cache_dir="/dev/shm/metadata_cache"
  mkdir -p "${cache_dir}"

  # 1. Verify jq presence upfront to prevent downstream silent crashes
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed. Aborting." >&2
    exit 1
  fi

  local -r MDS_PREFIX="http://metadata.google.internal/computeMetadata/v1"
  echo "DEBUG: Freezing GCE metadata and system state in JSON cache..." >&2

  # 2. GCE Metadata Probe: Fetch only instance attributes recursively,
  # and project-id non-recursively. This avoids downloading massive project-wide SSH keys.
  local instance_json
  instance_json=$(curl -s -f -H "Metadata-Flavor: Google" \
    --connect-timeout 2 --max-time 5 "${MDS_PREFIX}/instance/?recursive=true" 2>/dev/null) || instance_json="{}"

  local project_id
  project_id=$(curl -s -f -H "Metadata-Flavor: Google" \
    --connect-timeout 2 --max-time 5 "${MDS_PREFIX}/project/project-id" 2>/dev/null) || project_id=""

  # Construct a clean, lightweight metadata_root.json to mimic the GCE MDS structure
  if ! jq -n \
    --argjson inst "${instance_json}" \
    --arg proj_id "${project_id}" \
    '{instance: $inst, project: {"project-id": $proj_id}}' \
    > "${cache_dir}/metadata_root.json" 2>/dev/null; then
    # Fallback if jq compilation fails
    echo "{}" > "${cache_dir}/metadata_root.json"
  fi

  # 3. System Introspection Probes: Audit OS, systemd, and services up front
  local -r os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | xargs || echo "unknown")

  local systemd_is_pid1="false"
  if [[ -d /run/systemd/system ]]; then
    systemd_is_pid1="true"
  fi

  local proxy_service_provisioned="false"
  if [[ -f /etc/systemd/system/dataproc-proxy-init.service ]]; then
    proxy_service_provisioned="true"
  fi

  local proxy_vars_in_env="false"
  if grep -q "http_proxy=" /etc/environment 2>/dev/null; then
    proxy_vars_in_env="true"
  fi

  local proxy_vars_in_systemd="false"
  if [[ -f /etc/systemd/system.conf.d/10-default-env.conf ]]; then
    proxy_vars_in_systemd="true"
  fi

  # Write audited system states into a single, clean JSON file
  cat <<EOF > "${cache_dir}/system_state.json"
{
  "os_id": "${os_id}",
  "systemd_is_pid1": "${systemd_is_pid1}",
  "proxy_service_provisioned": "${proxy_service_provisioned}",
  "proxy_vars_in_env": "${proxy_vars_in_env}",
  "proxy_vars_in_systemd": "${proxy_vars_in_systemd}"
}
EOF

  echo "DEBUG: Comprehensive guest state JSON cache initialized." >&2
}

# --- OS Detection Helpers (Decoupled & JSON Cache-Backed) ---
function get_cached_state() {
  local -r key="${1}"
  local -r default="${2:-}"
  local -r cache_dir="/dev/shm/metadata_cache"

  if [[ "${key}" =~ ^http://metadata.google.internal/computeMetadata/v1/(.+) ]]; then
    # Extract the relative path from the GCE URL (e.g. "instance/attributes/dataproc-cluster-name")
    local -r relative_path="${BASH_REMATCH[1]}"
    local -r cache_file="${cache_dir}/metadata_root.json"

    if [[ -f "${cache_file}" ]]; then
      # Convert the slash-separated path into a bracket-notation jq filter
      # e.g. "instance/attributes/foo" -> '.["instance"]["attributes"]["foo"]'
      local jq_filter="."
      local path_parts
      IFS='/' read -r -a path_parts <<< "${relative_path}"
      for part in "${path_parts[@]}"; do
        jq_filter+="[\"${part}\"]"
      done
      jq_filter+=" // empty"

      local value
      value=$(jq -r "${jq_filter}" "${cache_file}" 2>/dev/null) || value=""
      if [[ -n "${value}" ]]; then
        echo -n "${value}"
        return 0
      fi
    fi
  elif [[ "${key}" =~ ^system/(.+) ]]; then
    # System state key (queries system_state.json)
    local -r attr_name="${BASH_REMATCH[1]}"
    local -r cache_file="${cache_dir}/system_state.json"

    if [[ -f "${cache_file}" ]]; then
      local value
      value=$(jq -r --arg key "${attr_name}" '.[$key] // empty' "${cache_file}" 2>/dev/null) || value=""
      if [[ -n "${value}" ]]; then
        echo -n "${value}"
        return 0
      fi
    fi
  fi

  # Strict Cache Enforcement: Any GCE metadata key MUST be cached. No network fallbacks.
  echo -n "${default}"
  return 1
}

function os_id()       { get_cached_state 'system/os_id' 'unknown'; }
function is_debuntu()  { [[ "$(os_id)" == "debian" || "$(os_id)" == "ubuntu" ]]; }
function is_rocky()    { [[ "$(os_id)" == "rocky" ]]; }
# --- End OS Detection Helpers ---

# --- Version Comparison Helpers ---
function version_ge(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|tail -n1)" ]]; }
function version_le(){ [[ "$1" = "$(echo -e "$1\n$2"|sort -V|head -n1)" ]]; }
function version_lt(){ [[ "$1" = "$2" ]] && return 1 || version_le "$1" "$2"; }
# --- End Version Comparison Helpers ---

function execute_with_retries() {
  local -r cmd="$*"
  local retries=3
  local delay=5
  for ((i = 0; i < retries; i++)); do
    eval "${cmd}" && return 0
    echo "Command failed. Retrying in ${delay} seconds..." >&2
    sleep "${delay}"
  done
  echo "Command failed after ${retries} retries: ${cmd}" >&2
  return 1
}

function set_proxy(){
  local -r BLUE='\033[0;34m'
  local -r GREEN='\033[0;32m'
  local -r YELLOW='\033[1;33m'
  local -r NC='\033[0m'

  local meta_http_proxy meta_https_proxy meta_proxy_uri
  meta_http_proxy=$(get_metadata_attribute 'http-proxy' '')
  meta_https_proxy=$(get_metadata_attribute 'https-proxy' '')
  meta_proxy_uri=$(get_metadata_attribute 'proxy-uri' '')

  local http_proxy_val=""
  local https_proxy_val=""

  # Determine HTTP_PROXY value
  if [[ -n "${meta_http_proxy}" ]] && [[ "${meta_http_proxy}" != ":" ]]; then
    http_proxy_val="${meta_http_proxy}"
  elif [[ -n "${meta_proxy_uri}" ]] && [[ "${meta_proxy_uri}" != ":" ]]; then
    http_proxy_val="${meta_proxy_uri}"
  fi

  # Determine HTTPS_PROXY value
  if [[ -n "${meta_https_proxy}" ]] && [[ "${meta_https_proxy}" != ":" ]]; then
    https_proxy_val="${meta_https_proxy}"
  elif [[ -n "${meta_proxy_uri}" ]] && [[ "${meta_proxy_uri}" != ":" ]]; then
    https_proxy_val="${meta_proxy_uri}"
  fi

  # Check actual state
  local -r actual_env_proxy=$(get_cached_state 'system/proxy_vars_in_env' 'false')
  local -r actual_systemd_proxy=$(get_cached_state 'system/proxy_vars_in_systemd' 'false')
  local -r actual_service_provisioned=$(get_cached_state 'system/proxy_service_provisioned' 'false')

  echo -e "${BLUE}--- PLANNING & RECONCILIATION ---${NC}" >&2
  echo -e "  Asserted HTTP Proxy  : ${YELLOW}${http_proxy_val:-none}${NC}" >&2
  echo -e "  Asserted HTTPS Proxy : ${YELLOW}${https_proxy_val:-none}${NC}" >&2

  if [[ -z "${http_proxy_val}" && -z "${https_proxy_val}" ]]; then
    echo -e "  Status: No proxy is asserted in GCE metadata." >&2
    echo -e "  Plan: [SKIP] Skipping all proxy configuration modifications." >&2
    echo -e "${BLUE}---------------------------------${NC}" >&2
    return 0
  fi

  echo -e "  Status: Proxy is ${GREEN}ASSERTED${NC} by GCE metadata." >&2

  local plan_env_update="false"
  local plan_systemd_update="false"
  local plan_service_update="false"

  # 1. Compare /etc/environment
  if [[ "${actual_env_proxy}" == "true" ]]; then
    echo -e "  Plan: [SKIP] /etc/environment already has proxy configured." >&2
  else
    echo -e "  Plan: ${YELLOW}[ACTION]${NC} Inject proxy into /etc/environment." >&2
    plan_env_update="true"
  fi

  # 2. Compare systemd manager
  if [[ "${actual_systemd_proxy}" == "true" ]]; then
    echo -e "  Plan: [SKIP] systemd manager already has proxy configured." >&2
  else
    echo -e "  Plan: ${YELLOW}[ACTION]${NC} Inject proxy into systemd manager configuration." >&2
    plan_systemd_update="true"
  fi

  # 3. Compare deferred service (only for image builds or custom sources)
  if [[ "${IS_CUSTOM_IMAGE_BUILD:-}" == "true" || -n "$(get_metadata_attribute 'custom-sources-path' '')" ]]; then
    if [[ "${actual_service_provisioned}" == "true" ]]; then
      echo -e "  Plan: [SKIP] Deferred systemd service is already provisioned." >&2
    else
      echo -e "  Plan: ${YELLOW}[ACTION]${NC} Provision deferred systemd service for boot-persistence." >&2
      plan_service_update="true"
    fi
  fi
  echo -e "${BLUE}---------------------------------${NC}" >&2

  # Idempotency Check: If everything is already configured, exit cleanly!
  # If FORCE_APPLY=1 is set, bypass this check and force all mutations.
  if [[ "${FORCE_APPLY:-0}" -eq 1 ]]; then
    echo -e "${YELLOW}INFO: FORCE_APPLY=1 is set. Bypassing idempotency and forcing all mutations!${NC}" >&2
    plan_env_update="true"
    plan_systemd_update="true"
    if [[ "${IS_CUSTOM_IMAGE_BUILD:-}" == "true" || -n "$(get_metadata_attribute 'custom-sources-path' '')" ]]; then
      plan_service_update="true"
    fi
  elif [[ "${plan_env_update}" == "false" && "${plan_systemd_update}" == "false" && "${plan_service_update}" == "false" ]]; then
    echo "INFO: Actual state matches Desired state. No mutations required." >&2
    return 0
  fi

  local default_no_proxy_list=(
    "localhost"
    "127.0.0.1"
    "::1"
    "metadata.google.internal"
    "169.254.169.254"
    ".google.com"
    ".googleapis.com"
    ".internal"
  )

  # Add project-specific internal domain
  local project_id
  project_id=$(get_metadata_attribute 'project-id' "${PROJECT_ID:-}")
  if [[ -n "${project_id}" ]]; then
    default_no_proxy_list+=( ".c.${project_id}.internal" )
  fi

  # Add cluster-specific hostnames
  local cluster_name
  cluster_name=$(get_metadata_attribute 'dataproc-cluster-name' '')
  if [[ -z "${cluster_name}" ]]; then
    # Fallback: Derive from hostname if it matches Dataproc naming convention
    local hostname
    hostname=$(uname -n)
    hostname="${hostname%%.*}"
    if [[ "${hostname}" =~ ^(.+)-(m|w|sw)(-[0-9]+)?$ ]]; then
      cluster_name="${BASH_REMATCH[1]}"
      echo "DEBUG: set_proxy: Derived cluster name '${cluster_name}' from hostname '${hostname}'" >&2
    else
      echo "DEBUG: set_proxy: Hostname '${hostname}' does not match Dataproc naming convention. Skipping wildcard derivation." >&2
    fi
  fi
  if [[ -n "${cluster_name}" ]]; then
    # Add wildcard patterns (supported by some tools like Go/Java)
    default_no_proxy_list+=( "${cluster_name}-m" "${cluster_name}-m-*" "${cluster_name}-w-*" "${cluster_name}-sw-*" )
    # Add FQDN suffixes to ensure bypass for tools like curl/wget
    default_no_proxy_list+=( "${cluster_name}-m.c.${project_id}.internal" )
    default_no_proxy_list+=( ".c.${project_id}.internal" )
  fi

  local user_no_proxy
  user_no_proxy=$(get_metadata_attribute 'no-proxy' '')
  local user_no_proxy_list=()
  if [[ -n "${user_no_proxy}" ]]; then
    IFS=$' \t\n' read -r -a user_no_proxy_list <<< "${user_no_proxy//,/ }"
  fi

  local combined_no_proxy_list=( "${default_no_proxy_list[@]}" "${user_no_proxy_list[@]}" )
  local no_proxy
  no_proxy=$( IFS=',' ; echo "${combined_no_proxy_list[*]}" )
  export NO_PROXY="${no_proxy}"
  export no_proxy="${no_proxy}"

  # Export environment variables
  if [[ -n "${http_proxy_val}" ]]; then
    export HTTP_PROXY="http://${http_proxy_val}"
    export http_proxy="http://${http_proxy_val}"
  fi
  if [[ -n "${https_proxy_val}" ]]; then
    export HTTPS_PROXY="http://${https_proxy_val}"
    export https_proxy="http://${https_proxy_val}"
  fi

  # Clear existing proxy settings in /etc/environment
  sed -i -e '/^http_proxy=/d' -e '/^https_proxy=/d' -e '/^no_proxy=/d' \
    -e '/^HTTP_PROXY=/d' -e '/^HTTPS_PROXY=/d' -e '/^NO_PROXY=/d' /etc/environment

  # Add current proxy environment variables to /etc/environment
  if [[ -n "${HTTP_PROXY:-}" ]]; then echo "HTTP_PROXY=${HTTP_PROXY}" >> /etc/environment; fi
  if [[ -n "${http_proxy:-}" ]]; then echo "http_proxy=${http_proxy}" >> /etc/environment; fi
  if [[ -n "${HTTPS_PROXY:-}" ]]; then echo "HTTPS_PROXY=${HTTPS_PROXY}" >> /etc/environment; fi
  if [[ -n "${https_proxy:-}" ]]; then echo "https_proxy=${https_proxy}" >> /etc/environment; fi
  if [[ -n "${NO_PROXY:-}" ]]; then echo "NO_PROXY=${NO_PROXY}" >> /etc/environment; fi
  if [[ -n "${NO_PROXY:-}" ]]; then echo "no_proxy=${no_proxy}" >> /etc/environment; fi

  # Persist for all shell sessions
  local profile_script="/etc/profile.d/proxy.sh"
  echo "# Proxy settings from Dataproc init action" > "${profile_script}"
  if [[ -n "${HTTP_PROXY:-}" ]]; then echo "export HTTP_PROXY='${HTTP_PROXY}'" >> "${profile_script}"; fi
  if [[ -n "${http_proxy:-}" ]]; then echo "export http_proxy='${http_proxy}'" >> "${profile_script}"; fi
  if [[ -n "${HTTPS_PROXY:-}" ]]; then echo "export HTTPS_PROXY='${HTTPS_PROXY}'" >> "${profile_script}"; fi
  if [[ -n "${https_proxy:-}" ]]; then echo "export https_proxy='${https_proxy}'" >> "${profile_script}"; fi
  if [[ -n "${NO_PROXY:-}" ]]; then echo "export NO_PROXY='${NO_PROXY}'" >> "${profile_script}"; fi
  if [[ -n "${no_proxy:-}" ]]; then echo "export no_proxy='${no_proxy}'" >> "${profile_script}"; fi

  # Source the script to apply settings to the current shell
  source "${profile_script}"

  # Configure gcloud proxy
  local gcloud_version
  local -r min_gcloud_proxy_ver="547.0.0"
  gcloud_version=$(gcloud version --format="value(google_cloud_sdk)" 2>/dev/null || echo "0.0.0")
  if version_ge "${gcloud_version}" "${min_gcloud_proxy_ver}"; then
    if [[ -n "${http_proxy_val}" ]]; then
      local proxy_host=$(echo "${http_proxy_val}" | cut -d: -f1)
      local proxy_port=$(echo "${http_proxy_val}" | cut -d: -f2)
      gcloud config set proxy/type http
      gcloud config set proxy/address "${proxy_host}"
      gcloud config set proxy/port "${proxy_port}"
    else
      gcloud config unset proxy/type
      gcloud config unset proxy/address
      gcloud config unset proxy/port
    fi
  fi

  # Install the HTTPS proxy's certificate
  local proxy_ca_pem=""
  local trusted_pem_path=""
  METADATA_HTTP_PROXY_PEM_URI="$(get_metadata_attribute http-proxy-pem-uri '')"
  if [[ -n "${METADATA_HTTP_PROXY_PEM_URI}" ]] ; then
    if [[ ! "${METADATA_HTTP_PROXY_PEM_URI}" =~ ^gs:// ]] ; then echo "ERROR: http-proxy-pem-uri value must start with gs://" ; exit 1 ; fi
    echo "DEBUG: set_proxy: Processing http-proxy-pem-uri='${METADATA_HTTP_PROXY_PEM_URI}'"
    local trusted_pem_dir
    if is_debuntu ; then
      trusted_pem_dir="/usr/local/share/ca-certificates"
      proxy_ca_pem="${trusted_pem_dir}/proxy_ca.crt"
      mkdir -p "${trusted_pem_dir}"
      gsutil cp "${METADATA_HTTP_PROXY_PEM_URI}" "${proxy_ca_pem}" || { echo "ERROR: Failed to download proxy CA cert from GCS." ; exit 1 ; }
      update-ca-certificates
      trusted_pem_path="/etc/ssl/certs/ca-certificates.crt"
    elif is_rocky ; then
      trusted_pem_dir="/etc/pki/ca-trust/source/anchors"
      proxy_ca_pem="${trusted_pem_dir}/proxy_ca.crt"
      mkdir -p "${trusted_pem_dir}"
      gsutil cp "${METADATA_HTTP_PROXY_PEM_URI}" "${proxy_ca_pem}" || { echo "ERROR: Failed to download proxy CA cert from GCS." ; exit 1 ; }
      update-ca-trust
      trusted_pem_path="/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
    fi
    export REQUESTS_CA_BUNDLE="${trusted_pem_path}"
    echo "DEBUG: set_proxy: trusted_pem_path set to '${trusted_pem_path}'"

    # Add to Java/Conda trust stores
    if [[ -f "/etc/environment" ]]; then
        JAVA_HOME="$(awk -F= '/^JAVA_HOME=/ {print $2}' /etc/environment)"
        if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/bin/keytool" ]]; then
            "${JAVA_HOME}/bin/keytool" -import -cacerts -storepass changeit -noprompt -alias swp_ca -file "${proxy_ca_pem}"
        fi
    fi
    if command -v conda &> /dev/null ; then
      local conda_cert_file="/opt/conda/default/ssl/cacert.pem"
      if [[ -f "${conda_cert_file}" ]]; then
        local ca_subject=$(openssl crl2pkcs7 -nocrl -certfile "${proxy_ca_pem}" | openssl pkcs7 -print_certs -noout | grep ^subject)
        openssl crl2pkcs7 -nocrl -certfile "${conda_cert_file}" | openssl pkcs7 -print_certs -noout | grep -Fxq "${ca_subject}" || {
          cat "${proxy_ca_pem}" >> "${conda_cert_file}"
        }
      fi
    fi
  fi

  if [[ -n "${http_proxy_val}" ]]; then

    local proxy_host=$(echo "${http_proxy_val}" | cut -d: -f1)
    local proxy_port=$(echo "${http_proxy_val}" | cut -d: -f2)

    echo "DEBUG: set_proxy: Testing TCP connection to proxy ${proxy_host}:${proxy_port}..."
    if ! nc -zv -w 5 "${proxy_host}" "${proxy_port}"; then
      echo "ERROR: Failed to establish TCP connection to proxy ${proxy_host}:${proxy_port}."
      exit 1
    fi

    echo "DEBUG: set_proxy: Testing external site access via proxy..."
    local test_url="https://www.google.com"
    local curl_test_args=()
    if [[ -n "${trusted_pem_path}" ]]; then
      curl_test_args+=(--cacert "${trusted_pem_path}")
    fi
    if curl "${curl_test_args[@]}" -vL --retry 3 --retry-delay 5 -o /dev/null "${test_url}"; then
      echo "DEBUG: set_proxy: Successfully fetched ${test_url} via proxy."
    else
      echo "ERROR: Failed to fetch ${test_url} via proxy ${HTTP_PROXY}."
      exit 1
    fi
  fi

  # Configure package managers
  local pkg_proxy_conf_file
  local effective_proxy="${http_proxy_val:-${https_proxy_val}}"
  if [[ -z "${effective_proxy}" ]]; then
      echo "DEBUG: set_proxy: No HTTP or HTTPS proxy set for package managers."
  elif is_debuntu ; then
    pkg_proxy_conf_file="/etc/apt/apt.conf.d/99proxy"
    echo "Acquire::http::Proxy \"http://${effective_proxy}\";" > "${pkg_proxy_conf_file}"
    echo "Acquire::https::Proxy \"http://${effective_proxy}\";" >> "${pkg_proxy_conf_file}"
  elif is_rocky ; then
    pkg_proxy_conf_file="/etc/dnf/dnf.conf"
    touch "${pkg_proxy_conf_file}"
    sed -i.bak '/^proxy=/d' "${pkg_proxy_conf_file}"
    if grep -q "^\[main\]" "${pkg_proxy_conf_file}"; then
      sed -i.bak "/^\\\[main\\\\]/a proxy=http://${effective_proxy}" "${pkg_proxy_conf_file}"
    else
      echo -e "[main]\nproxy=http://${effective_proxy}" >> "${pkg_proxy_conf_file}"
    fi
  fi

  # Configure dirmngr
  if is_debuntu ; then
    if ! dpkg -l | grep -q dirmngr; then
      execute_with_retries apt-get install -y -qq dirmngr
    fi
  elif is_rocky ; then
    if ! rpm -q gnupg2-smime; then
      execute_with_retries dnf install -y -q gnupg2-smime
    fi
  fi
  mkdir -p /etc/gnupg
  local dirmngr_conf="/etc/gnupg/dirmngr.conf"
  touch "${dirmngr_conf}"
  sed -i.bak '/^http-proxy/d' "${dirmngr_conf}"
  if [[ -n "${HTTP_PROXY:-}" ]]; then
    echo "http-proxy ${HTTP_PROXY}" >> "${dirmngr_conf}"
  fi
}

function configure_systemd_proxy() {
  local -r systemd_conf_dir="/etc/systemd/system.conf.d"
  local -r systemd_conf_file="${systemd_conf_dir}/10-default-env.conf"

  if [[ -n "${HTTP_PROXY:-}" || -n "${HTTPS_PROXY:-}" || -n "${http_proxy:-}" || -n "${https_proxy:-}" ]]; then
    if [[ "$(get_cached_state 'system/systemd_is_pid1')" != "true" ]]; then
      echo "ERROR: configure_systemd_proxy: systemd is not running as PID 1. This environment is unsupported." >&2
      exit 1
    fi

    echo "DEBUG: configure_systemd_proxy: Injecting proxy overrides into systemd manager..." >&2
    mkdir -p "${systemd_conf_dir}"

    local env_strings=()
    if [[ -n "${http_proxy:-}" ]];  then env_strings+=( "http_proxy=${http_proxy}" ); fi
    if [[ -n "${HTTP_PROXY:-}" ]];  then env_strings+=( "HTTP_PROXY=${HTTP_PROXY}" ); fi
    if [[ -n "${https_proxy:-}" ]]; then env_strings+=( "https_proxy=${https_proxy}" ); fi
    if [[ -n "${HTTPS_PROXY:-}" ]]; then env_strings+=( "HTTPS_PROXY=${HTTPS_PROXY}" ); fi
    if [[ -n "${no_proxy:-}" ]];    then env_strings+=( "no_proxy=${no_proxy}" ); fi
    if [[ -n "${NO_PROXY:-}" ]];    then env_strings+=( "NO_PROXY=${NO_PROXY}" ); fi

    # Format as systemd DefaultEnvironment space-separated list
    local default_env
    default_env=$(printf '"%s" ' "${env_strings[@]}")
    default_env=${default_env% }

    cat <<EOF > "${systemd_conf_file}"
[Manager]
DefaultEnvironment=${default_env}
EOF

    echo "DEBUG: configure_systemd_proxy: Executing systemd daemon-reexec..." >&2
    # NOTE: daemon-reexec is a heavy operation but required to make systemd
    # propagate the new DefaultEnvironment to subsequent services (like dataproc agent).
    systemctl daemon-reexec || true
  fi
}

function repair_boto() {
  local boto_file="/etc/boto.cfg"
  if [[ -f "${boto_file}" ]]; then
    echo "DEBUG: repair_boto: Repairing and deduplicating ${boto_file}" >&2

    # 1. Deduplicate sections (fix for DuplicateSectionError)
    # Use a more robust perl one-liner that also handles the content within duplicate sections
    # by only keeping the first occurrence of each section and its variables.
    perl -i -ne '
      if (/^\[(.*)\]/) {
        $section = $1;
        $skip = $seen{$section}++;
      }
      print unless $skip;
    ' "${boto_file}"

    # 2. Fix universe_domain if it is still a variable
    local universe_domain
    universe_domain=$(get_metadata_attribute 'universe-domain' 'googleapis.com')
    # Use a more robust replacement that handles potential escaping issues
    UNIVERSE_DOMAIN="${universe_domain}" perl -i -pe 's/\$\{universe_domain\}/$ENV{UNIVERSE_DOMAIN}/g' "${boto_file}"
    # Also fix cases where it might have been partially expanded to storage.$
    UNIVERSE_DOMAIN="${universe_domain}" perl -i -pe 's/storage\.\$/storage.$ENV{UNIVERSE_DOMAIN}/g' "${boto_file}"

    # 3. Apply proxy if set
    local meta_http_proxy=$(get_metadata_attribute 'http-proxy' '')
    local meta_proxy_uri=$(get_metadata_attribute 'proxy-uri' '')
    local effective_proxy="${meta_http_proxy:-${meta_proxy_uri}}"

    if [[ -n "${effective_proxy}" ]]; then
      local proxy_host="${effective_proxy%:*}"
      local proxy_port="${effective_proxy##*:}"

      sed -i -e '/^[[:space:]]*proxy[[:space:]]*=/d' -e '/^[[:space:]]*proxy_port[[:space:]]*=/d' "${boto_file}"
      if grep -q "^\[Boto\]" "${boto_file}"; then
        sed -i "/^\[Boto\]/a proxy = ${proxy_host}\nproxy_port = ${proxy_port}" "${boto_file}"
      else
        echo -e "\n[Boto]\nproxy = ${proxy_host}\nproxy_port = ${proxy_port}" >> "${boto_file}"
      fi
    fi
    echo "DEBUG: repair_boto: Updated ${boto_file}" >&2
  fi
}

function setup_deferred_service() {
  local -r service_name="dataproc-proxy-init"
  local -r service_file="/etc/systemd/system/${service_name}.service"
  local -r target_path="/usr/local/sbin/gce-proxy-setup.sh"
  local current_script_path
  current_script_path=$(readlink -f "$0")

  echo "INFO: setup_deferred_service: Registering gce-proxy-setup.sh for deferred execution on boot..." >&2

  # 1. Copy itself to the target path if not already there
  if [[ "${current_script_path}" != "${target_path}" ]]; then
    echo "INFO: setup_deferred_service: Copying script from ${current_script_path} to ${target_path}" >&2
    mkdir -p "$(dirname "${target_path}")"
    cp "${current_script_path}" "${target_path}"
    chmod +x "${target_path}"
  fi

  # 2. Write the systemd unit file (runs BEFORE google-dataproc-agent)
  echo "INFO: setup_deferred_service: Writing systemd service file ${service_file}" >&2
  cat <<EOF > "${service_file}"
[Unit]
Description=Inject Dynamic Dataproc Proxy Overrides into Systemd Manager
DefaultDependencies=no
After=systemd-udevd.service local-fs.target network-online.target
Wants=network-online.target
Before=google-dataproc-agent.service
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=${target_path}
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${service_file}"

  # 3. Enable the service so it runs on every boot
  if ! command -v systemctl >/dev/null 2>&1 || [[ "$(get_cached_state 'system/systemd_is_pid1')" != "true" ]]; then
    echo "ERROR: setup_deferred_service: systemd is not running as PID 1. Cannot enable deferred service." >&2
    exit 1
  fi

  echo "INFO: setup_deferred_service: Enabling systemd service ${service_name}" >&2
  systemctl enable "${service_name}.service"
  echo "INFO: setup_deferred_service: Deferred proxy service enabled successfully." >&2
}

function print_introspection_report() {
  local -r BLUE='\033[0;34m'
  local -r YELLOW='\033[1;33m'
  local -r NC='\033[0m'

  echo -e "${BLUE}--- INTROSPECTION REPORT (Actual State) ---${NC}" >&2
  echo -e "  OS ID                     : ${YELLOW}$(os_id)${NC}" >&2
  echo -e "  systemd is PID 1          : ${YELLOW}$(get_cached_state 'system/systemd_is_pid1' 'false')${NC}" >&2
  echo -e "  Proxy Service Installed   : ${YELLOW}$(get_cached_state 'system/proxy_service_provisioned' 'false')${NC}" >&2
  echo -e "  Proxy in /etc/environment : ${YELLOW}$(get_cached_state 'system/proxy_vars_in_env' 'false')${NC}" >&2
  echo -e "  Proxy in systemd manager  : ${YELLOW}$(get_cached_state 'system/proxy_vars_in_systemd' 'false')${NC}" >&2
  echo -e "${BLUE}-------------------------------------------${NC}" >&2
}

# --- Execution ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Define ANSI colors for structured phase logging
  BLUE='\033[0;34m'
  GREEN='\033[0;32m'
  NC='\033[0m'

  echo -e "${BLUE}[PHASE 1/3] INTROSPECTION: Auditing VM and GCE Metadata...${NC}" >&2
  initialize_guest_state
  trap 'rm -rf /dev/shm/metadata_cache' EXIT INT TERM
  print_introspection_report

  echo -e "${BLUE}[PHASE 2/3] PLANNING: Resolving proxy configurations...${NC}" >&2
  set_proxy

  echo -e "${BLUE}[PHASE 3/3] MUTATION: Applying system modifications...${NC}" >&2
  configure_systemd_proxy
  repair_boto

  if [[ "${IS_CUSTOM_IMAGE_BUILD:-}" == "true" || -n "$(get_metadata_attribute 'custom-sources-path' '')" ]]; then
    setup_deferred_service
  fi
  echo -e "${GREEN}SUCCESS: gce-proxy-setup.sh execution complete.${NC}" >&2
fi
