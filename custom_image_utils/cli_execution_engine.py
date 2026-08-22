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
"""CLI-based implementation of the ExecutionEngine interface."""

import subprocess
from custom_image_utils import args_inferer
from custom_image_utils import expiration_notifier
from custom_image_utils import image_labeller
from custom_image_utils import shell_image_creator
from custom_image_utils import smoke_test_runner
from custom_image_utils.execution_engine import ExecutionEngine


class CliExecutionEngine(ExecutionEngine):
    """Execution engine that uses gcloud and gsutil CLI utilities."""

    def infer_args(self, args):
        args_inferer.infer_args(args)

    def perform_sanity_checks(self, args):
        # Check the image doesn't already exist using gcloud compute images describe.
        command = [
            "gcloud",
            "compute",
            "images",
            "describe",
            args.image_name,
            f"--project={args.project_id}",
        ]
        result = subprocess.run(
            command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        if result.returncode == 0:
            raise RuntimeError("Image {} already exists.".format(args.image_name))

    def create_image(self, args):
        shell_image_creator.create(args)

    def add_label(self, args):
        image_labeller.add_label(args)

    def run_smoke_test(self, args):
        smoke_test_runner.run(args)

    def notify_expiration(self, args):
        expiration_notifier.notify(args)
