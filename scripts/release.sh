#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions

### Functions ###

function determine_org() {
    git config --get remote.origin.url | awk -F'[:/]' '{print $(NF-1)}'
}

function create_release() {
    local project="$1"
    local target="$2"
    local files="${@:3}"
    local org=$(determine_org)

    gh config set prompt disabled
    gh release create "${release['version']}" $files \
        --title "${release['name']}" \
        --repo "${org}/${project}" \
        --target "${target}" \
        --notes "${release['release-notes']}"
}

### Main ###

file=$(readlink -f releases/target)
read_release_file
errors=0

commit_ref=$(git rev-parse --verify HEAD)
create_release releases "${commit_ref}" projects/submariner-operator/dist/subctl-* || errors=$((errors+1))

export GITHUB_TOKEN="${RELEASE_TOKEN}"

for project in ${PROJECTS[*]}; do
    clone_repo
    commit_ref=$(_git rev-parse --verify HEAD)
    create_release "${project}" "${commit_ref}" || errors=$((errors+1))
done

if [[ $errors > 0 ]]; then
    printerr "Encountered ${errors} errors while doing the release."
    exit 1
fi

