# Copyright 2026 Google LLC and contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#            http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""API-based execution engine implementation using Google Cloud Python client libraries."""

import datetime
from dataclasses import dataclass
import logging
import os
import re
import sys
import time

import google.auth
from google.api_core.exceptions import (
    NotFound,
    GoogleAPIError,
    PermissionDenied,
    Conflict,
    DeadlineExceeded,
)
from google.api_core.retry import Retry
from google.cloud import compute_v1
from google.cloud import storage

from custom_image_utils.execution_engine import ExecutionEngine
from custom_image_utils.compute_operation_helper import ComputeOperationHelper


def _is_transient(e):
    from google.api_core.exceptions import BadRequest

    if isinstance(e, (NotFound, PermissionDenied, Conflict, BadRequest)):
        return False
    return isinstance(e, (GoogleAPIError, DeadlineExceeded))


_DEFAULT_RETRY = Retry(
    initial=1.0,
    maximum=10.0,
    multiplier=2.0,
    predicate=_is_transient,
)


def _parse_dataproc_version(version_str):
    """Parses dataproc version string like '2.1.115-debian11' or '2-1-115-debian11' to integer tuple (2, 1, 115) for sorting."""
    if not version_str:
        return 0, 0, 0
    # Normalize hyphens to dots to handle both formats
    normalized = version_str.replace("-", ".")
    parts = []
    for p in normalized.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            break
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


@dataclass
class BuildState:
    """State of the VM and disk provisioning/creation workflow."""

    disk_created: bool = False
    vm_created: bool = False
    build_succeeded: bool = False
    build_failed: bool = False


_LOG = logging.getLogger(__name__)
_LOG.setLevel(logging.INFO)

_IMAGE_PATH = "projects/{}/global/images/{}"
_IMAGE_URI = re.compile(
    r"^(https://www\.googleapis\.com/compute/([^/]+)/)?projects/([^/]+)/global/images/([^/]+)$"
)
_IMAGE_FAMILY_PATH = "projects/{}/global/images/family/{}"
_IMAGE_FAMILY_URI = re.compile(
    r"^(https://www\.googleapis\.com/compute/([^/]+)/)?projects/([^/]+)/global/images/family/([^/]+)$"
)


def _has_build_signal(contents: str, signal: str) -> bool:
    """Checks if contents has the build signal in a non-trace and non-quoted way."""
    target = f"startup-script: {signal}"
    for line in contents.splitlines():
        if target in line:
            if "+ " in line:
                continue
            if f'"{target}' in line or f"'{target}" in line or f'\\"{target}' in line:
                continue
            return True
    return False


class ApiExecutionEngine(ExecutionEngine):
    """Execution engine that uses Google Cloud Python client libraries."""

    def __init__(self, credentials=None):
        self.credentials = credentials
        self.compute_helper = ComputeOperationHelper(credentials=credentials)
        self.images_client = compute_v1.ImagesClient(credentials=credentials)
        self.disks_client = compute_v1.DisksClient(credentials=credentials)
        self.instances_client = compute_v1.InstancesClient(credentials=credentials)
        self.storage_client = storage.Client(credentials=credentials)

    def _get_default_project(self):
        """Gets default project ID from authenticated credentials."""
        if self.credentials and getattr(self.credentials, "project_id", None):
            return self.credentials.project_id
        _, project_id = google.auth.default()
        if not project_id:
            raise RuntimeError(
                "Cannot find default Google Cloud project ID. "
                "Please verify your credentials or set --project-id."
            )
        return project_id

    def infer_args(self, args):
        """Infers missing command-line arguments using GCP client APIs."""
        _LOG.info("Inferring arguments using API Engine...")

        # 1. Project ID
        if not args.project_id:
            args.project_id = self._get_default_project()

        # Validate and format Zone & Region (Point 12)
        if not args.zone:
            raise RuntimeError("Zone must be specified.")
        zone_pattern = re.compile(r"^[a-z0-9-]+-[a-z]$")
        if not zone_pattern.match(args.zone):
            raise RuntimeError(
                f"Invalid zone format: {args.zone}. Expected format like us-central1-a"
            )

        region_from_zone = "-".join(args.zone.split("-")[:-1])
        region_pattern = re.compile(r"^[a-z0-9-]+$")
        if not region_pattern.match(region_from_zone):
            raise RuntimeError(f"Extracted region is invalid: {region_from_zone}")

        # 2. Base Image
        if args.base_image_uri:
            m = _IMAGE_URI.match(args.base_image_uri)
            project, image_name = m.group(3), m.group(4)
            args.dataproc_base_image = _IMAGE_PATH.format(project, image_name)

            # Describe base image to get dataproc version label
            img = self.images_client.get(
                project=project, image=image_name, retry=_DEFAULT_RETRY
            )
            args.dataproc_version = (img.labels or {}).get("goog-dataproc-version", "")

        elif args.dataproc_version:
            # Find base image path by dataproc version
            parsed_version = args.dataproc_version.split(".")
            major_version = parsed_version[0]
            if len(parsed_version) == 2:
                # e.g., 1.5-debian10 -> query READY images and filter in Python
                minor_version = parsed_version[1].split("-")[0]
                version_filter = parsed_version[1].replace("-", r"-\d+-", 1)
                label_regex = re.compile(f"^{parsed_version[0]}-{version_filter}$")
                filter_expr = 'status = "READY"'
            else:
                major_version = parsed_version[0]
                minor_version = parsed_version[1]
                version_str = (
                    f"{parsed_version[0]}-{parsed_version[1]}-{parsed_version[2]}"
                )
                label_regex = None
                filter_expr = f'labels.goog-dataproc-version = "{version_str}" AND status = "READY"'

            # List matching Dataproc base images
            images = list(
                self.images_client.list(
                    request={"project": "cloud-dataproc", "filter": filter_expr},
                    retry=_DEFAULT_RETRY,
                )
            )

            # Sort by parsed version descending, then by creationTimestamp descending (Point 13)
            images.sort(
                key=lambda x: (
                    _parse_dataproc_version(x.labels.get("goog-dataproc-version", "")),
                    x.creation_timestamp or "",
                ),
                reverse=True,
            )

            expected_prefix = f"dataproc-{major_version}-{minor_version}"
            all_images_for_version = {}
            image_versions = []

            for img in images:
                # Local Python filtering to avoid fragile/non-standard API filters
                if "-eap" in img.name:
                    continue
                if not img.name.startswith(expected_prefix):
                    continue
                ver = img.labels.get("goog-dataproc-version")
                if not ver:
                    continue
                if label_regex and not label_regex.match(ver):
                    continue

                if ver not in all_images_for_version:
                    all_images_for_version[ver] = [
                        _IMAGE_PATH.format("cloud-dataproc", img.name)
                    ]
                    image_versions.append(ver)
                else:
                    all_images_for_version[ver].append(
                        _IMAGE_PATH.format("cloud-dataproc", img.name)
                    )

            if not image_versions:
                raise RuntimeError(
                    f"Cannot find dataproc base image with version {args.dataproc_version}"
                )

            latest_ver = image_versions[0]
            if len(all_images_for_version[latest_ver]) > 1:
                raise RuntimeError(
                    "Found more than one image for latest dataproc version."
                    f" Images: {all_images_for_version[latest_ver]}"
                )

            args.dataproc_base_image = all_images_for_version[latest_ver][0]
            args.dataproc_version = latest_ver

        elif args.base_image_family:
            m = _IMAGE_FAMILY_URI.match(args.base_image_family)
            project, family_name = m.group(3), m.group(4)
            args.dataproc_base_image = _IMAGE_FAMILY_PATH.format(project, family_name)

            # Describe latest image from the family
            img = self.images_client.get_from_family(
                project=project, family=family_name, retry=_DEFAULT_RETRY
            )
            args.dataproc_version = img.labels.get("goog-dataproc-version", "")
        else:
            raise RuntimeError(
                "Neither --dataproc-version nor --base-image-uri nor"
                " --base-image-family is specified."
            )

        # 3. OAuth config (None or formatted string)
        if args.oauth:
            args.oauth_path = os.path.abspath(args.oauth)
        else:
            args.oauth_path = None

        # 4. Network and subnetwork configuration (Point 3)
        if not args.network and not args.subnetwork:
            args.network = f"projects/{args.project_id}/global/networks/default"

        # Expand Network Uri
        if args.network and not args.network.startswith("projects/"):
            if args.network.startswith("global/networks/"):
                args.network = f"projects/{args.project_id}/{args.network}"
            elif "/" not in args.network:
                args.network = (
                    f"projects/{args.project_id}/global/networks/{args.network}"
                )

        # Expand Subnetwork Uri
        if args.subnetwork and not args.subnetwork.startswith("projects/"):
            if args.subnetwork.startswith("regions/"):
                args.subnetwork = f"projects/{args.project_id}/{args.subnetwork}"
            elif "/" not in args.subnetwork:
                args.subnetwork = f"projects/{args.project_id}/regions/{region_from_zone}/subnetworks/{args.subnetwork}"

        args.shutdown_timer_in_sec = args.shutdown_instance_timer_sec

        _LOG.info("Returned Dataproc base image: %s", args.dataproc_base_image)
        _LOG.info("Returned Dataproc version   : %s", args.dataproc_version)
        print(f"Returned Dataproc base image: {args.dataproc_base_image}")
        print(f"Returned Dataproc version   : {args.dataproc_version}")

    def perform_sanity_checks(self, args):
        """Checks if the target image already exists using API Client."""
        _LOG.info("Performing sanity checks using API Client...")
        try:
            self.images_client.get(
                project=args.project_id, image=args.image_name, retry=_DEFAULT_RETRY
            )
            raise RuntimeError(f"Image {args.image_name} already exists.")
        except NotFound:
            # Image does not exist, which is expected.
            pass
        except GoogleAPIError as e:
            raise RuntimeError(f"Error describing image {args.image_name}: {e}")

        _LOG.info("Passed sanity checks...")

    def create_image(self, args):
        """Executes the custom image creation workflow using API Clients."""
        if args.dry_run:
            _LOG.info("Dry-run mode: Skipping image creation.")
            return

        # Initialize runtime identifiers
        if "run_id" not in vars(args):
            args.run_id = "custom-image-{image_name}-{timestamp}".format(
                image_name=args.image_name,
                timestamp=datetime.datetime.now().strftime("%Y%m%d-%H%M%S"),
            )
        gcs_bucket_clean = args.gcs_bucket.replace("gs://", "").strip("/")
        if "/" in gcs_bucket_clean:
            args.bucket_name, prefix_path = gcs_bucket_clean.split("/", 1)
            prefix_path = prefix_path.strip("/")
            args.gcs_base_path = f"{prefix_path}/{args.run_id}"
        else:
            args.bucket_name = gcs_bucket_clean
            args.gcs_base_path = args.run_id

        args.custom_sources_path = (
            f"gs://{args.bucket_name}/{args.gcs_base_path}/sources"
        )
        args.log_dir = f"/tmp/{args.run_id}/logs"
        args.gcs_log_dir = f"gs://{args.bucket_name}/{args.gcs_base_path}/logs"

        os.makedirs(args.log_dir, exist_ok=True)
        local_log_file = os.path.join(args.log_dir, "startup-script.log")

        # Upload customizing sources to GCS
        _LOG.info("Uploading files to GCS bucket...")
        all_sources = {
            "run.sh": "startup_script/run.sh",
            "gce-proxy-setup.sh": "startup_script/gce-proxy-setup.sh",
        }
        # Upload any non-GCS extra sources
        for target_name, path in args.extra_sources.items():
            if not path.startswith("gs://"):
                all_sources[target_name] = path

        bucket = self.storage_client.bucket(args.bucket_name)
        for target_name, local_path in all_sources.items():
            blob_path = f"{args.gcs_base_path}/sources/{target_name}"
            blob = bucket.blob(blob_path)
            blob.upload_from_filename(local_path, retry=_DEFAULT_RETRY)
            _LOG.info("Uploaded %s to %s", local_path, blob_path)

            # Post-upload verification check (Point 9)
            if not blob.exists(retry=_DEFAULT_RETRY):
                raise RuntimeError(
                    f"Failed to verify upload of {local_path} to GCS (blob does not exist)."
                )

        # Handle customization script (local vs. gs://) (Point 10)
        init_actions_blob_path = f"{args.gcs_base_path}/sources/init_actions.sh"
        if args.customization_script.startswith("gs://"):
            # Cloud-to-Cloud copy! No local download needed.
            _LOG.info(
                "Copying remote GCS customization script: %s", args.customization_script
            )
            src_bucket_name, src_blob_name = args.customization_script.replace(
                "gs://", ""
            ).split("/", 1)
            src_bucket = self.storage_client.bucket(src_bucket_name)
            src_blob = src_bucket.blob(src_blob_name)
            try:
                src_bucket.copy_blob(
                    src_blob, bucket, init_actions_blob_path, retry=_DEFAULT_RETRY
                )
            except (
                GoogleAPIError,
                NotFound,
                PermissionDenied,
                Conflict,
                DeadlineExceeded,
            ) as e:
                raise RuntimeError(
                    f"Error copying customization script {args.customization_script} to {init_actions_blob_path}: {e}. "
                    "Please ensure your service account has storage.objects.get permission on the source bucket "
                    "and storage.objects.create permission on the target bucket."
                ) from e
            _LOG.info(
                "Copied remote GCS customization script to %s", init_actions_blob_path
            )

            # Verify GCS copy succeeded
            dest_blob = bucket.blob(init_actions_blob_path)
            if not dest_blob.exists(retry=_DEFAULT_RETRY):
                raise RuntimeError(
                    f"Failed to verify GCS copy of customization script to {init_actions_blob_path}."
                )
        else:
            # Upload local file
            blob = bucket.blob(init_actions_blob_path)
            blob.upload_from_filename(args.customization_script, retry=_DEFAULT_RETRY)
            _LOG.info(
                "Uploaded local customization script %s to %s",
                args.customization_script,
                init_actions_blob_path,
            )

            # Verify local upload succeeded
            if not blob.exists(retry=_DEFAULT_RETRY):
                raise RuntimeError(
                    f"Failed to verify upload of customization script {args.customization_script} to GCS."
                )

        # Handle GCS extra sources if any
        for target_name, path in args.extra_sources.items():
            if path.startswith("gs://"):
                _LOG.info("Copying remote GCS extra source: %s", path)
                src_bucket_name, src_blob_name = path.replace("gs://", "").split("/", 1)
                src_bucket = self.storage_client.bucket(src_bucket_name)
                src_blob = src_bucket.blob(src_blob_name)
                try:
                    src_bucket.copy_blob(
                        src_blob,
                        bucket,
                        f"{args.gcs_base_path}/sources/{target_name}",
                        retry=_DEFAULT_RETRY,
                    )
                except (
                    GoogleAPIError,
                    NotFound,
                    PermissionDenied,
                    Conflict,
                    DeadlineExceeded,
                ) as e:
                    raise RuntimeError(
                        f"Error copying GCS extra source {path} to sources/{target_name}: {e}. "
                        "Please ensure your service account has storage.objects.get permission on the source bucket "
                        "and storage.objects.create permission on the target bucket."
                    ) from e
                _LOG.info(
                    "Copied remote GCS extra source %s to sources/%s", path, target_name
                )

                # Verify copy succeeded
                extra_blob = bucket.blob(f"{args.gcs_base_path}/sources/{target_name}")
                if not extra_blob.exists(retry=_DEFAULT_RETRY):
                    raise RuntimeError(
                        f"Failed to verify GCS copy of extra source {path} to GCS."
                    )

        # Resolve zone and region
        region = "-".join(args.zone.split("-")[:-1])

        # Generate unique intermediate disk and VM instance names using SHA-256 hash of run_id
        import hashlib

        unique_suffix = hashlib.sha256(args.run_id.encode("utf-8")).hexdigest()[:6]
        max_prefix_len = 63 - len(f"-install-{unique_suffix}")
        prefix = args.image_name[:max_prefix_len].rstrip("-")
        disk_name = f"{prefix}-install-{unique_suffix}"
        instance_name = f"{prefix}-install-{unique_suffix}"

        state = BuildState()

        try:
            # Create Compute Disk from base image
            self._create_disk(args, disk_name)
            state.disk_created = True

            # Create VM Instance
            self._create_vm(args, instance_name, disk_name, region)
            state.vm_created = True

            # Monitor Serial Logs
            self._monitor_build(args, instance_name, local_log_file, state)

            # Check outcome status
            if not state.build_succeeded:
                raise RuntimeError(
                    "Custom image build failed. See logs at {} or GCS {}.".format(
                        local_log_file, args.gcs_log_dir
                    )
                )

            # Ensure the VM is fully stopped before creating the image from its disk
            inst = self.instances_client.get(
                project=args.project_id,
                zone=args.zone,
                instance=instance_name,
                retry=_DEFAULT_RETRY,
            )
            if inst.status not in ("TERMINATED", "STOPPED"):
                _LOG.info(
                    "Stopping VM instance %s to release disk for imaging...",
                    instance_name,
                )
                op = self.instances_client.stop(
                    project=args.project_id,
                    zone=args.zone,
                    instance=instance_name,
                    retry=_DEFAULT_RETRY,
                )
                self.compute_helper.wait_for_zone_operation(
                    args.project_id, args.zone, op.name
                )

            # Create Final custom image from the disk
            self._create_final_image(args, disk_name)

            # Shutdown and delete the VM instance
            _LOG.info("Deleting VM instance %s...", instance_name)
            op = self.instances_client.delete(
                project=args.project_id,
                zone=args.zone,
                instance=instance_name,
                retry=_DEFAULT_RETRY,
            )
            self.compute_helper.wait_for_zone_operation(
                args.project_id, args.zone, op.name
            )
            state.vm_created = False

        finally:
            self._cleanup(args, instance_name, disk_name, state)
            self._upload_logs(args, bucket)

    def _create_disk(self, args, disk_name):
        """Creates boot disk from Dataproc base image."""
        _LOG.info(
            "Creating boot disk %s from base image %s...",
            disk_name,
            args.dataproc_base_image,
        )
        disk_body = compute_v1.Disk(
            name=disk_name,
            source_image=args.dataproc_base_image,
            type_=f"zones/{args.zone}/diskTypes/pd-ssd",
            size_gb=args.disk_size,
        )
        try:
            op = self.disks_client.insert(
                project=args.project_id,
                zone=args.zone,
                disk_resource=disk_body,
                retry=_DEFAULT_RETRY,
            )
            self.compute_helper.wait_for_zone_operation(
                args.project_id, args.zone, op.name
            )
        except Conflict as e:
            raise RuntimeError(
                f"Boot disk '{disk_name}' already exists in project '{args.project_id}' and zone '{args.zone}'. "
                "A previous build may have failed or was interrupted. "
                f"Please delete the existing disk (e.g. gcloud compute disks delete {disk_name} --zone={args.zone}) "
                "or specify a different --image-name."
            ) from e
        except (
            GoogleAPIError,
            NotFound,
            PermissionDenied,
            DeadlineExceeded,
        ) as e:
            raise RuntimeError(f"Error creating boot disk {disk_name}: {e}")

    def _create_vm(self, args, instance_name, disk_name, region):
        """Creates the VM instance that runs customization scripts."""
        _LOG.info(
            "Creating VM instance %s to run customization script...", instance_name
        )

        # Build metadata items
        metadata_items = [
            compute_v1.Items(
                key="shutdown-timer-in-sec", value=str(args.shutdown_timer_in_sec)
            ),
            compute_v1.Items(key="custom-sources-path", value=args.custom_sources_path),
            compute_v1.Items(key="universe-domain", value=args.universe_domain),
            compute_v1.Items(key="dataproc-region", value=region),
        ]
        if args.dataproc_version:
            metadata_items.append(
                compute_v1.Items(
                    key="dataproc_dataproc_version", value=args.dataproc_version
                )
            )
        # Process user customization metadata (Point 4)
        if args.metadata:
            # Match key=value where value can be double-quoted or unquoted
            for match in re.finditer(
                r'([^=,\s]+)=(?:"([^"]*)"|([^,]+))', args.metadata
            ):
                k = match.group(1)
                v = match.group(2) if match.group(2) is not None else match.group(3)
                metadata_items.append(compute_v1.Items(key=k, value=v))

        # Use startup-script-url pointing to GCS to avoid ~256KB metadata limits (Point 11)
        startup_script_url = (
            f"gs://{args.bucket_name}/{args.gcs_base_path}/sources/run.sh"
        )
        metadata_items.append(
            compute_v1.Items(key="startup-script-url", value=startup_script_url)
        )

        # Build network interface
        network_interface = compute_v1.NetworkInterface()
        if args.subnetwork:
            network_interface.subnetwork = args.subnetwork
        else:
            network_interface.network = args.network
        if not args.no_external_ip:
            # Add access config to assign external IP address
            network_interface.access_configs = [
                compute_v1.AccessConfig(
                    name="External NAT",
                    type_="ONE_TO_ONE_NAT",
                )
            ]

        # Build Boot Disk attachment
        boot_disk = compute_v1.AttachedDisk(
            auto_delete=True,
            boot=True,
            mode="READ_WRITE",
            source=f"projects/{args.project_id}/zones/{args.zone}/disks/{disk_name}",
        )

        # Build instance specs
        instance_resource = compute_v1.Instance(
            name=instance_name,
            machine_type=f"zones/{args.zone}/machineTypes/{args.machine_type}",
            disks=[boot_disk],
            network_interfaces=[network_interface],
            metadata=compute_v1.Metadata(items=metadata_items),
            service_accounts=[
                compute_v1.ServiceAccount(
                    email=args.service_account,
                    scopes=["https://www.googleapis.com/auth/cloud-platform"],
                )
            ],
        )

        # Add Accelerator configurations
        if args.accelerator:
            # type=nvidia-tesla-v100,count=2
            acc_type = "nvidia-tesla-v100"
            acc_count = 1
            for item in args.accelerator.split(","):
                if "=" in item:
                    k, v = item.split("=", 1)
                    if k == "type":
                        acc_type = v
                    elif k == "count":
                        try:
                            acc_count = int(v)
                        except ValueError:
                            raise RuntimeError(
                                f"Invalid accelerator count: {v}. Must be an integer."
                            )
            instance_resource.guest_accelerators = [
                compute_v1.AcceleratorConfig(
                    accelerator_type=f"zones/{args.zone}/acceleratorTypes/{acc_type}",
                    accelerator_count=acc_count,
                )
            ]
            # Required scheduling for GPU instances
            instance_resource.scheduling = compute_v1.Scheduling(
                on_host_maintenance="TERMINATE"
            )

        try:
            op = self.instances_client.insert(
                project=args.project_id,
                zone=args.zone,
                instance_resource=instance_resource,
                retry=_DEFAULT_RETRY,
            )
            self.compute_helper.wait_for_zone_operation(
                args.project_id, args.zone, op.name
            )
        except Conflict as e:
            raise RuntimeError(
                f"VM instance '{instance_name}' already exists in project '{args.project_id}' and zone '{args.zone}'. "
                "A previous build may have failed or was interrupted. "
                f"Please delete the existing instance (e.g. gcloud compute instances delete {instance_name} --zone={args.zone}) "
                "or specify a different --image-name."
            ) from e
        except (
            GoogleAPIError,
            NotFound,
            PermissionDenied,
            DeadlineExceeded,
        ) as e:
            raise RuntimeError(f"Error creating VM instance {instance_name}: {e}")

    def _monitor_build(self, args, instance_name, local_log_file, state):
        """Monitors the customization build progress by polling serial port output."""
        _LOG.info("Waiting for customization script to finish and VM shutdown...")
        time.sleep(15)  # Allow initial VM boot

        offset = 0
        start_time = time.time()
        timeout_secs = 7200
        if hasattr(args, "build_timeout_sec") and isinstance(
            args.build_timeout_sec, (int, float)
        ):
            timeout_secs = args.build_timeout_sec
        delay = 10

        with open(local_log_file, "w") as log_f:
            while time.time() - start_time < timeout_secs:
                try:
                    # Check VM instance state
                    inst = self.instances_client.get(
                        project=args.project_id,
                        zone=args.zone,
                        instance=instance_name,
                        retry=_DEFAULT_RETRY,
                    )
                    _LOG.info("VM Status: %s", inst.status)
                    is_stopped = inst.status in ("TERMINATED", "STOPPED")

                    # Retrieve serial port output
                    try:
                        res = self.instances_client.get_serial_port_output(
                            request={
                                "project": args.project_id,
                                "zone": args.zone,
                                "instance": instance_name,
                                "port": 1,
                                "start": offset,
                            },
                            retry=_DEFAULT_RETRY,
                        )
                        if res.contents:
                            log_f.write(res.contents)
                            log_f.flush()
                            sys.stdout.write(res.contents)
                            sys.stdout.flush()
                            offset = res.next_

                            # Reset backoff delay when new logs arrive (Point 7)
                            delay = 10

                            if _has_build_signal(res.contents, "BuildSucceeded:"):
                                state.build_succeeded = True
                                _LOG.info("Customization script succeeded.")
                            elif _has_build_signal(res.contents, "BuildFailed:"):
                                state.build_failed = True
                                _LOG.info("Customization script failed.")
                        else:
                            # Apply exponential backoff when no output is received
                            delay = min(delay * 2, 60)

                    except (
                        GoogleAPIError,
                        NotFound,
                        PermissionDenied,
                        Conflict,
                        DeadlineExceeded,
                    ) as e:
                        if is_stopped:
                            _LOG.info(
                                "VM is stopped and serial output is no longer available: %s",
                                e,
                            )
                        else:
                            raise

                    if is_stopped or state.build_succeeded or state.build_failed:
                        break

                    time.sleep(delay)
                except (
                    GoogleAPIError,
                    NotFound,
                    PermissionDenied,
                    Conflict,
                    DeadlineExceeded,
                ) as e:
                    _LOG.warning("Error reading serial output (will retry): %s", e)
                    time.sleep(delay)

        # Check outcome status in log file
        if not state.build_succeeded:
            with open(local_log_file, "r") as log_f:
                logs = log_f.read()
                if _has_build_signal(logs, "BuildSucceeded:"):
                    state.build_succeeded = True
                elif _has_build_signal(logs, "BuildFailed:"):
                    state.build_failed = True

    def _create_final_image(self, args, disk_name):
        """Creates the final custom image from GCE boot disk."""
        _LOG.info("Creating custom image %s from disk...", args.image_name)
        image_resource = compute_v1.Image(
            name=args.image_name,
            source_disk=f"projects/{args.project_id}/zones/{args.zone}/disks/{disk_name}",
            family=args.family,
        )
        if args.storage_location:
            image_resource.storage_locations = [args.storage_location]

        try:
            op = self.images_client.insert(
                project=args.project_id,
                image_resource=image_resource,
                retry=_DEFAULT_RETRY,
            )
            self.compute_helper.wait_for_global_operation(args.project_id, op.name)
            _LOG.info("Successfully created custom image %s.", args.image_name)
        except (
            GoogleAPIError,
            NotFound,
            PermissionDenied,
            Conflict,
            DeadlineExceeded,
        ) as e:
            raise RuntimeError(
                f"Error creating final custom image {args.image_name}: {e}"
            )

    def _cleanup(self, args, instance_name, disk_name, state):
        """Deletes provisioned VM and disk on completion or failure."""
        if state.vm_created:
            try:
                _LOG.info("Cleaning up VM instance %s...", instance_name)
                op = self.instances_client.delete(
                    project=args.project_id,
                    zone=args.zone,
                    instance=instance_name,
                    retry=_DEFAULT_RETRY,
                )
                self.compute_helper.wait_for_zone_operation(
                    args.project_id, args.zone, op.name
                )
            except Exception as e:
                _LOG.warning("Failed to delete VM instance %s: %s", instance_name, e)

        if state.disk_created and not state.vm_created:
            try:
                _LOG.info("Cleaning up boot disk %s...", disk_name)
                op = self.disks_client.delete(
                    project=args.project_id,
                    zone=args.zone,
                    disk=disk_name,
                    retry=_DEFAULT_RETRY,
                )
                self.compute_helper.wait_for_zone_operation(
                    args.project_id, args.zone, op.name
                )
            except NotFound:
                _LOG.info("Boot disk %s was already deleted (auto-delete).", disk_name)
            except Exception as e:
                _LOG.warning("Failed to delete boot disk %s: %s", disk_name, e)

    def _upload_logs(self, args, bucket):
        """Syncs local logs to GCS."""
        try:
            _LOG.info("Syncing local logs to GCS log folder...")
            for root, _, files in os.walk(args.log_dir):
                for name in files:
                    path = os.path.join(root, name)
                    rel = os.path.relpath(path, args.log_dir)
                    blob_path = f"{args.gcs_base_path}/logs/{rel}"
                    blob = bucket.blob(blob_path)
                    blob.upload_from_filename(path, retry=_DEFAULT_RETRY)
        except (
            GoogleAPIError,
            NotFound,
            PermissionDenied,
            Conflict,
            DeadlineExceeded,
        ) as e:
            _LOG.warning("Failed to upload build logs to GCS: %s", e)

    def add_label(self, args):
        """Sets Dataproc version label in the custom image."""
        if args.dry_run:
            _LOG.info("Dry-run mode: Skipping label attachment.")
            return

        _LOG.info("Setting label on custom image via API client...")
        version_label = args.dataproc_version.replace(".", "-").lower()

        # Retrieve current image to get resource fingerprint
        img = self.images_client.get(
            project=args.project_id, image=args.image_name, retry=_DEFAULT_RETRY
        )

        # Set labels
        labels_spec = compute_v1.GlobalSetLabelsRequest(
            label_fingerprint=img.label_fingerprint,
            labels={"goog-dataproc-version": version_label},
        )
        op = self.images_client.set_labels(
            project=args.project_id,
            resource=args.image_name,
            global_set_labels_request_resource=labels_spec,
            retry=_DEFAULT_RETRY,
        )
        self.compute_helper.wait_for_global_operation(args.project_id, op.name)
        _LOG.info("Successfully set label on custom image %s.", args.image_name)

    def notify_expiration(self, args):
        """Notifies when the image will expire using Images API client."""
        if args.dry_run:
            _LOG.info("Dry-run mode: Skipping expiration notification.")
            return

        _LOG.info("Successfully built Dataproc custom image: %s", args.image_name)
        img = self.images_client.get(
            project=args.project_id, image=args.image_name, retry=_DEFAULT_RETRY
        )
        timestamp_string = img.creation_timestamp

        # RFC3339 timestamp parsing
        creation_date = datetime.datetime.fromisoformat(
            timestamp_string.replace("Z", "+00:00")
        )
        expiration_date = creation_date + datetime.timedelta(days=365)

        notification_text = """
#####################################################################
  WARNING: DATAPROC CUSTOM IMAGE '{}'
           WILL EXPIRE ON {}.
#####################################################################
"""
        _LOG.warning(notification_text.format(args.image_name, str(expiration_date)))

    def run_smoke_test(self, args):
        """Runs a smoke test on the custom image."""
        from custom_image_utils import smoke_test_runner

        smoke_test_runner.run(args)
