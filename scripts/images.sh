#!/usr/bin/env bash

set -e

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"

function _pull_image() {
    local hash="${1#v}"
    local full_image="${REPO}/${image}"
    dryrun docker pull "${full_image}:${hash}"
    dryrun docker tag "${full_image}:${hash}" "${full_image}:${DEV_VERSION}"
}

function pull_images() {
    local project_version
    clone_repo
    checkout_project_branch
    project_version=$(cd "projects/${project}" && make print-version BASE_BRANCH="${release['branch']:-devel}" | \
                      grep -oP "(?<=CALCULATED_VERSION=).+")

    for image in $(project_images); do
        _pull_image "$project_version"
    done
}

determine_target_release
read_release_file
exit_on_branching
for_every_project pull_images "${PROJECTS[@]}"
