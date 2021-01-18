#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/image_defs
source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions

### Functions: General ###

function create_release() {
    local project="$1"
    local target="$2"
    local files="${@:3}"
    [[ "${release['pre-release']}" = "true" ]] && local prerelease="--prerelease"

    gh config set prompt disabled
    gh release create "${release['version']}" $files $prerelease \
        --title "${release['name']}" \
        --repo "${ORG}/${project}" \
        --target "${target}" \
        --notes "${release['release-notes']}"
}

function create_project_release() {
    local project=$1
    clone_repo

    # Skip trying to tag a project that's already tagged as we've already released it
    if _git rev-parse "${release['version']}" >/dev/null 2>&1; then
        echo "WARN: '${project}' is already tagged with version '${release['version']}', skipping it..."
        return
    fi

    # Release the project on GitHub so that it gets tagged
    export GITHUB_TOKEN="${RELEASE_TOKEN}"
    commit_ref=$(_git rev-parse --verify HEAD)
    create_release "${project}" "${commit_ref}" || errors=$((errors+1))

    # Tag the project's container images, if there are any to tag
    if [[ -n "${project_images[${project}]}" ]]; then
        tag_images "${project_images[${project}]}" || errors=$((errors+1))
    fi
}

function clone_and_create_branch() {
    local branch=$1
    clone_repo
    _git checkout -B ${branch} origin/master
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
    export GITHUB_TOKEN="${RELEASE_TOKEN}"

    _git commit -a -s -m "${msg}"
    _git push -f https://${GITHUB_ACTOR}:${RELEASE_TOKEN}@github.com/${ORG}/${project}.git ${branch}
    reviews+=($(gh pr create --repo "${ORG}/${project}" --head ${branch} --base master --title "${msg}" --body "${msg}"))
}

function tag_images() {
    local images="$@"

    # Creating a local tag so that images are uploaded with it
    git tag -a -f "${release['version']}" -m "${release['version']}"

    make release RELEASE_ARGS="$images --tag ${release['version']}"
}

### Functions: Shipyard Stage ###

function pin_to_shipyard() {
    clone_and_create_branch pin_shipyard
    sed -i -E "s/(shipyard-dapper-base):.*/\1:${release['version']#v}/" projects/${project}/Dockerfile.dapper
    update_go_mod shipyard
    create_pr pin_shipyard "Pin Shipyard to ${release['version']}"
}

function unpin_from_shipyard() {
    clone_repo
    _git checkout -B unpin_shipyard origin/master
    sed -i -E "s/(shipyard-dapper-base):.*/\1:devel/" projects/${project}/Dockerfile.dapper
    create_pr unpin_shipyard "Un-Pin Shipyard after ${release['version']} released"
}

function release_shipyard() {

    # Release Shipyard first so that we get the tag
    create_project_release shipyard

    # Create a PR to pin Shipyard on every one of its consumers
    for project in ${SHIPYARD_CONSUMERS[*]}; do
        pin_to_shipyard || errors=$((errors+1))
    done
}

### Functions: Admiral Stage ###

function pin_to_admiral() {
    clone_and_create_branch pin_admiral
    update_go_mod admiral
    create_pr pin_admiral "Pin Admiral to ${release['version']}"
}

function release_admiral() {

    # Release Admiral first so that we get the tag
    create_project_release admiral

    # Create a PR to pin Admiral on every one of it's consumers
    for project in ${ADMIRAL_CONSUMERS[*]}; do
        pin_to_admiral || errors=$((errors+1))
    done
}

### Functions: Projects Stage ###

function update_operator_pr() {
    local project="submariner-operator"

    clone_and_create_branch update_operator
    for target in ${OPERATOR_CONSUMES[*]} ; do
        update_go_mod "${target}"
    done

    sed -i -E "s/(.*Version +=) .*/\1 \"${release['version']#v}\"/" projects/${project}/pkg/versions/versions.go
    create_pr update_operator "Update Operator to use version ${release['version']}"
}

function release_projects() {
    # Release projects first so that we get them tagged
    for project in ${OPERATOR_CONSUMES[*]}; do
        create_project_release $project
    done

    # Create a PR for operator to use these versions
    update_operator_pr || errors=$((errors+1))
}

### Functions: Released Stage ###

function release_all() {
    local commit_ref=$(git rev-parse --verify HEAD)
    make subctl SUBCTL_ARGS=cross
    create_release releases "${commit_ref}" projects/submariner-operator/dist/subctl-* || errors=$((errors+1))

    for project in ${PROJECTS[*]}; do
        create_project_release $project
    done

    # Create a PR to un-pin Shipyard on every one of its consumers, but only on GA releases
    if [[ "${release['pre-release']}" != "true" ]]; then
        for project in ${SHIPYARD_CONSUMERS[*]}; do
            unpin_from_shipyard || errors=$((errors+1))
        done
    fi
}

function post_reviews_comment() {
    if [[ ${#reviews[@]} = 0 ]]; then
        return
    fi

    local comment="Release for status '${release['status']}' is done, please review:"
    for review in ${reviews[@]}; do
        comment+=$(printf "\n * ${review}")
    done

    local pr_url=$(gh api -H 'Accept: application/vnd.github.groot-preview+json' \
        repos/:owner/:repo/commits/$(git rev-parse HEAD)/pulls | jq -r '.[0] | .html_url')
    gh pr review "${pr_url}" --comment --body "${comment}"
}

### Main ###

reviews=()
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

post_reviews_comment || echo "WARN: Can't post reviews comment"

if [[ $errors > 0 ]]; then
    printerr "Encountered ${errors} errors while doing the release."
    exit 1
fi

