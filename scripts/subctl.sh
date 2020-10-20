#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions
source ${SCRIPTS_DIR}/lib/utils

file=$(readlink -f releases/target)
read_release_file

project=submariner-operator
clone_repo

pushd projects/submariner-operator
export VERSION="${release["version"]}"
make bin/subctl
ln -f -s $(pwd)/bin/subctl /go/bin/subctl
./bin/subctl version
popd

