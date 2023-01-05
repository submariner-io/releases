#!/usr/bin/env bash

set -e

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"
. "${SCRIPTS_DIR}/lib/utils"

### Functions ###

# Allow running dapper in dapper by some trickery
function dapper_in_dapper() {
    # Trick our own Makefile to think we're running outside dapper
    export DAPPER_HOST_ARCH=""

    # Make sure we have Dockerfile.dapper as it could be in Shipyard and needs to be fetched
    make Dockerfile.dapper

    # Plant a directive in the Dockerfile.dapper to let dapper run in dapper
    local orig_pwd
    local cur_pwd
    orig_pwd=$(docker inspect "$HOSTNAME" | jq -r ".[0].Mounts[] | select(.Destination == \"$DAPPER_SOURCE\") | .Source")
    cur_pwd=$(pwd | sed -E 's/[a-zA-Z0-9-]+/../g')
    echo "ENV DAPPER_CP=${cur_pwd}/${orig_pwd}/projects/subctl" >> Dockerfile.dapper
}

# Skips make when requested (useful for testing)
function _make() {
    local DEBUG_PRINT=false
    [[ -z "$SKIP_WHEN_TESTING" ]] || { echo "SKIPPING: make $*" && return 0; }
    make "$@"
}

### Main ###

determine_target_release
read_release_file

project=subctl
clone_repo
checkout_project_branch

pushd projects/subctl
dapper_in_dapper

target=( cmd/bin/subctl )

# If cross build requested perform it, except when dry-running as it takes a very long time and has little benefit when testing
[[ "$1" == "cross" && "$dryrun" != "true" ]] && target+=( build-cross )
_make "${target[@]}" VERSION="${release['version']}" DEFAULT_IMAGE_VERSION="${DEFAULT_IMAGE_VERSION:-${release['version']}}"

ln -f -s "$(pwd)/cmd/bin/subctl" /go/bin/subctl
[[ -n "$SKIP_WHEN_TESTING" ]] || ./cmd/bin/subctl version

