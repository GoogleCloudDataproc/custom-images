#!/bin/bash
# Copyright 2026 Google LLC and contributors
# Licensed under the Apache License, Version 2.0.
#
# Simple customization script for testing the Dataproc custom image build process.

set -eo pipefail

echo "========================================="
echo "Starting local test customization script..."
echo "========================================="

# 1. Update package list and install a lightweight diagnostic tool (e.g., htop or tree)
echo "Installing htop utility..."
apt-get update && apt-get install -y htop

# 2. Write a verification marker file to the image
echo "Writing verification marker file to /etc/custom_image_test..."
echo "Dataproc Custom Image built successfully at $(date)" > /etc/custom_image_test

echo "========================================="
echo "Customization script finished successfully!"
echo "========================================="
