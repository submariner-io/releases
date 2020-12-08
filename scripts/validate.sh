#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions

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
    local project=$1
    if ! _validate "components.${project}"; then
        return
    fi

    local commit_hash="${release["components.${project}"]}"
    if [[ ! $commit_hash =~ ^([0-9a-f]{7,40}|v[0-9a-z\.\-]+)$ ]]; then
        printerr "Version of ${project} should be either a valid git commit hash or in the form v1.2.3: ${commit_hash}"
        errors=$((errors+1))
    fi
}

function validate_release_fields() {
    local errors=0

    _validate 'version'
    _validate 'name'
    _validate 'release-notes'
    _validate 'status'
    _validate 'components'

    case "${release['status']}" in
    shipyard)
        _validate_component "shipyard"
        ;;
    admiral)
        _validate_component "admiral"
        ;;
    projects)
        for project in ${OPERATOR_CONSUMES[*]}; do
            _validate_component "${project}"
        done
        ;;
    released)
        for project in ${PROJECTS[*]}; do
            _validate_component "${project}"
        done
        ;;
    *)
        printerr "Status '${release['status']}' should be one of: 'shipyard', 'admiral', 'projects' or 'released'."
        return 2
        ;;
    esac

    if [[ $errors -gt 0 ]]; then
        printerr "Found ${errors} errors in the file"
        return 1
    fi
}

function validate_admiral_consumers() {
    local expected_version="$1"
    for project in ${ADMIRAL_CONSUMERS[*]}; do
        local actual_version=$(grep admiral "projects/${project}/go.mod" | cut -f2 -d' ')
        if [[ "${expected_version}" != "${actual_version}" ]]; then
            printerr "Expected Admiral version ${expected_version} but found ${actual_version} in ${project}"
            return 1
        fi
    done
}

function validate_shipyard_consumers() {
    local expected_version="$1"
    for project in ${SHIPYARD_CONSUMERS[*]}; do
        local actual_version=$(head -1 "projects/${project}/Dockerfile.dapper" | cut -f2 -d':')
        if [[ "${expected_version}" != "${actual_version}" ]]; then
            printerr "Expected Shipyard version ${expected_version} but found ${actual_version} in ${project}"
            return 1
        fi
    done
}

function validate_not_released() {
    local project="${1:-${project}}"

    if _git rev-parse "${release['version']}" >/dev/null 2>&1; then
        printerr "'${project}' is already released with version '${release['version']}'."
        return 1
    fi
}

function validate_release() {
    validate_release_fields

    local version=${release['version']}
    if ! git check-ref-format "refs/tags/${version}"; then
        printerr "Version ${version@Q} is not a valid tag name"
        return 1
    fi

    local pre_release="${release['pre-release']}"
    if [[ "$pre_release" = "true" ]] && [[ ! "$version" =~ -[0-9a-z\.]+$ ]]; then
        printerr "Version ${version@Q} should have a hyphen followed by identifiers as it's marked as pre-release"
        return 1
    fi

    if [[ "$pre_release" != "true" ]] && [[ "$version" =~ - ]]; then
        printerr "Version ${version@Q} should not have a hyphen as it isn't marked as pre-release"
        return 1
    fi

    case "${release['status']}" in
    shipyard)
        local project=shipyard
        clone_repo
        validate_not_released
        ;;
    admiral)
        local project=admiral
        clone_repo
        validate_not_released
        ;;
    projects)
        for project in ${OPERATOR_CONSUMES[*]}; do
            clone_repo
            validate_not_released
        done
        ;;
    released)
        for project in ${PROJECTS[*]}; do
            clone_repo
        done

        validate_not_released submariner-operator
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
