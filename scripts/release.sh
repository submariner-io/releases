#!/usr/bin/env bash
# shellcheck disable=SC2034 # We declare some shared variables here

set -e
set -o pipefail

export ORG="${ORG:-submariner-io}"

source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${SCRIPTS_DIR}/lib/utils"
print_env ORG GITHUB_ACTOR GITHUB_REPOSITORY_OWNER
source "${SCRIPTS_DIR}/lib/debug_functions"

### Functions: General ###

function expect_env() {
    local env_var="$1"
    if [[ -z "${!env_var}" ]]; then
        printerr "Expected environment variable ${env_var@Q} is not set"
        exit 1
    fi
}

function expect_git() {
    local git_config="$1"
    if [[ -z "$(git config --get "${git_config}")" ]]; then
        printerr "Expected Git config ${git_config@Q} is not set, please set it and try again"
        exit 1
    fi
}

function validate() {
    is_semver "$VERSION"
    dryrun expect_env "GITHUB_TOKEN"
    expect_git "user.email"
    expect_git "user.name"

    # Run a harmless command to make sure the token we have is valid
    dryrun gh repo view > /dev/null

    # Make sure that the release targets the same base branch (if it exists), as the release process might be different.
    local branch
    branch="$(stable_branch_name)"
    if [[ "${BASE_BRANCH}" != "${branch}" ]] && git fetch upstream_releases "${branch}" >/dev/null 2>&1; then
        printerr "Releases for ${semver['major']}.${semver['minor']} must be based on the ${branch@Q} branch. " \
            "Please rebase your branch on ${branch@Q} and try again."
        exit 1
    fi
}

function write() {
    echo "$*" >> "${file}"
}

function stable_branch_name() {
    echo "release-${semver['major']}.${semver['minor']}"
}

function set_stable_branch() {
    write "branch: $(stable_branch_name)"
}

function set_status() {
    if [[ -z "${release['status']}" ]]; then
        write "status: ${1}"
        return
    fi

    sed -i -E "s/(status: ).*/\1${1}/" "${file}"
}

function sync_upstream() {
    git remote rm upstream_releases 2> /dev/null || :
    git remote add upstream_releases "https://github.com/${ORG}/releases.git"
    git fetch upstream_releases "${BASE_BRANCH}"
    git rebase "upstream_releases/${BASE_BRANCH}"
}

# Validates the created commit to make sure we're not missing anything
function validate_commit {
    if ! make validate; then
        printerr "Failed to run validation for the commit, please attend any reported errors and try again."
        reset_git
        exit 1
    fi
}

### Functions: Creating initial release ###

function create_pr() {
    local branch="$1"
    local msg="$2"
    local pr_to_review
    local project

    # shellcheck disable=SC2046
    project="$(basename $(pwd))"
    local repo="${ORG}/${project}"
    local gh_user=${GITHUB_ACTOR:-${ORG}}

    git add "${file}"
    git commit -s -m "${msg}"
    dryrun git push -f "https://${GITHUB_TOKEN}:x-oauth-basic@github.com/${gh_user}/${project}.git" "HEAD:${branch}"
    pr_to_review=$(dryrun gh pr create --repo "${repo}" --head "${gh_user}:${branch}" --base "${BASE_BRANCH}" --label "automated" \
                   --title "${msg}" --body "${msg}")
    dryrun gh pr merge --auto --repo "${repo}" --rebase "${pr_to_review}" \
        || echo "WARN: Failed to enable auto merge on ${pr_to_review}"
    echo "Created Pull Request: ${pr_to_review}"
}


function create_initial() {
    declare -gA release
    echo "Creating initial release file ${file}"
    cat > "${file}" <<EOF
---
version: v${VERSION}
name: ${VERSION}
EOF

    # On first RC we'll branch to allow development to continue while doing the release
    if [[ "${semver['pre']}" = "rc0" ]]; then
        set_stable_branch
        set_status "branch"
        return
    fi

    # Detect stable branch and set it if necessary
    if [[ -z "${semver['pre']}" || "${semver['pre']}" =~ rc.* ]]; then
        set_stable_branch
    fi

    # We're not branching, so just move on to shipyard
    set_status "shipyard"
    read_release_file
    advance_to_shipyard
}

### Functions: Advancing release to next stage ###

function write_component() {
    local project=${1:-${project}}
    local branch=${release['branch']:-devel}
    local commit_hash
    if ! commit_hash="$(gh_commit_sha "${branch}")"; then
        printerr "Failed to determine latest commit hash for ${project} - make sure branch ${branch@Q} exists"
        return 1
    fi

    write "  ${project}: ${commit_hash}"
}

function advance_to_shipyard() {
    write "components:"
    write_component "shipyard"
}

function advance_to_admiral() {
    write_component "admiral"
}

function advance_to_projects() {
    for_every_project write_component "${PROJECTS_PROJECTS[@]}"
}

function advance_to_installers() {
    for_every_project write_component "${INSTALLER_PROJECTS[@]}"
}

function advance_to_released() {
    write_component "subctl"
}

function advance_stage() {
    echo "Advancing release to the next stage (file=${file})"

    read_release_file
    case "${release['status']}" in
    branch|shipyard|admiral|projects|installers)
        local next="${NEXT_STATUS[${release['status']}]}"
        set_status "${next}"
        # shellcheck disable=SC2086
        advance_to_${next}
        validate_commit
        create_pr "releasing-${VERSION}" "Advancing ${VERSION} release to status: ${next}"
        ;;
    released)
        echo "The release ${VERSION} has been released, nothing to do."
        ;;
    *)
        printerr "Unknown status '${release['status']}'"
        exit 1
        ;;
    esac
}

### Main ###

extract_semver "$VERSION"
base_commit=$(git rev-parse HEAD)
sync_upstream
validate

file="releases/v${VERSION}.yaml"
if [[ ! -f "${file}" ]]; then
    create_initial
    echo "Created initial release file ${file}"
    create_pr "releasing-${VERSION}" "Initiating release of ${VERSION}"
else
    advance_stage
    echo "Advanced release to the next stage (file=${file})"
fi
