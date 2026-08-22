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
"""Base execution engine interface for custom image creation workflow."""

import abc


class ExecutionEngine(abc.ABC):
    """Abstract base class representing the execution engine interface."""

    @abc.abstractmethod
    def infer_args(self, args):
        """Infers missing command-line arguments using Google Cloud APIs or CLI."""
        pass

    @abc.abstractmethod
    def perform_sanity_checks(self, args):
        """Performs sanity checks (e.g. checks if the target image already exists)."""
        pass

    @abc.abstractmethod
    def create_image(self, args):
        """Creates the custom Dataproc image."""
        pass

    @abc.abstractmethod
    def add_label(self, args):
        """Adds the goog-dataproc-version label to the created custom image."""
        pass

    @abc.abstractmethod
    def run_smoke_test(self, args):
        """Runs a smoke test on the custom image."""
        pass

    @abc.abstractmethod
    def notify_expiration(self, args):
        """Notifies the user when the custom image will expire."""
        pass
