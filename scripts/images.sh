#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions
source ${SCRIPTS_DIR}/lib/deploy_funcs
source ${SCRIPTS_DIR}/lib/version

REPO="quay.io/submariner"
declare -A project_images
project_images[lighthouse]="lighthouse-agent lighthouse-coredns"
project_images[shipyard]="nettest shipyard-dapper-base"
project_images[submariner]="submariner submariner-globalnet submariner-route-agent"
project_images[submariner-operator]="submariner-operator"

function _load_dev_image() {
    docker pull "${image}:${hash}"
    docker tag "${image}:${hash}" "${image}:${DEV_VERSION}"
}

function _pull_image() {
    local image="${1}"
    local hash="${2#v}"
    if ! _load_dev_image; then
        hash="${hash:0:7}"
        _load_dev_image
    fi
}

function pull_images() {
    for project in ${PROJECTS[*]}; do
        for image in ${project_images[${project}]}; do
            _pull_image "${REPO}/${image}" "${release["components.${project}"]}"
            import_image "${REPO}/${image}"
        done
    done
}

file=$(readlink -f releases/target)
read_release_file
pull_images
