#!/usr/bin/env bash
# shellcheck disable=SC2034 # We declare some shared variables here

set -e

source "${DAPPER_SOURCE}/scripts/lib/image_defs"
source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${SCRIPTS_DIR}/lib/debug_functions"

### Functions: General ###

function validate() {
    is_semver "$VERSION"
}

function write() {
    echo "$*" >> "${file}"
}

function set_stable_branch() {
    write "branch: release-${semver['major']}.${semver['minor']}"
}

function set_status() {
    write "status: $1"
}

### Functions: Creating initial release ###

function init_components() {
    local project=shipyard
    clone_repo
    checkout_project_branch
    write "components:"
    write "  shipyard: $(_git rev-parse HEAD)"
}

function create_initial() {
    declare -gA release
    echo "Creating initial release file ${file}"
    cat > "${file}" <<EOF
---
version: v${VERSION}
name: ${VERSION}
EOF

    extract_semver "$VERSION"
 
    if [[ -n "${semver['pre']}" ]]; then
        write "pre-release: true"
    elif [[ "${semver['patch']}" = "0" ]]; then
        # On first GA or a major.minor we'll branch out first
        set_stable_branch
        set_status "branch"
        return
    fi

    # Detect stable branch and set it if necessary
    if git rev-parse "v${semver['major']}.${semver['minor']}.0" 2&> /dev/null ; then
        set_stable_branch
    fi

    set_status "shipyard"
    init_components
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
