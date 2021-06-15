#!/usr/bin/env bash

set -e

# shellcheck source=scripts/lib/image_defs
. "${DAPPER_SOURCE}/scripts/lib/image_defs"
# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"

function _pull_image() {
    local hash="${1#v}"
    local full_image="${REPO}/${image}"
    docker pull "${full_image}:${hash}"
    docker tag "${full_image}:${hash}" "${full_image}:${DEV_VERSION}"
}

function pull_images() {
    for project in ${PROJECTS[*]}; do
        local project_version
        clone_repo
        checkout_project_branch
        project_version=$(cd "projects/${project}" && make print-version | grep -oP "(?<=CALCULATED_VERSION=).+")

        for image in ${project_images[${project}]}; do
            _pull_image "$project_version"
        done
    done
}

determine_target_release
read_release_file

# If we're creating branches, no need to pull images as they won't exist and aren't needed yet anyhow
[[ "${release['status']}" != "branch" ]] || exit 0

pull_images
