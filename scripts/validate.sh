#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/yaml_funcs

readonly PROJECTS=(admiral lighthouse shipyard submariner submariner-charts submariner-operator)
readonly ADMIRAL_CONSUMERS=(lighthouse submariner)
readonly SHIPYARD_CONSUMERS=(admiral lighthouse submariner submariner-operator)

function validate_file_fields() {
    local missing=0

    function _validate() {
        local key=$1
        validate_value $file $key || missing=$((missing+1))
        release[$key]=$(get_value $file $key)
    }

    _validate 'version'
    _validate 'name'
    _validate 'release-notes'
    _validate 'components'
    for project in ${PROJECTS[*]}; do
        _validate "components.${project}"
    done

    if [[ $missing -gt 0 ]]; then
        printerr "Missing ${missing} fields"
        return 1
    fi
}

function validate_admiral_consumers() {
    local expected_version="$1"
    for project in ${ADMIRAL_CONSUMERS[*]}; do
        local actual_version=$(grep admiral "${project}/go.mod" | cut -f2 -d' ')
        if [[ "${expected_version}" != "${actual_version}" ]]; then
            printerr "Expected Admiral version ${expected_version} but found ${actual_version} in ${project}"
            return 1
        fi
    done
}

function validate_shipyard_consumers() {
    local expected_version="$1"
    for project in ${SHIPYARD_CONSUMERS[*]}; do
        local actual_version=$(head -1 "${project}/Dockerfile.dapper" | cut -f2 -d':')
        if [[ "${expected_version}" != "${actual_version}" ]]; then
            printerr "Expected Shipyard version ${expected_version} but found ${actual_version} in ${project}"
            return 1
        fi
    done
}

function validate_file() {
    declare -A release
    validate_file_fields

    version=${release['version']}
    if ! git check-ref-format "refs/tags/${version}"; then
        printerr "Version ${version@Q} is not a valid tag name"
        return 1
    fi

    rm -rf projects
    mkdir -p projects
    pushd projects
    for project in ${PROJECTS[*]}; do
        mkdir -p "${project}"
        git init "${project}"
        pushd "${project}"
        git remote add origin "https://github.com/submariner-io/${project}"
        git fetch --no-tags --prune --progress --no-recurse-submodules --depth=1 origin "+${release["components.${project}"]}:refs/remotes/origin/master"
        git checkout --progress --force -B master refs/remotes/origin/master
        popd
    done

    validate_admiral_consumers "${release["components.admiral"]}"
    validate_shipyard_consumers "${release["components.shipyard"]#v}"
    popd
    rm -rf projects
}

for file in $(find releases -type f); do
    validate_file $file
done
