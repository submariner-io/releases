#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions
source ${SCRIPTS_DIR}/lib/utils

### Functions ###

# Allow running dapper in dapper by some trickery
function dapper_in_dapper() {
    # Plant a directive in the Dockerfile.dapper to let dapper run in dapper
    local orig_pwd=$(docker inspect $HOSTNAME | jq -r ".[0].Mounts[] | select(.Destination == \"$DAPPER_SOURCE\") | .Source")
    local cur_pwd=$(pwd | sed -E 's/[a-zA-Z0-9-]+/../g')
    echo "ENV DAPPER_CP=${cur_pwd}/${orig_pwd}/projects/submariner-operator" >> Dockerfile.dapper

    # Trick our own Makefile to think we're running outside dapper
    export DAPPER_HOST_ARCH=""

    # Commit and tag so that we get a correct "version" calculated
    git commit -a -m "DAPPER IN DAPPER"
    git tag -a -f "${release['version']}" -m "${release['version']}"
}

function cleanup_dapper_in_dapper() {
    # Remove last commit which was needed to run dapper in dapper
    git reset --hard HEAD^

    # Remove local tag so not to interfere
    git tag -d ${release["version"]}
}

### Main ###

determine_target_release
read_release_file

project=submariner-operator
clone_repo

    pushd projects/submariner-operator
    dapper_in_dapper

    [[ "$1" == "cross" ]] && make build-cross
    make bin/subctl

    ln -f -s $(pwd)/bin/subctl /go/bin/subctl
    ./bin/subctl version
    cleanup_dapper_in_dapper

