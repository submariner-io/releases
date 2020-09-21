#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/utils

file=$(readlink -f releases/target)
read_release_file

gh release create "${release['version']}" --title "${release['name']}" --notes "${release['release-notes']}"
