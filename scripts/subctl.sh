#!/usr/bin/env bash

set -e

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"
. "${SCRIPTS_DIR}/lib/utils"

### Main ###

determine_target_release
read_release_file

project=submariner-operator
clone_repo
checkout_project_branch

pushd projects/submariner-operator
dapper_in_dapper

target=( bin/subctl )
[[ "$1" == "cross" ]] && target+=( build-cross )
make "${target[@]}" VERSION="${release['version']}" DEFAULT_IMAGE_VERSION="${release['version']}"

ln -f -s "$(pwd)/bin/subctl" /go/bin/subctl
./bin/subctl version

