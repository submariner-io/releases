#!/usr/bin/env bash

set -e

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"
. "${SCRIPTS_DIR}/lib/utils"

### Functions ###

# Allow running dapper in dapper by some trickery
function dapper_in_dapper() {
    # Plant a directive in the Dockerfile.dapper to let dapper run in dapper
    local orig_pwd
    local cur_pwd
    orig_pwd=$(docker inspect "$HOSTNAME" | jq -r ".[0].Mounts[] | select(.Destination == \"$DAPPER_SOURCE\") | .Source")
    cur_pwd=$(pwd | sed -E 's/[a-zA-Z0-9-]+/../g')
    echo "ENV DAPPER_CP=${cur_pwd}/${orig_pwd}/projects/submariner-operator" >> Dockerfile.dapper

    # Trick our own Makefile to think we're running outside dapper
    export DAPPER_HOST_ARCH=""
}

### Main ###

determine_target_release
read_release_file

project=submariner-operator
clone_repo
checkout_project_branch

pushd projects/submariner-operator
dapper_in_dapper

export DEFAULT_IMAGE_VERSION=${release["version"]}
export VERSION=${release["version"]}
[[ "$1" == "cross" ]] && make build-cross
make bin/subctl

ln -f -s "$(pwd)/bin/subctl" /go/bin/subctl
./bin/subctl version

