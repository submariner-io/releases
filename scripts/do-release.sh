#!/usr/bin/env bash

set -e

# shellcheck source=scripts/lib/image_defs
. "${DAPPER_SOURCE}/scripts/lib/image_defs"
# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"

### Constants ###

readonly BUNDLE_SOURCE_DIR=${BUNDLE_SOURCE_DIR:-"projects/submariner-operator/packagemanifests"}
readonly BUNDLE_TARGET_DIR=${BUNDLE_TARGET_DIR:-"projects/community-operators/operators/submariner"}
readonly BUNDLE_TARGET_ORG=${BUNDLE_TARGET_ORG:-"k8s-operatorhub"}
readonly BUNDLE_TARGET_REPO=${BUNDLE_TARGET_REPO:-"${BUNDLE_TARGET_ORG}/community-operators"}
readonly BUNDLE_PR_TEMPLATE="https://raw.githubusercontent.com/${BUNDLE_TARGET_REPO}/main/docs/pull_request_template.md"

### Functions: General ###

function create_release() {
    local project="$1"
    local target="$2"
    local files=( "${@:3}" )
    [[ "${release['pre-release']}" = "true" ]] && local prerelease="--prerelease"
#    [[ -n "${release['release-notes']}" ]] && local notes="--notes ${release['release-notes']}"

    gh config set prompt disabled
    # shellcheck disable=SC2086,SC2068 # Some things have to be expanded or GH CLI flips out
    dryrun gh release create "${release['version']}" ${files[@]} ${prerelease} \
        --title "${release['name']}" \
        --repo "${ORG}/${project}" \
        --target "${target}"
}

function create_project_release() {
    local project=$1
    clone_repo
    checkout_project_branch

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
    local base_branch="${2:-${release['branch']:-devel}}"

    clone_repo
    _git checkout -B "${branch}" "remotes/origin/${base_branch}"
}

function update_go_mod() {
    local target="$1"
    if [[ ! -f projects/${project}/go.mod ]]; then
        return 1
    fi

    # Run in subshell so we don't change the working directory even on failure
    (
        pushd "projects/${project}"

        go mod tidy
        GOPROXY=direct go get "github.com/submariner-io/${target}@${release['version']}"
        go mod vendor
        go mod tidy
    )
}

function push_to_repo() {
    local branch="$1"

    dryrun _git push -f "https://${GITHUB_ACTOR}:${RELEASE_TOKEN}@github.com/${ORG}/${project}.git" "${branch}"
}

function create_pr() {
    local branch="$1"
    local msg="$2"
    local title="$3"
    local base_branch="${4:-${release['branch']}}"
    local base_branch="${base_branch:-devel}"
    local to_review
    export GITHUB_TOKEN="${RELEASE_TOKEN}"

    _git commit -a -s -m "${title}" -m "${msg}"
    push_to_repo "${branch}"
    to_review=$(dryrun gh pr create --repo "${ORG}/${project}" --head "${branch}" --base "${base_branch}" --title "${title}" \
                --label "ready-to-test" --label "e2e-all-k8s" --body "${msg}")

    # shellcheck disable=SC2181 # The command is too long already, this is more readable
    if [[ $? -ne 0 ]]; then
        reviews+=("Error creating pull request to ${msg@Q} on ${project}: ${to_review@Q}")
        return 1
    fi

    dryrun gh pr merge --auto --repo "${ORG}/${project}" --squash "${to_review}" || echo "WARN: Failed to enable auto merge on ${to_review}"
    reviews+=("${to_review}")
}

function release_images() {
    local args="$1"
    dryrun make release-images RELEASE_ARGS="${args}" || \
        dryrun make release RELEASE_ARGS="${args}"
}

function tag_images() {
    # Creating a local tag so that images are uploaded with it
    git tag -a -f "${release['version']}" -m "${release['version']}"

    release_images "$* --tag ${release['version']}"
}

### Functions: Branch Stage ###

function update_base_branch() {
    sed -i -E "s/^(BASE_BRANCH.*= *)devel$/\1${release['branch']}/" "projects/${project}/Makefile"
    sed -i -E "s/\<devel\>/${release['branch']}/" "projects/${project}/.github/workflows"/*
}

function adjust_shipyard() {
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
        # Make sure subctl is taken from devel, as it won't be available yet
        cd projects/shipyard
        make images IMAGES_ARGS="--buildargs 'SUBCTL_VERSION=devel'"
    )

    release_images "shipyard-dapper-base --tag='${release['branch']}'"
}

function create_branches() {
    local branch="${release['branch']}"

    # Shipyard needs some extra care since everything else relies on it
    adjust_shipyard

    for project in ${PROJECTS[*]}; do
        [[ "$project" != "shipyard" ]] || continue

        clone_and_create_branch "${branch}" devel
        update_base_branch
        _git commit -a -s -m "Update base image to use stable branch '${branch}'"
        push_to_repo "${branch}" || errors=$((errors+1))
    done
}

### Functions: Shipyard Stage ###

function pin_to_shipyard() {
    clone_and_create_branch pin_shipyard
    update_go_mod shipyard
    create_pr pin_shipyard "Pin Shipyard to ${release['version']}"
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

    local versions_file
    versions_file=$(grep -l -r --include='*.go' --exclude-dir=vendor 'Default.*Version *=' projects/${project}/)
    [[ -n "${versions_file}" ]] || { printerr "Can't find file for default image versions"; return 1; }

    sed -i -E "s/(Default.*Version *=) .*/\1 \"${release['version']#v}\"/" "${versions_file}"
    if [[ "${release['pre-release']}" != "true" ]]; then
        release_bundle || errors=$((errors+1))
    fi
    create_pr update_operator "Update Operator to use version ${release['version']}"
}

function release_projects() {
    # Release projects first so that we get them tagged
    for project in ${OPERATOR_CONSUMES[*]}; do
        create_project_release "$project"
    done

    # Create a PR for operator to use these versions
    update_operator_pr || errors=$((errors+1))
}

### Functions: Released Stage ###

function release_all() {
    local commit_ref
    commit_ref=$(git rev-parse --verify HEAD)
    make subctl SUBCTL_ARGS=cross
    create_release releases "${commit_ref}" projects/submariner-operator/dist/subctl-* || errors=$((errors+1))

    for project in ${PROJECTS[*]}; do
        create_project_release "$project"
    done
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

function get_bundle_pr_body() {
   echo "Release Submariner v$1"
   curl -s "${BUNDLE_PR_TEMPLATE}" | sed -E "s/\[ \]/\[x\]/g; 0,/Is operator/d"
}

function release_bundle() {
    local bundle_version="${release['version']#v}"
    local bundle_from_version="${release['bundle.from_version']:-0.0.0}"
    local bundle_channel
    bundle_channel="${release['bundle.channel']:-$(echo alpha-"${bundle_version}" | cut -d'.' -f1,2)}"

    local pr_body
    pr_body=$(get_bundle_pr_body "${bundle_version}")

    (
        project=submariner-operator
        pushd projects/${project}
        dapper_in_dapper

        make packagemanifests \
            VERSION="${bundle_version}" \
            FROM_VERSION="${bundle_from_version}" \
            CHANNEL="${bundle_channel}"

        # Running dapper_in_dapper changes the Dockerfile, make sure to reset it.
        _git checkout HEAD Dockerfile.dapper
    )

    if [ ! -d "${BUNDLE_SOURCE_DIR}/${bundle_version}" ]; then
        echo "ERROR: The bundle version ${bundle_version} was not found in ${BUNDLE_SOURCE_DIR}/${bundle_version}"
        return 1
    fi

    (
        project=community-operators
        ORG="${BUNDLE_TARGET_ORG}"
        clone_and_create_branch "submariner-update" "main"
        cp -r "${BUNDLE_SOURCE_DIR}/${bundle_version}" "${BUNDLE_TARGET_DIR}"
        cp "${BUNDLE_SOURCE_DIR}/submariner.package.yaml" "${BUNDLE_TARGET_DIR}"
        pushd projects/${project}
        tree "${BUNDLE_TARGET_DIR}"
        create_pr "submariner-update" \
            "${pr_body}" \
            "[upstream] Update submariner-operator to ${bundle_version}" \
            "main"
    )
}

### Main ###

reviews=()
errors=0
determine_target_release
read_release_file
extract_semver "${release['version']#v}"

case "${release['status']}" in
branch)
    create_branches
    ;;
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

if [[ $errors -gt 0 ]]; then
    printerr "Encountered ${errors} errors while doing the release."
    exit 1
fi
