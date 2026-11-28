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
"""Unit tests for api_execution_engine.py."""

import unittest
from unittest.mock import MagicMock, patch, mock_open

from custom_image_utils.api_execution_engine import ApiExecutionEngine


class TestApiExecutionEngine(unittest.TestCase):
    def setUp(self):
        self.auth_patch = patch(
            "google.auth.default", return_value=(None, "test-project")
        )
        self.auth_patch.start()
        self.addCleanup(self.auth_patch.stop)

        self.images_patch = patch("google.cloud.compute_v1.ImagesClient")
        self.images_patch.start()
        self.addCleanup(self.images_patch.stop)

        self.disks_patch = patch("google.cloud.compute_v1.DisksClient")
        self.disks_patch.start()
        self.addCleanup(self.disks_patch.stop)

        self.instances_patch = patch("google.cloud.compute_v1.InstancesClient")
        self.instances_patch.start()
        self.addCleanup(self.instances_patch.stop)

        self.storage_patch = patch("google.cloud.storage.Client")
        self.storage_patch.start()
        self.addCleanup(self.storage_patch.stop)

        self.engine = ApiExecutionEngine()
        self.engine.compute_helper = MagicMock()

    def test_get_default_project(self):
        with patch("google.auth.default", return_value=(None, "test-project")):
            project_id = self.engine._get_default_project()
            self.assertEqual(project_id, "test-project")

    def test_get_default_project_with_credentials(self):
        mock_creds = MagicMock()
        mock_creds.project_id = "credentials-project"
        self.engine.credentials = mock_creds
        try:
            project_id = self.engine._get_default_project()
            self.assertEqual(project_id, "credentials-project")
        finally:
            self.engine.credentials = None

    def test_get_default_project_missing(self):
        with patch("google.auth.default", return_value=(None, None)):
            with self.assertRaises(RuntimeError):
                self.engine._get_default_project()

    def test_infer_args_with_project_and_base_image(self):
        args = MagicMock()
        args.project_id = "test-project"
        args.base_image_uri = (
            "projects/cloud-dataproc/global/images/dataproc-2-1-deb11-20260611"
        )
        args.base_image_family = None
        args.dataproc_version = None
        args.oauth = None
        args.network = None
        args.subnetwork = None
        args.zone = "us-central1-a"
        args.shutdown_instance_timer_sec = 300

        mock_image = MagicMock()
        mock_image.labels = {"goog-dataproc-version": "2.1.115-debian11"}
        self.engine.images_client.get.return_value = mock_image

        self.engine.infer_args(args)

        self.assertEqual(
            args.dataproc_base_image,
            "projects/cloud-dataproc/global/images/dataproc-2-1-deb11-20260611",
        )
        self.assertEqual(args.dataproc_version, "2.1.115-debian11")
        self.assertEqual(args.network, "projects/test-project/global/networks/default")

    def test_perform_sanity_checks_not_found(self):
        from google.api_core.exceptions import NotFound

        args = MagicMock()
        args.project_id = "test-project"
        args.image_name = "test-image"
        args.zone = "us-central1-a"

        self.engine.images_client.get.side_effect = NotFound("Not Found")
        self.engine.disks_client.get.side_effect = NotFound("Not Found")
        self.engine.instances_client.get.side_effect = NotFound("Not Found")
        # Should not raise exception
        self.engine.perform_sanity_checks(args)

    def test_perform_sanity_checks_already_exists(self):
        args = MagicMock()
        args.project_id = "test-project"
        args.image_name = "test-image"
        args.zone = "us-central1-a"

        self.engine.images_client.get.return_value = MagicMock()
        with self.assertRaises(RuntimeError) as ctx:
            self.engine.perform_sanity_checks(args)
        self.assertIn("already exists", str(ctx.exception))

    @patch("builtins.open", new_callable=mock_open, read_data="echo test")
    @patch("os.makedirs")
    @patch("time.sleep")
    def test_create_image_dry_run(self, mock_sleep, mock_makedirs, mock_open):
        args = MagicMock()
        args.dry_run = True

        # Should exit early without making any API calls
        self.engine.create_image(args)
        self.engine.images_client.insert.assert_not_called()

    def test_create_disk_success(self):
        args = MagicMock()
        args.project_id = "test-project"
        args.zone = "us-central1-a"
        args.dataproc_base_image = "projects/cloud-dataproc/global/images/dataproc-2-1"
        args.disk_size = 50

        self.engine.disks_client.insert.return_value = MagicMock(name="op")
        self.engine._create_disk(args, "test-disk")
        self.engine.disks_client.insert.assert_called_once()

    def test_create_disk_failure(self):
        from google.api_core.exceptions import GoogleAPIError

        args = MagicMock()
        args.project_id = "test-project"
        args.zone = "us-central1-a"
        args.dataproc_base_image = "projects/cloud-dataproc/global/images/dataproc-2-1"
        args.disk_size = 50

        self.engine.disks_client.insert.side_effect = GoogleAPIError("GCP error")
        with self.assertRaises(RuntimeError) as ctx:
            self.engine._create_disk(args, "test-disk")
        self.assertIn("Error creating boot disk", str(ctx.exception))

    @patch("builtins.open", new_callable=mock_open, read_data="echo startup")
    def test_create_vm_success(self, mock_open):
        args = MagicMock()
        args.project_id = "test-project"
        args.zone = "us-central1-a"
        args.machine_type = "n1-standard-4"
        args.service_account = "test-sa@project.iam.gserviceaccount.com"
        args.subnetwork = None
        args.network = "global/networks/default"
        args.no_external_ip = False
        args.accelerator = None
        args.metadata = "key1=value1"
        args.universe_domain = "googleapis.com"
        args.dataproc_version = "2.1.115"
        args.custom_sources_path = "gs://test-bucket/sources"
        args.shutdown_timer_in_sec = 300

        self.engine.instances_client.insert.return_value = MagicMock(name="op")
        self.engine._create_vm(args, "test-instance", "test-disk", "us-central1")
        self.engine.instances_client.insert.assert_called_once()

    @patch("builtins.open", new_callable=mock_open, read_data="BuildSucceeded:")
    @patch("time.sleep")
    def test_monitor_build_success(self, mock_sleep, mock_open_file):
        from custom_image_utils.api_execution_engine import BuildState

        args = MagicMock()
        args.project_id = "test-project"
        args.zone = "us-central1-a"
        state = BuildState()

        mock_instance = MagicMock()
        mock_instance.status = "RUNNING"
        self.engine.instances_client.get.return_value = mock_instance

        mock_serial = MagicMock()
        mock_serial.contents = "startup-script: BuildSucceeded:\n"
        mock_serial.next_ = 100
        self.engine.instances_client.get_serial_port_output.return_value = mock_serial

        self.engine._monitor_build(args, "test-instance", "local-log.log", state)
        self.assertTrue(state.build_succeeded)

    def test_create_final_image_success(self):
        args = MagicMock()
        args.project_id = "test-project"
        args.image_name = "test-image"
        args.family = "test-family"
        args.storage_location = "us"

        self.engine.images_client.insert.return_value = MagicMock(name="op")
        self.engine._create_final_image(args, "test-disk")
        self.engine.images_client.insert.assert_called_once()

    def test_cleanup_vm_and_disk(self):
        from custom_image_utils.api_execution_engine import BuildState

        args = MagicMock()
        args.project_id = "test-project"
        args.zone = "us-central1-a"

        # Scenario 1: Both created -> Only VM delete is called (disk is auto-deleted with VM)
        state = BuildState(disk_created=True, vm_created=True)
        self.engine._cleanup(args, "test-instance", "test-disk", state)
        self.engine.instances_client.delete.assert_called_once()
        self.engine.disks_client.delete.assert_not_called()

        # Scenario 2: Only disk created -> Only disk delete is called
        self.engine.instances_client.delete.reset_mock()
        self.engine.disks_client.delete.reset_mock()
        state2 = BuildState(disk_created=True, vm_created=False)
        self.engine._cleanup(args, "test-instance", "test-disk", state2)
        self.engine.instances_client.delete.assert_not_called()
        self.engine.disks_client.delete.assert_called_once()

    def test_csv_metadata_parsing(self):
        args = MagicMock()
        args.project_id = "test-project"
        args.zone = "us-central1-a"
        args.machine_type = "n1-standard-4"
        args.service_account = "test-sa@project.iam.gserviceaccount.com"
        args.subnetwork = None
        args.network = "global/networks/default"
        args.no_external_ip = False
        args.accelerator = None
        args.metadata = 'key1="val1,val2",key2=val3'
        args.universe_domain = "googleapis.com"
        args.dataproc_version = "2.1.115"
        args.custom_sources_path = "gs://test-bucket/sources"
        args.shutdown_timer_in_sec = 300
        args.bucket_name = "test-bucket"
        args.gcs_base_path = "run-id"

        self.engine.instances_client.insert.return_value = MagicMock(name="op")

        with patch("builtins.open", mock_open(read_data="echo test")):
            self.engine._create_vm(args, "test-instance", "test-disk", "us-central1")

        call_args = self.engine.instances_client.insert.call_args
        instance_resource = call_args.kwargs["instance_resource"]
        metadata_items = instance_resource.metadata.items

        metadata_dict = {item.key: item.value for item in metadata_items}
        self.assertEqual(metadata_dict.get("key1"), "val1,val2")
        self.assertEqual(metadata_dict.get("key2"), "val3")

    def test_dataproc_version_parsing_and_sorting(self):
        from custom_image_utils.api_execution_engine import _parse_dataproc_version

        v1 = _parse_dataproc_version("2.1.115-debian11")
        v2 = _parse_dataproc_version("2.0.50-debian10")
        v3 = _parse_dataproc_version("2.1.99-debian11")
        v4 = _parse_dataproc_version("2-1-115-debian11")

        self.assertEqual(v1, (2, 1, 115))
        self.assertEqual(v2, (2, 0, 50))
        self.assertEqual(v3, (2, 1, 99))
        self.assertEqual(v4, (2, 1, 115))
        self.assertTrue(v1 > v3)
        self.assertTrue(v3 > v2)

    @patch("custom_image_utils.smoke_test_runner.run")
    def test_run_smoke_test(self, mock_smoke_run):
        args = MagicMock()
        self.engine.run_smoke_test(args)
        mock_smoke_run.assert_called_once_with(args)

    def test_invalid_accelerator_count(self):
        args = MagicMock()
        args.project_id = "test-project"
        args.zone = "us-central1-a"
        args.machine_type = "n1-standard-4"
        args.service_account = "test-sa@project.iam.gserviceaccount.com"
        args.subnetwork = None
        args.network = "global/networks/default"
        args.no_external_ip = False
        args.accelerator = "type=nvidia-tesla-v100,count=two"
        args.universe_domain = "googleapis.com"
        args.dataproc_version = "2.1.115"
        args.custom_sources_path = "gs://test-bucket/sources"
        args.shutdown_timer_in_sec = 300
        args.bucket_name = "test-bucket"
        args.gcs_base_path = "run-id"
        args.metadata = None

        with patch("builtins.open", mock_open(read_data="echo test")):
            with self.assertRaises(RuntimeError) as ctx:
                self.engine._create_vm(
                    args, "test-instance", "test-disk", "us-central1"
                )
        self.assertIn(
            "Invalid accelerator count: two. Must be an integer.", str(ctx.exception)
        )


if __name__ == "__main__":
    unittest.main()
