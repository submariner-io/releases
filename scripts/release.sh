#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/image_defs
source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions

### Functions: General ###

function validate() {
    is_semver "$VERSION"
}

### Functions: Creating initial release ###

function create_initial() {
    echo "Creating initial release file ${file}"
}

### Functions: Advancing release to next stage ###

function advance_stage() {
    echo "Advancing release to the next stage (file=${file})"
}

### Main ###

validate
file="releases/v${VERSION}.yaml"
if [[ ! -f "${file}" ]]; then
    create_initial
    echo "Created initial release file ${file}"
else
    advance_stage
    echo "Advanced release to the next stage (file=${file})"
fi
