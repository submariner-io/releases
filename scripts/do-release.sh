#!/usr/bin/env bash

set -e
set -o pipefail

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"

### Functions: General ###

function create_release() {
    local project="$1"
    local target="$2"
    local files=( "${@:3}" )
    [[ "${release['pre-release']}" = "true" ]] && local prerelease="--prerelease"
#    [[ -n "${release['release-notes']}" ]] && local notes="--notes ${release['release-notes']}"

    gh config set prompt disabled
    # shellcheck disable=SC2086,SC2068 # Some things have to be expanded or GH CLI flips out
    with_retries 3 dryrun gh release create "${release['version']}" ${files[@]} ${prerelease} \
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
    if [[ -n "$(project_images)" ]] && ! tag_images $(project_images); then
        ((errors++))
        return 1
    fi

    # Release the project on GitHub so that it gets tagged
    export GITHUB_TOKEN="${RELEASE_TOKEN}"
    commit_ref=$(_git rev-parse --verify HEAD)
    create_release "${project}" "${commit_ref}" || errors=$((errors+1))
}

function clone_and_create_branch() {
    local branch=$1
    local base_branch="${2:-${release['branch']:-devel}}"

    clone_repo
    _git checkout -B "${branch}" "remotes/origin/${base_branch}"
}

function _update_go_mod() {
    go mod tidy -compat=1.17
    GOPROXY=direct go get "github.com/submariner-io/${target}@${release['version']}"
    go mod tidy -compat=1.17
    go mod vendor
}

function update_go_mod() {
    local target="$1"

    shopt -s globstar
    for gomod in projects/"${project}"/**/go.mod; do
        dir="${gomod%/*}"
        if [ ! -d "$dir" ]; then
            # The project doesn't have any go.mod, dir is ".../**/go.mod"
            return 1
        fi

        # Run in subshell so we don't change the working directory even on failure
        ( cd "$dir" && dryrun _update_go_mod; )
    done
}

function update_dependencies() {
    clone_and_create_branch "update-dependencies-${release['branch']:-devel}"

    for dependency; do
        update_go_mod "$dependency"
    done

    run_if_defined "$update_dependencies_extra"
    create_pr "Update dependencies ($*) to ${release['version']}"
}

function push_to_repo() {
    local branch="$1"

    dryrun _git push -f "https://${GITHUB_REPOSITORY_OWNER}:${RELEASE_TOKEN}@github.com/${ORG}/${project}.git" "${branch}"
}

function create_pr() {
    local msg="$1"
    local base_branch="${release['branch']:-devel}"
    local branch to_review
    export GITHUB_TOKEN="${RELEASE_TOKEN}"

    _git commit -a -s -m "${msg}"
    branch=$(_git rev-parse --abbrev-ref HEAD)
    push_to_repo "${branch}"
    to_review=$(dryrun gh pr create --repo "${ORG}/${project}" --head "${branch}" --base "${base_branch}" --title "${msg}" \
                --label "automated" --label "ready-to-test" --label "e2e-all-k8s" --body "${msg}" 2>&1)

    # shellcheck disable=SC2181 # The command is too long already, this is more readable
    if [[ $? -ne 0 ]]; then
        reviews+=("Error creating pull request to ${msg@Q} on ${project}: ${to_review@Q}")
        return 1
    fi

    to_review=$(echo "${to_review}" | dryrun grep "http.*")
    dryrun gh pr merge --auto --repo "${ORG}/${project}" --squash "${to_review}" || echo "WARN: Failed to enable auto merge on ${to_review}"
    reviews+=("${to_review}")
}

function tag_images() {
    # Tag the images matching the release commit using the release tag
    local project_version
    project_version=$(cd "projects/${project}" && make print-version BASE_BRANCH="${release['branch']:-devel}" | \
                      grep -oP "(?<=CALCULATED_VERSION=).+")
    local hash="${project_version#v}"
    
    echo "$QUAY_PASSWORD" | dryrun skopeo login quay.io -u "$QUAY_USERNAME" --password-stdin
    for image; do
        local full_image="${REPO}/${image}"
        # --all ensures we handle multi-arch images correctly; it works with single- and multi-arch
        dryrun skopeo copy --all "docker://${full_image}:${hash}" "docker://${full_image}:${release['version']#v}"
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
    sed -e "s/devel/${branch}/" -i projects/shipyard/Makefile.versions
    update_base_branch
    _git commit -a -s -m "Update Shipyard to use stable branch '${branch}'"
    push_to_repo "${branch}"

    # Build & upload shipyard base image so that other projects have it immediately
    # Otherwise, image building jobs are likely to fail when creating the branches
    (
        set -e

        # Trick our own Makefile to think we're running outside dapper
        export DAPPER_HOST_ARCH=""

        # Rebuild Shipyard image with the changes we made for stable branches
        cd projects/shipyard
        make images multiarch-images

        # This will release all of Shipyard's images
        dryrun make release-images TAG="${release['branch']}"
    )
}

function create_stable_branch() {
    local project=${1:-${project}}
    local branch="${release['branch']}"
    [[ "$project" != "shipyard" ]] || return 0

    clone_and_create_branch "${branch}" devel
    update_base_branch
    _git commit -a -s -m "Update base image to use stable branch '${branch}'"
    push_to_repo "${branch}" || errors=$((errors+1))
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

    # Create a PR to pin Shipyard on every one of its consumers
    for project in "${SHIPYARD_CONSUMERS[@]}"; do
        update_dependencies shipyard || errors=$((errors+1))
    done
}

### Functions: Admiral Stage ###

function release_admiral() {

    # Release Admiral first so that we get the tag
    create_project_release admiral

    # Create a PR to pin Admiral on every one of it's consumers
    for project in "${ADMIRAL_CONSUMERS[@]}"; do
        update_dependencies admiral || errors=$((errors+1))
    done
}

### Functions: Projects Stage ###

function update_operator_versions() {
    local versions_file
    versions_file=$(grep -l -r --include='*.go' --exclude-dir=vendor 'Default.*Version *=' "projects/${project}/")
    [[ -n "${versions_file}" ]] || { printerr "Can't find file for default image versions"; return 1; }

    sed -i -E "s/(Default.*Version *=) .*/\1 \"${release['version']#v}\"/" "${versions_file}"
}

function release_projects() {
    # Release projects first so that we get them tagged
    for_every_project create_project_release "${PROJECTS_PROJECTS[@]}"

    # Create a PR for operator to use these versions
    local project="submariner-operator"
    local update_dependencies_extra=update_operator_versions
    update_dependencies "${OPERATOR_CONSUMES[@]}" || errors=$((errors+1))
}

### Functions: Installers Stage ###

function release_installers() {
    for_every_project create_project_release "${INSTALLER_PROJECTS[@]}"

    # Create a PR for subctl to use these versions
    local project="subctl"
    update_dependencies "${SUBCTL_CONSUMES[@]}" || errors=$((errors+1))
}

### Functions: Released Stage ###

function release_released() {
    local commit_ref
    commit_ref=$(git rev-parse --verify HEAD)
    make subctl SUBCTL_ARGS=cross
    create_release releases "${commit_ref}" projects/subctl/dist/subctl-* || errors=$((errors+1))

    for_every_project create_project_release "${PROJECTS[@]}"
}

function post_reviews_comment() {
    if [[ ${#reviews[@]} = 0 ]]; then
        return
    fi

    local comment="Release for status '${release['status']}' is done, please review:"
    for review in "${reviews[@]}"; do
        comment+=$(printf "\n * %s" "${review}")
    done

    local pr_url
    pr_url=$(gh api -H 'Accept: application/vnd.github.groot-preview+json' \
        "repos/:owner/:repo/commits/$(git rev-parse HEAD)/pulls" | jq -r '.[0] | .html_url')
    dryrun gh pr review "${pr_url}" --comment --body "${comment}"
}

### Main ###

reviews=()
errors=0
determine_target_release
read_release_file
extract_semver "${release['version']#v}"

case "${release['status']}" in
branch|shipyard|admiral|projects|installers|released)
    "release_${release['status']}"
    ;;
*)
    printerr "Unknown status '${release['status']}'"
    exit 1
    ;;
esac

post_reviews_comment || echo "WARN: Can't post reviews comment"

if [[ $errors -gt 0 ]]; then
    printerr "Encountered ${errors} errors while doing the release."
    exit 1
fi
