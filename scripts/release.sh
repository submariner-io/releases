#!/usr/bin/env bash
# shellcheck disable=SC2034 # We declare some shared variables here

set -e
set -o pipefail

source "${DAPPER_SOURCE}/scripts/lib/image_defs"
source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${SCRIPTS_DIR}/lib/debug_functions"

ORG=submariner-io

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
}

function write() {
    echo "$*" >> "${file}"
}

function set_stable_branch() {
    write "branch: release-${semver['major']}.${semver['minor']}"
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

### Functions: Creating initial release ###

function create_pr() {
    local branch="$1"
    local msg="$2"
    local pr_to_review
    local project

    # shellcheck disable=SC2046
    project="$(basename $(pwd))"
    local repo="submariner-io/${project}"
    local gh_user=${GITHUB_ACTOR:-${ORG}}

    git add "${file}"
    git commit -s -m "${msg}"
    dryrun git push -f "https://${GITHUB_TOKEN}:x-oauth-basic@github.com/${gh_user}/${project}.git" "HEAD:${branch}"
    pr_to_review=$(dryrun gh pr create --repo "${repo}" --head "${gh_user}:${branch}" --base "${BASE_BRANCH}" --title "${msg}" --body "${msg}")
    dryrun gh pr merge --auto --repo "${repo}" --rebase "${pr_to_review}" \
        || echo "WARN: Failed to enable auto merge on ${pr_to_review}"
    echo "Created Pull Request: ${pr_to_review}"
}


function create_initial() {
    declare -gA release
    sync_upstream
    echo "Creating initial release file ${file}"
    cat > "${file}" <<EOF
---
version: v${VERSION}
name: ${VERSION}
EOF

    if [[ -n "${semver['pre']}" ]]; then
        write "pre-release: true"

        # On first RC we'll branch to allow development to continue while doing the release
        if [[ "${semver['pre']}" = "rc0" ]]; then
            set_stable_branch
            set_status "branch"
            return
        fi
    fi

    # Detect stable branch and set it if necessary
    if [[ -z "${semver['pre']}" || "${semver['pre']}" =~ rc.* ]]; then
        set_stable_branch
    fi

    # We're not branching, so just move on to shipyard
    set_status "shipyard"
    read_release_file
    advance_branch
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

function advance_branch() {
    write "components:"
    write_component "shipyard"
}

function advance_shipyard() {
    write_component "admiral"
}

function advance_admiral() {
    for project in ${OPERATOR_CONSUMES[*]}; do
        write_component
    done
}

function advance_projects() {
    write_component "submariner-operator"
    write_component "submariner-charts"
}

function advance_installers() {
    write_component "subctl"
}

function advance_stage() {
    echo "Advancing release to the next stage (file=${file})"

    read_release_file
    case "${release['status']}" in
    branch|shipyard|admiral|projects|installers)
        sync_upstream
        local next="${NEXT_STATUS[${release['status']}]}"
        set_status "${next}"
        # shellcheck disable=SC2086
        advance_${release['status']}
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

validate
file="releases/v${VERSION}.yaml"
extract_semver "$VERSION"
if [[ ! -f "${file}" ]]; then
    create_initial
    echo "Created initial release file ${file}"
    create_pr "releasing-${VERSION}" "Initiating release of ${VERSION}"
else
    advance_stage
    echo "Advanced release to the next stage (file=${file})"
fi
