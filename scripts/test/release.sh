#!/usr/bin/env bash

set -e

source "${DAPPER_SOURCE}/scripts/lib/utils"

### General Functions ###

function exit_error() {
    echo "--------- Captured output ---------"
    echo "${output}"
    echo "-----------------------------------"
    echo "ERROR: $*"
    exit 1
}

function print_test() {
    echo "TEST: Running 'make release' - $*"
}

function reset_git() {
    git checkout -- releases/*
    git reset --keep "${base_commit}" > /dev/null
}

function make_release() {
    declare -g output

    output=$(make release "$1" dryrun=true 2>&1)

    return "$?"
}

function expect_in_file() {
    local expected="^${1}$"
    local file="releases/v${2:-${version}}.yaml"

    if ! grep -e "${expected}" "${file}" > /dev/null; then
        echo "--------- ${file} ---------"
        cat "${file}"
        echo "---------------------------"
        exit_error "Release file ${file} missing expected content: ${expected}"
    fi
}

### Testing Functions ###

function test_semver_faulty() {
    print_test "faulty version '$1'"
    if make_release "VERSION=$1"; then
        exit_error "Running 'make release' should've failed due to faulty version $1"
    fi

    if ! grep -e "ERROR:.*${1}" - <<<"${output}" > /dev/null; then
        exit_error "Running 'make release' should've failed with output indicating the version $1"
    fi
}

function _test_release_step() {
    local version="$1"
    local status="$2"

    print_test "version '${version}' expecting status '${status}'"
    if ! make_release "VERSION=${version}"; then
        exit_error "Running 'make release' failed for version '${version}'"
    fi

    expect_in_file "version: v${version}"
    expect_in_file "status: ${status}"
}

function test_release() {
    local version="$1"
    local status="$2"
    local expected_fields=("${@:3}")

    print_test "entire release process for version ${version}"
    _test_release_step "${version}" "${status}"

    for field in "${expected_fields[@]}"; do
        expect_in_file "${field}"
    done

    # Since the branch is expected to exist, the script will fail, so remove it for testing
    [[ "${status}" == 'branch' ]] && sed -i '/^branch:.*/d' "releases/v${version}.yaml"

    while [[ -n "${NEXT_STATUS[${status}]}" ]]; do
        status="${NEXT_STATUS[${status}]}"
        _test_release_step "${version}" "${status}"
    done

    # Run final step again to make sure it stays put
    _test_release_step "${version}" "${status}"
}

### Main ###

base_commit=$(git rev-parse HEAD)
trap reset_git EXIT

print_test 'no version argument'
if make_release; then
    exit_error 'should fail when no VERSION is given'
fi

faulty_versions=( '' '1' '1.2' 'a.2.3' '1.a.3' '1.2.a' '01.2.3' '1.02.3' '1.2.03' '1.2.3-?')
for version in "${faulty_versions[@]}"; do
    test_semver_faulty "$version"
done

test_release '100.0.0' 'shipyard'
test_release '100.0.1' 'shipyard'
test_release '100.0.0-rc0' 'branch' 'pre-release: true'
test_release '100.0.0-rc1' 'shipyard' 'pre-release: true'
test_release '100.0.1-rc1' 'shipyard' 'pre-release: true'

# Test with an existing known branch
test_release '0.9.100' 'shipyard' 'branch: release-0.9'
test_release '0.9.100-rc1' 'shipyard' 'branch: release-0.9' 'pre-release: true'
