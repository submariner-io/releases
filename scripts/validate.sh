#!/usr/bin/env bash

set -e
set -o pipefail

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"

### Functions ###

function _validate() {
    local key=$1

    if [[ -z "${release[$key]}" ]]; then
        printerr "Missing value for ${key@Q}"
        errors=$((errors+1))
        return 1
    fi
}

function _validate_component() {
    local project="${1:-$project}"
    if ! _validate "components.${project}"; then
        return
    fi

    local commit_hash="${release["components.${project}"]}"
    if [[ ! $commit_hash =~ ^[0-9a-f]{7,40}$ ]]; then
        printerr "Version of ${project} should be a valid git commit hash: ${commit_hash}"
        errors=$((errors+1))
    fi
}

function validate_release_fields() {
    local errors=0

    _validate 'version'
    _validate 'status'
    local status="${release['status']}"

    if [[ "${status}" = "branch" ]]; then
        _validate "branch"
        return $errors
    fi

    _validate 'name'
    _validate 'components'

    case "${status}" in
    shipyard)
        _validate_component "shipyard"
        ;;
    admiral)
        _validate_component "admiral"
        ;;
    projects)
        for_every_project _validate_component "${PROJECTS_PROJECTS[@]}"
        ;;
    installers)
        for_every_project _validate_component "${INSTALLER_PROJECTS[@]}"
        ;;
    released)
        for_every_project _validate_component "${PROJECTS[@]}"
        ;;
    *)
        printerr "Status '${status}' should be one of: 'branch', 'shipyard', 'admiral', 'projects', 'installers' or 'released'."
        errors=1
        ;;
    esac

    return $errors
}

function validate_admiral_consumers() {
    local expected_version="$1"
    for project in "${ADMIRAL_CONSUMERS[@]}"; do
        local actual_version
        actual_version=$(grep admiral "projects/${project}/go.mod" | cut -f2 -d' ')
        if [[ "${expected_version}" != "${actual_version}" ]]; then
            printerr "Expected Admiral version ${expected_version} but found ${actual_version} in ${project}"
            return 1
        fi
    done
}

function validate_shipyard_consumers() {
    local expected_version="$1"
    for project in "${SHIPYARD_CONSUMERS[@]}"; do
        local actual_version
        actual_version=$(head -1 "projects/${project}/Dockerfile.dapper" | cut -f2 -d':')
        if [[ "${expected_version}" != "${actual_version}" ]]; then
            printerr "Expected Shipyard version ${expected_version} but found ${actual_version} in ${project}"
            return 1
        fi
    done
}

function validate_no_branch() {
    if gh_commit_sha "${release['branch']}" >/dev/null 2>&1; then
        printerr "'${project}' already has stable branch '${release['branch']}'."
        return 1
    fi
}

function validate_project_commits() {
    local latest_hash

    for project; do
        if gh_commit_sha "${release['version']}" >/dev/null 2>&1; then
            printerr "'${project}' is already released with version '${release['version']}'."
            return 1
        fi

        if ! latest_hash="$(gh_commit_sha "${release['branch']:-devel}")"; then
            printerr "Failed to determine latest commit hash for ${project}"
            return 1
        fi

        local commit_hash="${release["components.${project}"]}"
        if [[ ! $latest_hash =~ ^${commit_hash} ]]; then
            printerr "Version of ${project} (${commit_hash}) isn't the latest, consider using ${latest_hash}"
            return 1
        fi
    done
}

function validate_no_update_prs() {
    local head="update-dependencies-${release['branch']:-devel}"
    local update_prs

    for project; do
        if ! update_prs="$(dryrun gh_api "pulls?base=${release['branch']:-devel}&head=${ORG}:${head}&state=open" | jq -r ".[].html_url")"; then
            printerr "Failed to list pull requests for ${project}."
            return 1
        fi

        if [[ -n "${update_prs}" ]]; then
            printerr "Found open ${head@Q} pull requests on ${project}, make sure they're merged before proceeding"
            echo "${update_prs}"
            return 1
        fi
    done
}

function validate_release() {
    if ! validate_release_fields; then
        printerr "File is missing expected fields"
        return 1
    fi

    local version=${release['version']}
    if ! git check-ref-format "refs/tags/${version}"; then
        printerr "Version ${version@Q} is not a valid tag name"
        return 1
    fi

    is_semver "${version#v}" || return 1

    case "${release['status']}" in
    branch)
        for_every_project validate_no_branch "${PROJECTS[@]}"
        ;;
    shipyard)
        validate_project_commits shipyard
        ;;
    admiral)
        validate_project_commits admiral
        validate_no_update_prs "${SHIPYARD_CONSUMERS[@]}"
        ;;
    projects)
        validate_project_commits "${PROJECTS_PROJECTS[@]}"
        validate_no_update_prs "${ADMIRAL_CONSUMERS[@]}"
        ;;
    installers)
        validate_project_commits "${INSTALLER_PROJECTS[@]}"
        validate_no_update_prs "${INSTALLER_PROJECTS[@]}"
        ;;
    released)
        validate_project_commits "${RELEASED_PROJECTS[@]}"
        validate_no_update_prs "${RELEASED_PROJECTS[@]}"
        ;;
    esac

# TODO: Uncomment once we're using automated release which makes sure these are in sync
#    validate_admiral_consumers "${release["components.admiral"]}"
#    validate_shipyard_consumers "${release["components.shipyard"]#v}"
}

### Main ###

determine_target_release
read_release_file
validate_release
