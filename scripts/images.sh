#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/image_defs
source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions
source ${SCRIPTS_DIR}/lib/deploy_funcs
source ${SCRIPTS_DIR}/lib/version

function _pull_image() {
    local hash="${1#v}"
    local full_image="${REPO}/${image}"
    docker pull "${full_image}:${hash}"
    docker tag "${full_image}:${hash}" "${full_image}:${DEV_VERSION}"
}

function pull_images() {
    for project in ${PROJECTS[*]}; do
        for image in ${project_images[${project}]}; do
            if ! _pull_image "${release["components.${project}"]}"; then
                clone_repo
                local project_version=$(_git describe --tags --dirty="-${DEV_VERSION}" --exclude="${CUTTING_EDGE}" --exclude="latest")
                _pull_image "$project_version"
            fi

            import_image "${REPO}/${image}"
        done
    done
}

file=$(readlink -f releases/target)
read_release_file
pull_images
