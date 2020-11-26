#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/image_defs
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
    [[ "${release['pre-release']}" = "true" ]] && local prerelease="--prerelease"

    gh config set prompt disabled
    gh release create "${release['version']}" $files $prerelease \
        --title "${release['name']}" \
        --repo "${org}/${project}" \
        --target "${target}" \
        --notes "${release['release-notes']}"
}

function create_project_release() {
    export GITHUB_TOKEN="${RELEASE_TOKEN}"
    commit_ref=$(_git rev-parse --verify HEAD)
    create_release "${project}" "${commit_ref}" || errors=$((errors+1))
}

function update_go_mod() {
    local target="$1"
    if [[ ! -f projects/${project}/go.mod ]]; then
        return
    fi

    # Run in subshell so we don't change the working directory even on failure
    (
        pushd "projects/${project}"
        go get github.com/submariner-io/${target}@${release['version']}
        go mod vendor
        go mod tidy
    )
}

function create_pr() {
    local branch="$1"
    local msg="$2"
    local org=$(determine_org)

    _git commit -a -s -m "${msg}"
    _git push -f https://${GITHUB_ACTOR}:${RELEASE_TOKEN}@github.com/${org}/${project}.git ${branch}
    gh pr create --repo "${org}/${project}" --head ${branch} --base master --title "${msg}" --body "${msg}"
}

function pin_to_shipyard() {
    clone_repo
    _git checkout -B pin_shipyard origin/master
    sed -i -E "s/(shipyard-dapper-base):.*/\1:${release['version']#v}/" projects/${project}/Dockerfile.dapper
    update_go_mod shipyard
    create_pr pin_shipyard "Pin Shipyard to ${release['version']}"
}

function release_shipyard() {
    local project=shipyard

    # Release Shipyard first so that we get the tag
    clone_repo
    create_project_release || errors=$((errors+1))

    # Tag Shipyard images so they're available to use
    tag_images "${project_images['shipyard']}" || errors=$((errors+1))

    # Create a PR to pin Shipyard on every one of its consumers
    for project in ${SHIPYARD_CONSUMERS[*]}; do
        pin_to_shipyard || errors=$((errors+1))
    done
}

function pin_to_admiral() {
    clone_repo
    _git checkout -B pin_admiral origin/master
    update_go_mod admiral
    create_pr pin_admiral "Pin Admiral to ${release['version']}"
}

function release_admiral() {
    local project=admiral

    # Release Admiral first so that we get the tag
    clone_repo
    create_project_release || errors=$((errors+1))

    # Create a PR to pin Admiral on every one of it's consumers
    for project in ${ADMIRAL_CONSUMERS[*]}; do
        pin_to_admiral || errors=$((errors+1))
    done
}

function update_operator_pr() {
    local project="submariner-operator"

    clone_repo
    _git checkout -B update_operator origin/master
    for target in ${OPERATOR_CONSUMES[*]} ; do
        update_go_mod "${target}"
    done

    sed -i -E "s/(.*Version +=) .*/\1 \"${release['version']#v}\"/" projects/${project}/pkg/versions/versions.go
    create_pr update_operator "Update Operator to use version ${release['version']}"
}

function release_projects() {
    # Release projects first so that we get them tagged
    for project in ${OPERATOR_CONSUMES[*]}; do
        clone_repo
        create_project_release || errors=$((errors+1))
    done

    # Create a PR for operator to use these versions
    update_operator_pr || errors=$((errors+1))
}

function tag_images() {
    local images="$@"

    # Creating a local tag so that images are uploaded with it
    git tag -f "${release['version']}"

    make release RELEASE_ARGS="$images --tag ${release['version']}"
}

function tag_all_images() {
    local images=""

    for project in ${PROJECTS[*]}; do
        for image in ${project_images[${project}]}; do
            images+=" $image"
        done
    done

    tag_images "$images"
}

function release_all() {
    local commit_ref=$(git rev-parse --verify HEAD)
    make subctl SUBCTL_ARGS=cross
    create_release releases "${commit_ref}" projects/submariner-operator/dist/subctl-* || errors=$((errors+1))

    for project in ${PROJECTS[*]}; do
        clone_repo

        # Skip trying to tag a project that's already tagged as we've already released it
        if _git rev-parse "${release['version']}" >/dev/null 2>&1; then
            continue
        fi

        create_project_release
    done

    tag_all_images || errors=$((errors+1))
}

### Main ###

errors=0
determine_target_release
read_release_file

case "${release['status']}" in
shipyard)
    release_shipyard
    ;;
admiral)
    release_admiral
    ;;
projects)
    release_projects
    ;;
released)
    release_all
    ;;
*)
    printerr "Unknown status '${release['status']}'"
    exit 1
    ;;
esac

if [[ $errors > 0 ]]; then
    printerr "Encountered ${errors} errors while doing the release."
    exit 1
fi

