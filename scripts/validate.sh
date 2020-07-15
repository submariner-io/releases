#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/yaml_funcs

function validate_file_fields() {
    local missing=0

    function _validate() {
        local key=$1
        validate_value $file $key || missing=$((missing+1))
    }

    _validate 'version'
    _validate 'name'
    _validate 'release-notes'
    _validate 'components'
    _validate 'components.admiral'
    _validate 'components.lighthouse'
    _validate 'components.shipyard'
    _validate 'components.submariner'
    _validate 'components.submariner-charts'
    _validate 'components.submariner-operator'

    if [[ $missing -gt 0 ]]; then
        printerr "Missing ${missing} fields"
        return 1
    fi
}

function validate_file() {
    validate_file_fields

    version=$(get_value $file 'version')
    if ! git check-ref-format "refs/tags/${version}"; then
        printerr "Version ${version@Q} is not a valid tag name"
        return 1
    fi
}

for file in $(find releases -type f); do
    validate_file $file
done
