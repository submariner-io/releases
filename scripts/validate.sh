#!/usr/bin/env sh

set -e

source ${SCRIPTS_DIR}/lib/yaml_funcs

function validate_file() {
    local file=$1
    local errors=0

    function _validate() {
        local key=$1
        validate_value $file $key || errors=$((errors+1))
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

    if [[ $errors -gt 0 ]]; then
        printerr "Found ${errors} errors while validating ${file}."
        return 1
    fi
}

for file in $(find releases -type f); do
    validate_file $file
done
