#!/bin/bash

set -e

DATAPROC_IMAGE_VERSION="${1:-2.3-debian12}"

# Source environment variables and utilities
if [[ -f examples/secure-boot/lib/env.sh ]]; then
  source examples/secure-boot/lib/env.sh
else
  echo "ERROR: examples/secure-boot/lib/env.sh not found."
  exit 1
fi
if [[ -f examples/secure-boot/lib/util.sh ]]; then
  source examples/secure-boot/lib/util.sh
else
  echo "ERROR: examples/secure-boot/lib/util.sh not found."
  exit 1
fi

# Check if env.json exists
if [[ ! -f env.json ]]; then
  echo "ERROR: env.json not found."
  echo "Please create an env.json file from examples/secure-boot/env.json.sample"
  exit 1
fi

# Validate essential variables
if [[ -z "${GSA}" || -z "${PROJECT_ID}" ]]; then
  echo "ERROR: GSA or PROJECT_ID is not set in examples/secure-boot/lib/env.sh."
  echo "Please check your env.json and examples/secure-boot/lib/env.sh configuration."
  exit 1
fi

function configure_service_account() {
  local phase_name="configure_service_account"
  # Note: Sentinels are not used on the host side in this script

  # Create service account
  print_status "Checking Service Account ${GSA}... "
  if run_gcloud "check_sa" gcloud iam service-accounts describe "${GSA}" --project="${PROJECT_ID}"; then
    report_result "Exists"
  else
    report_result "Not Found"
    print_status "Creating Service Account ${GSA}... "
    if run_gcloud "create_sa" gcloud iam service-accounts create "${SA_NAME}" \
      --description="Service account for pre-init customization" \
      --display-name="${SA_NAME}" --project="${PROJECT_ID}"; then
      report_result "Created"
    else
      report_result "Fail"
      exit 1
    fi
  fi

  print_status "Creating/Fetching key pair for secure boot... "
  eval "$(bash examples/secure-boot/create-key-pair.sh)"
  report_result "Done"

  print_status "Binding roles to ${GSA}... "
  run_gcloud "bind_dataproc_worker" gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/dataproc.worker" \
    --condition=None --project="${PROJECT_ID}"

  for storage_object_role in 'User' 'Creator' 'Viewer' ; do
    run_gcloud "bind_storage_${storage_object_role}" gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${GSA}" \
      --role="roles/storage.object${storage_object_role}" \
      --condition=None --project="${PROJECT_ID}"
  done

  for secret in "${public_secret_name}" "${private_secret_name}" ; do
    for sm_role in 'viewer' 'secretAccessor' ; do
      run_gcloud "bind_secret_${secret}_${sm_role}" gcloud secrets -q add-iam-policy-binding "${secret}" \
        --member="serviceAccount:${GSA}" \
        --role="roles/secretmanager.${sm_role}" \
        --condition=None --project="${PROJECT_ID}"
    done
  done

  run_gcloud "bind_compute_admin" gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/compute.instanceAdmin.v1 \
    --condition=None --project="${PROJECT_ID}"

  run_gcloud "bind_sa_user" gcloud iam service-accounts add-iam-policy-binding "${GSA}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/iam.serviceAccountUser \
    --condition=None --project="${PROJECT_ID}"
  report_result "Done"

  # Create or recreate the key file for the service account
  KEY_FILE="key.json"
  if [[ ! -f "${KEY_FILE}" ]]; then
    print_status "Generating key file ${KEY_FILE} for ${GSA}..."
    if gcloud iam service-accounts keys create "${KEY_FILE}" --iam-account="${GSA}" --project="${PROJECT_ID}"; then
      report_result "Success"
    else
      report_result "FAIL"
      echo "ERROR: Failed to create key file for ${GSA}."
      exit 1
    fi
  else
    print_status "Key file ${KEY_FILE} already exists."
    report_result "Skipped"
  fi
}

# === HOST SETUP START ===
print_status "Running HOST setup (Service Account, IAM, Keys)..."
# Ensure host gcloud is logged in to the correct user account
print_status "Setting gcloud account to ${PRINCIPAL} for host operations..."
gcloud config set --quiet account "${PRINCIPAL}"
gcloud config set --quiet project "${PROJECT_ID}"
report_result "Done"

configure_service_account
print_status "HOST setup complete."
# === HOST SETUP END ===

export timestamp=${timestamp:-$(date "+%Y%m%d-%H%M%S")}
echo "Log directory: ./tmp/logs/${timestamp}"
mkdir -p ./tmp/logs/${timestamp} ./tmp/tls/${timestamp}
echo "TLS directory: ./tmp/tls/${timestamp}"

image=custom-images-builder:latest

print_status "Building Podman image..."
time podman build -f Dockerfile -t ${image} .
report_result "Done"

print_status "Listing instances and images... "
run_gcloud "instance_list" gcloud compute instances list --zones "${ZONE}" --format json > ${tmpdir}/instances.json
run_gcloud "image_list" gcloud compute images    list                   --format json > ${tmpdir}/images.json
report_result "Done"

print_status "Running build in container..."
time podman run -it --rm \
  -v $(pwd)/${KEY_FILE}:/custom-images/key.json:ro \
  -v $(pwd)/tmp/logs/${timestamp}:/tmp \
  -v $(pwd)/tmp/tls/${timestamp}:/custom-images/tls \
  -e GOOGLE_APPLICATION_CREDENTIALS=/custom-images/key.json \
  -e GCE_METADATA_HOST=disabled \
  -e timestamp=${timestamp} \
  -e DEBUG=0 \
  -e REPRO_TMPDIR=/tmp \
  ${image} \
  bash -x examples/secure-boot/pre-init.sh "${DATAPROC_IMAGE_VERSION}"
#  bash examples/secure-boot/build-current-images.sh
function revoke_bindings() {
  print_status "Revoking roles from ${GSA}... "
  run_gcloud "revoke_dataproc_worker" gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role="roles/dataproc.worker" \
    --condition=None --project="${PROJECT_ID}"

  for storage_object_role in 'User' 'Creator' 'Viewer' ; do
    run_gcloud "revoke_storage_${storage_object_role}" gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${GSA}" \
      --role="roles/storage.object${storage_object_role}" \
      --condition=None --project="${PROJECT_ID}"
  done

  for secret in "${public_secret_name}" "${private_secret_name}" ; do
    for sm_role in 'viewer' 'secretAccessor' ; do
      run_gcloud "revoke_secret_${secret}_${sm_role}" gcloud secrets -q remove-iam-policy-binding "${secret}" \
        --member="serviceAccount:${GSA}" \
        --role="roles/secretmanager.${sm_role}" \
        --condition=None --project="${PROJECT_ID}"
    done
  done

  run_gcloud "revoke_compute_admin" gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/compute.instanceAdmin.v1 \
    --condition=None --project="${PROJECT_ID}"

  run_gcloud "revoke_sa_user" gcloud iam service-accounts remove-iam-policy-binding "${GSA}" \
    --member="serviceAccount:${GSA}" \
    --role=roles/iam.serviceAccountUser \
    --condition=None --project="${PROJECT_ID}"
  report_result "Done"

  print_status "Deleting service account key file key.json..."
  rm -f key.json
  report_result "Done"

  print_status "Deleting service account ${GSA}..."
  if run_gcloud "delete_sa" gcloud iam service-accounts delete "${GSA}" --project="${PROJECT_ID}" -q; then
    report_result "Success"
  else
    report_result "FAIL"
  fi
}

# To clean up, uncomment the following line:
# revoke_bindings
