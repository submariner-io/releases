#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/image_defs
source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions
source ${SCRIPTS_DIR}/lib/deploy_funcs

for project in ${PROJECTS[*]}; do
    for image in ${project_images[${project}]}; do
        import_image "${REPO}/${image}"
    done
done


