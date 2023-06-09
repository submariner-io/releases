#!/usr/bin/env bash

set -e
set -o pipefail

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"

### Functions: General ###

# Run the supplied command in the background so that `errexit` and `pipefail` are honored.
# Errors will be counted instead of exiting immediately.
function record_errors() {
    "$@" &
    wait $! || errors=$((errors+1))
}

function create_release() {
    local project="$1"
    local target="$2"
    local files=( "${@:3}" )
    local version="${release[version]}"
    local latest=false
    local prerelease=false

    [[ -z "${semver[pre]}" ]] || prerelease=true

    # Mark as latest release only when we're actually trying to release the latest GA release (ignoring any pre-releases).
    [[ $({ echo "$version"; git tag -l 'v*'; } | grep -v '-' | sort -V | tail -n1) != "$version" ]] || latest=true

    gh config set prompt disabled
    with_retries 3 dryrun gh release create "$version" "${files[@]}" \
        --latest="$latest" \
        --prerelease="$prerelease" \
        --title "${release['name']}" \
        --repo "${ORG}/${project}" \
        --target "${target}"
}

function create_project_release() {
    local project=${1:-${project}}
    clone_repo
    checkout_project_branch

    # Skip trying to tag a project that's already tagged as we've already released it
    if _git rev-parse "${release['version']}" >/dev/null 2>&1; then
        echo "WARN: '${project}' is already tagged with version '${release['version']}', skipping it..."
        return
    fi

    # If the project has container images, copy them to the release tag
    # This will fail if the source images don't exist; abort then without trying to create the release
    # shellcheck disable=SC2046 # We need to split $(project_images)
    if [[ -n "$(project_images)" ]] && ! tag_images "${release['version']}" $(project_images); then
        ((errors++))
        return 1
    fi

    # Release the project on GitHub so that it gets tagged
    export GITHUB_TOKEN="${RELEASE_TOKEN}"
    commit_ref=$(_git rev-parse --verify HEAD)
    record_errors create_release "${project}" "${commit_ref}"
}

function clone_and_create_branch() {
    local branch=$1
    local base_branch="${2:-${release['branch']:-devel}}"

    clone_repo
    _git checkout -B "${branch}" "remotes/origin/${base_branch}"
}

function update_go_mod() {
    [[ -z "$SKIP_WHEN_TESTING" ]] || { echo "SKIPPING: ${FUNCNAME[0]}" && return 0; }
    local target_version=${release['branch']:-devel}
    dryrun eval target_version="${release['version']}"

    go mod tidy

    awk '/github.com\/submariner-io.* v/ { print $1 }' go.mod | while read -r target; do
        dryrun export GONOPROXY="${target}"
        go get "${target}@${target_version}"
    done

    go mod tidy
    go mod vendor
}

function update_dependencies() {
    clone_and_create_branch "update-dependencies-${release['branch']:-devel}"

    if [ -f "projects/${project}/go.mod" ]; then
        shopt -s globstar
        for gomod in projects/"${project}"/**/go.mod; do
            # Run in subshell so we don't change the working directory even on failure
            ( cd "${gomod%/*}" && update_go_mod; )
        done
    fi

    run_if_defined "$update_dependencies_extra"
    create_pr "Update Submariner dependencies to ${release['version']}"
}

function push_to_repo() {
    local branch="$1"

    dryrun _git push -f "https://${GITHUB_REPOSITORY_OWNER}:${RELEASE_TOKEN}@github.com/${ORG}/${project}.git" "${branch}"
}

function create_pr() {
    local msg="$1"
    local base_branch="${release['branch']:-devel}"
    local branch output pr_url
    local empty_flag=--allow-empty
    export GITHUB_TOKEN="${RELEASE_TOKEN}"

    dryrun unset empty_flag
    _git commit $empty_flag -a -s -m "${msg}"
    branch=$(_git rev-parse --abbrev-ref HEAD)
    push_to_repo "${branch}"
    output=$(dryrun gh pr create --repo "${ORG}/${project}" --head "${branch}" --base "${base_branch}" --title "${msg}" \
                --label automated --body "${msg}" 2>&1)

    # shellcheck disable=SC2181 # The command is too long already, this is more readable
    if [[ $? -ne 0 ]]; then
        echo "Error creating pull request to ${msg@Q} on ${project}: ${output@Q}" >> "$reviews"
        return 1
    fi

    pr_url=$(echo "${output}" | dryrun grep "http.*")

    # Apply labels separately, since each label trigger the CI separately anyway and that causes multiple runs clogging the CI up.
    dryrun gh pr edit --add-label e2e-all-k8s "${pr_url}" || echo "INFO: Didn't label 'e2e-all-k8s', continuing without it."
    dryrun gh pr edit --add-label ready-to-test "${pr_url}" || >&2 echo "WARN: Didn't label 'ready-to-test', continuing without it."
    dryrun gh pr merge --auto --repo "${ORG}/${project}" --rebase "${pr_url}" || echo "WARN: Failed to enable auto merge on ${pr_url}"
    echo " * $pr_url" >> "$reviews"
}

# Tag the images matching the release commit using the release tag
function tag_images() {
    local tag=$1
    shift
    local project_version

    # Use the latest RC image for the initial GA image, to avoid any potentially breaking changes that might've slipped in untested.
    if [[ "${semver[patch]}" = "0" && -z "${semver[pre]}" ]]; then
        project_version=$(git rev-parse --symbolic --tags="v${semver[major]}.${semver[minor]}.*" | sort -V | tail -n1)
    else
        project_version=$(cd "projects/${project}" && make print-version | grep -oP "(?<=CALCULATED_VERSION=).+")
    fi
    
    echo "$QUAY_PASSWORD" | dryrun skopeo login quay.io -u "$QUAY_USERNAME" --password-stdin
    for image; do
        local full_image="${REPO}/${image}"
        # --all ensures we handle multi-arch images correctly; it works with single- and multi-arch
        dryrun skopeo copy --all "docker://${full_image}:${project_version#v}" "docker://${full_image}:${tag#v}"
    done
}

### Functions: Branch Stage ###

function update_base_branch() {
    sed -i -E "s/^(BASE_BRANCH.*= *)devel$/\1${release['branch']}/" "projects/${project}/Makefile"
    sed -i -E "s/\<devel\>/${release['branch']}/" "projects/${project}/.github/workflows"/*
}

function adjust_shipyard() {
    local branch="${release['branch']}"
    local project=shipyard

    clone_and_create_branch "${branch}" devel

    # Make sure all Shipyard's base images are immediately available to consuming projects with the expected tag (the stable branch name),
    # otherwise image building jobs are likely to fail when creating the branches.
    # We do this before changing the base branch, so that we'll use the latest `devel` images.
    # shellcheck disable=SC2046 # We need to split $(project_images)
    tag_images "$branch" $(project_images)

    sed -e "s/devel/${branch}/" -i projects/shipyard/Makefile.versions
    update_base_branch
    _git commit -a -s -m "Update Shipyard to use stable branch '${branch}'"
    push_to_repo "${branch}"
}

function create_stable_branch() {
    local project=${1:-${project}}
    local branch="${release['branch']}"
    [[ "$project" != "shipyard" ]] || return 0

    clone_and_create_branch "${branch}" devel
    update_base_branch
    _git commit -a -s -m "Update base image to use stable branch '${branch}'"
    record_errors push_to_repo "${branch}"
}

function release_branch() {

    # Branch out `releases` itself, in order to allow changes in release process on devel.
    # Further release logic needs to happen on the stable branch.
    create_stable_branch releases

    # Shipyard needs some extra care since everything else relies on it
    adjust_shipyard

    for_every_project create_stable_branch "${PROJECTS[@]}"
}

### Functions: Shipyard Stage ###

function release_shipyard() {

    # Release Shipyard first so that we get the tag
    create_project_release shipyard

    # Create a PR to bump Shipyard in Admiral
    project=admiral record_errors update_dependencies
}

### Functions: Admiral Stage ###

function release_admiral() {

    # Release Admiral first so that we get the tag
    create_project_release admiral

    # Create a PR to pin Admiral on every one of its consumers
    for project in "${PROJECTS_PROJECTS[@]}"; do
        record_errors update_dependencies
    done
}

### Functions: Projects Stage ###

function update_operator_versions() {
    local versions_file
    versions_file=$(grep -l -r --include='*.go' --exclude-dir=vendor 'Default.*Version *=' "projects/${project}/")
    [[ -n "${versions_file}" ]] || exit_error "Can't find file for default image versions"

    sed -i -E "s/(Default.*Version *=) .*/\1 \"${release['version']#v}\"/" "${versions_file}"
}

function release_projects() {
    # Release projects first so that we get them tagged
    for_every_project create_project_release "${PROJECTS_PROJECTS[@]}"

    # Create a PR for operator to use these versions
    local project="submariner-operator"
    local update_dependencies_extra=update_operator_versions
    record_errors update_dependencies
}

### Functions: Installers Stage ###

function release_installers() {
    for_every_project create_project_release "${INSTALLER_PROJECTS[@]}"

    # Create a PR for subctl to use these versions
    local project="subctl"
    record_errors update_dependencies

    # Create a PR in submariner-charts to update the CHARTS_VERSION in the Makefile
    local project="submariner-charts"
    local update_dependencies_extra=update_charts_versions
    record_errors update_dependencies
}

### Functions: Released Stage ###

function release_released() {
    local commit_ref
    commit_ref=$(git rev-parse --verify HEAD)
    make subctl SUBCTL_ARGS=cross
    record_errors create_release releases "${commit_ref}" projects/subctl/dist/subctl-*

    for_every_project create_project_release "${PROJECTS[@]}"
}

function update_charts_versions() {
     sed -i -E "s/(CHARTS_VERSION=).*/\1${release['version']#v}/" projects/"${project}"/Makefile
}

function comment_finished_status() {
    local comment="Release for status '${release['status']}' finished "

    if [[ $errors -gt 0 ]]; then
        comment+="with ${errors} errors."$'\n'"Please check the job for more details: ${GITHUB_JOB_URL}"
    else
        [[ -s "$reviews" ]] || return 0
        comment+='successfully. Please review:'
    fi

    comment+=$'\n\n'"$(<"$reviews")"
    local pr_url
    pr_url=$(gh api -H 'Accept: application/vnd.github.groot-preview+json' \
        "repos/:owner/:repo/commits/$(git rev-parse HEAD)/pulls" | jq -r '.[0] | .html_url')
    dryrun gh pr review "${pr_url}" --comment --body "${comment}"
}

### Main ###

reviews=$(mktemp)
errors=0
determine_target_release
read_release_file
extract_semver "${release['version']#v}"

case "${release['status']}" in
branch|shipyard|admiral|projects|installers|released)
    "release_${release['status']}"
    ;;
*)
    exit_error "Unknown status '${release['status']}'"
    ;;
esac

comment_finished_status || echo "WARN: Can't post comment with release status"
[[ $errors -eq 0 ]] || exit_error "Encountered ${errors} errors while doing the release."
