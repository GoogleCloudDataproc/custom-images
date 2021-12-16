#!/usr/bin/env bash

set -euxo pipefail

# This script applies patches to log4j jars of version [2.0.0, 2.16.0)
# for CVE-2021-44228 in Dataproc custom images.

function main() {
  echo "Searching for log4j jars of version [2.0.0, 2.16.0)..."
  local -a jars
  mapfile -t jars < <(find / -regextype egrep -regex ".*/log4j-core-2\.([0-9]|1[0-5])(\.[0-9]+)?\.jar$" || true)
  echo "Found ${#jars[@]} jars"
  for jar in "${jars[@]}"; do
   echo "Patching ${jar}"
   zip -q -d "${jar}" org/apache/logging/log4j/core/lookup/JndiLookup.class \
     || { echo "Failed patching ${jar}"; exit 1; }
   echo "Done with patching ${jar}"
  done

  echo "All done"
}

main "$@"
