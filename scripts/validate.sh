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
    ! gh_commit_sha "${release['branch']}" >/dev/null 2>&1 || \
        exit_error "'${project}' already has stable branch '${release['branch']}'."
}

function validate_project_commits() {
    local latest_hash

    for project; do
        ! gh_commit_sha "${release['version']}" >/dev/null 2>&1 || \
            exit_error "'${project}' is already released with version '${release['version']}'."
        latest_hash="$(gh_commit_sha "${release['branch']:-devel}")" || \
            exit_error "Failed to determine latest commit hash for ${project}"

        local commit_hash="${release["components.${project}"]}"
        [[ $latest_hash =~ ^${commit_hash} ]] || \
            exit_error "Version of ${project} (${commit_hash}) isn't the latest, consider using ${latest_hash}"
    done
}

function validate_release() {
    local version="${release['version']}"
    validate_release_fields || exit_error "File is missing expected fields"
    validate_semver "${version#v}"
    git check-ref-format "refs/tags/${version}" || \
        exit_error "Version ${version@Q} is not a valid tag name"

    case "${release['status']}" in
    branch)
        for_every_project validate_no_branch "${PROJECTS[@]}"
        ;;
    shipyard)
        validate_project_commits shipyard
        ;;
    admiral)
        validate_project_commits admiral
        ;;
    projects)
        validate_project_commits "${PROJECTS_PROJECTS[@]}"
        ;;
    installers)
        validate_project_commits "${INSTALLER_PROJECTS[@]}"
        ;;
    released)
        validate_project_commits "${RELEASED_PROJECTS[@]}"
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
