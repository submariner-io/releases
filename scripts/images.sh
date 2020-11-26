#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/image_defs
source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions
source ${SCRIPTS_DIR}/lib/version

function _pull_image() {
    local hash="${1#v}"
    local full_image="${REPO}/${image}"
    docker pull "${full_image}:${hash}"
    docker tag "${full_image}:${hash}" "${full_image}:${DEV_VERSION}"
}

function pull_images() {
    for project in ${PROJECTS[*]}; do
        clone_repo
        local project_version=$(_git describe --tags --exclude="${CUTTING_EDGE}" --exclude="latest")

        for image in ${project_images[${project}]}; do
            _pull_image "$project_version"
        done
    done
}

determine_target_release
read_release_file
pull_images
