#!/usr/bin/env bash

set -e

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"
. "${SCRIPTS_DIR}/lib/deploy_funcs"

for project in "${PROJECTS[@]}"; do
    for image in $(project_images); do
        [[ ! "$image" =~ "shipyard-" ]] || continue
        import_image "${REPO}/${image}"
    done
done


