#!/usr/bin/env bash
# shellcheck disable=SC2034 # We declare some shared variables here

set -e
set -o pipefail

export ORG="${ORG:-submariner-io}"
GITHUB_ACTOR=${GITHUB_ACTOR:-$ORG}

source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${SCRIPTS_DIR}/lib/utils"
print_env ORG UPDATE GITHUB_ACTOR GITHUB_REPOSITORY_OWNER
source "${SCRIPTS_DIR}/lib/debug_functions"

### Functions: General ###

function expect_env() {
    local env_var="$1"
    [[ -n "${!env_var}" ]] || exit_error "Expected environment variable ${env_var@Q} is not set"
}

function expect_git() {
    local git_config="$1"
    [[ -n "$(git config --get "${git_config}")" ]] || \
        exit_error "Expected Git config ${git_config@Q} is not set, please set it and try again"
}

function validate() {
    update_hashes_requested || validate_semver "$VERSION"
    dryrun expect_env "GITHUB_TOKEN"
    expect_git "user.email"
    expect_git "user.name"

    # Run a harmless command to make sure the token we have is valid
    dryrun gh repo view > /dev/null

    # Make sure that the release targets the same base branch (if it exists), as the release process might be different.
    local branch
    branch="$(stable_branch_name)"
    if [[ "${BASE_BRANCH}" != "${branch}" ]] && git fetch upstream_releases "${branch}" >/dev/null 2>&1; then
        exit_error "Releases for ${semver['major']}.${semver['minor']} must be based on the ${branch@Q} branch. " \
            "Please rebase your branch on ${branch@Q} and try again."
    fi
}

function write() {
    local key="$1"
    local value="$2"
    yq -i ".${key}=\"${value}\"" "$file"
}

function stable_branch_name() {
    echo "release-${semver['major']}.${semver['minor']}"
}

function sync_upstream() {
    git remote rm upstream_releases 2> /dev/null || :
    git remote add upstream_releases "https://github.com/${ORG}/releases.git"
    git fetch upstream_releases "${BASE_BRANCH}"
    git rebase "upstream_releases/${BASE_BRANCH}"
}

# Validates the created commit to make sure we're not missing anything
function validate_commit {
    make validate || {
        reset_git
        exit_error "Failed to run validation for the commit, please attend any reported errors and try again."
    }
}

function create_pr() {
    local branch="$1"
    local title="$2"
    local msg="$3"
    local pr_to_review
    local project

    # shellcheck disable=SC2046
    project="$(basename $(pwd))"
    local repo="${ORG}/${project}"

    git add "${file}"
    git commit -s -m "${title}"
    dryrun git push -f "https://${GITHUB_TOKEN}:x-oauth-basic@github.com/${GITHUB_ACTOR}/${project}.git" "HEAD:${branch}"
    pr_to_review=$(dryrun gh pr create --repo "${repo}" --head "${GITHUB_ACTOR}:${branch}" --base "${BASE_BRANCH}" --label "automated" \
                   --title "${title}" --body "${msg}")
    dryrun gh pr merge --auto --repo "${repo}" --rebase "${pr_to_review}" \
        || echo "WARN: Failed to enable auto merge on ${pr_to_review}"
    echo "Created Pull Request: ${pr_to_review}"
}

### Functions: Creating initial release ###

function create_initial() {
    declare -gA release
    echo "Creating initial release file ${file}"
    echo '---' > "$file"
    write version "v${VERSION}"
    write name "$VERSION"

    # On first RC we'll branch to allow development to continue while doing the release
    if [[ "${semver['pre']}" = "rc0" ]]; then
        write branch "$(stable_branch_name)"
        write status "branch"
        return
    fi

    # Detect stable branch and set it if necessary
    if [[ -z "${semver['pre']}" || "${semver['pre']}" =~ rc.* ]]; then
        write branch "$(stable_branch_name)"
    fi

    # We're not branching, so just move on to shipyard
    write status "shipyard"
    read_release_file
    advance_to_shipyard
}

### Functions: Advancing release to next stage ###

function write_component() {
    local project=${1:-${project}}
    local branch=${release['branch']:-devel}
    local commit_hash
    commit_hash="$(gh_commit_sha "${branch}")" || \
        exit_error "Failed to determine latest commit hash for ${project} - make sure branch ${branch@Q} exists"

    write "components.${project}" "$commit_hash"
}

function advance_to_shipyard() {
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
  for_every_project write_component "${RELEASED_PROJECTS[@]}"
}

function update_prs_message() {
    case "$1" in
    admiral)
        print_update_prs "${SHIPYARD_CONSUMERS[@]}"
        ;;
    projects)
        print_update_prs "${ADMIRAL_CONSUMERS[@]}"
        ;;
    installers)
        print_update_prs "${INSTALLER_PROJECTS[@]}"
        ;;
    released)
        print_update_prs "${RELEASED_PROJECTS[@]}"
        ;;
    esac
}

function print_update_prs() {
    local branch="${release['branch']:-devel}"
    local head="update-dependencies-${branch}"
    local update_prs=()

    for project; do
        #shellcheck disable=SC2207 # Split on purpose, as we need the individual URLs
        update_prs+=($(dryrun gh_api "pulls?base=${branch}&head=${ORG}:${head}&state=open" | jq -r ".[].html_url")) || \
            exit_error "Failed to list pull requests for ${project}."
    done

    [[ ${#update_prs[*]} -eq 0 ]] || printf 'Depends on %s\n' "${update_prs[@]}"
}

function advance_stage() {
    echo "Advancing release to the next stage (file=${file})"

    read_release_file
    case "${release['status']}" in
    branch|shipyard|admiral|projects|installers)
        local next="${NEXT_STATUS[${release['status']}]}"
        write status "$next"
        # shellcheck disable=SC2086
        advance_to_${next}
        validate_commit
        create_pr "releasing-${VERSION}" "Advancing ${VERSION} release to status: ${next}" "$(update_prs_message "$next")"
        ;;
    released)
        echo "The release ${VERSION} has been released, nothing to do."
        ;;
    *)
        exit_error "Unknown status '${release['status']}'"
        ;;
    esac
}

### Functions: Updating hashes for release in process ###

function update_hashes_requested() {
    [[ "${UPDATE@L}" =~ ^(true|yes|y)$ ]]
}

function update_hashes() {
    determine_target_release
    read_release_file
    local status="${release['status']}"

    [[ $(type -t "advance_to_${status}") == function ]] || exit_error "Unsupported status when updating hashes: ${status@Q}"
    "advance_to_${release['status']}"
    git commit --amend --no-edit --only "$file"
    dryrun git push -f "https://${GITHUB_TOKEN}:x-oauth-basic@github.com/${GITHUB_ACTOR}/releases.git" \
        "HEAD:releasing-${release['version']}"
}

### Main ###

extract_semver "$VERSION"
base_commit=$(git rev-parse HEAD)
sync_upstream
validate

if update_hashes_requested; then
    update_hashes
    echo "Updated hashes for the release (file=${file})"
    exit
fi

file="releases/v${VERSION}.yaml"
if [[ ! -f "${file}" ]]; then
    create_initial
    echo "Created initial release file ${file}"
    create_pr "releasing-${VERSION}" "Initiating release of ${VERSION}"
else
    advance_stage
    echo "Advanced release to the next stage (file=${file})"
fi
