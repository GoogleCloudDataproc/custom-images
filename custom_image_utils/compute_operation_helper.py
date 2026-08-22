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
"""Helper for waiting for Compute Engine long-running operations."""

import logging
import time
from google.cloud import compute_v1

_LOG = logging.getLogger(__name__)


class ComputeOperationHelper:
    """Helper to wait for Google Compute Engine long-running operations."""

    def __init__(self, credentials=None):
        self.zone_client = compute_v1.ZoneOperationsClient(credentials=credentials)
        self.global_client = compute_v1.GlobalOperationsClient(credentials=credentials)
        self.region_client = compute_v1.RegionOperationsClient(credentials=credentials)

    def wait_for_zone_operation(self, project, zone, operation_name, timeout_secs=600):
        """Waits for a zonal operation to complete."""
        _LOG.info("Waiting for zonal operation %s in zone %s...", operation_name, zone)
        start_time = time.time()
        while time.time() - start_time < timeout_secs:
            op = self.zone_client.get(
                project=project, zone=zone, operation=operation_name
            )
            if op.status == compute_v1.Operation.Status.DONE:
                if op.error:
                    raise RuntimeError("Zonal operation failed: {}".format(op.error))
                return op
            time.sleep(5)
        raise TimeoutError(
            "Zonal operation {} timed out after {}s".format(
                operation_name, timeout_secs
            )
        )

    def wait_for_global_operation(self, project, operation_name, timeout_secs=600):
        """Waits for a global operation to complete."""
        _LOG.info("Waiting for global operation %s...", operation_name)
        start_time = time.time()
        while time.time() - start_time < timeout_secs:
            op = self.global_client.get(project=project, operation=operation_name)
            if op.status == compute_v1.Operation.Status.DONE:
                if op.error:
                    raise RuntimeError("Global operation failed: {}".format(op.error))
                return op
            time.sleep(5)
        raise TimeoutError(
            "Global operation {} timed out after {}s".format(
                operation_name, timeout_secs
            )
        )

    def wait_for_region_operation(
        self, project, region, operation_name, timeout_secs=600
    ):
        """Waits for a regional operation to complete."""
        _LOG.info(
            "Waiting for regional operation %s in region %s...", operation_name, region
        )
        start_time = time.time()
        while time.time() - start_time < timeout_secs:
            op = self.region_client.get(
                project=project, region=region, operation=operation_name
            )
            if op.status == compute_v1.Operation.Status.DONE:
                if op.error:
                    raise RuntimeError("Regional operation failed: {}".format(op.error))
                return op
            time.sleep(5)
        raise TimeoutError(
            "Regional operation {} timed out after {}s".format(
                operation_name, timeout_secs
            )
        )
