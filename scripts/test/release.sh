#!/usr/bin/env bash

set -e

# Always run on "main" org and not on forks that can be stale
export ORG=submariner-io

source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${DAPPER_SOURCE}/scripts/test/utils"

### General Functions ###

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

function test_release_stable() {
    local suffix=$1
    git remote rm upstream_releases 2> /dev/null || :
    git remote add -f upstream_releases "https://github.com/${ORG}/releases.git" > /dev/null 2>&1

    local branch
    branch=$(git rev-parse --symbolic --remotes='upstream_releases/release-*' | \
                 grep -w -v "$BASE_BRANCH" | grep -w -o -m 1 'release-[0-9]*\.[0-9]*')
    local version=${branch#*-}.${suffix}

    print_test "Running 'make release' - stable branch '${version}'"
    expect_failure_running_make release VERSION="$version"
    expect_make_output_to_contain "ERROR:.* must be based on .*${branch}"
}

function test_semver_faulty() {
    print_test "Running 'make release' - faulty version '$1'"
    expect_failure_running_make release "VERSION=$1"
    expect_make_output_to_contain "ERROR: .*${1}.* not a valid semantic version"
}

function _test_release_step() {
    local version="$1"
    local status="$2"

    print_test "Running 'make release' - version '${version}' expecting status '${status}'"
    expect_success_running_make release "VERSION=${version}"

    expect_in_file "version: v${version}"
    expect_in_file "status: ${status}"
}

function test_release() {
    local version="$1"
    local status="$2"
    local expected_fields=("${@:3}")

    print_test "Running 'make release' - entire release process for version ${version}"
    _test_release_step "${version}" "${status}"

    for field in "${expected_fields[@]}"; do
        expect_in_file "${field}"
    done

    # Since the branch is expected to exist, the script will fail, so remove it for testing
    VERSION="${version}" sanitize_branch

    while [[ -n "${NEXT_STATUS[${status}]}" ]]; do
        status="${NEXT_STATUS[${status}]}"
        _test_release_step "${version}" "${status}"
    done

    # Run final step again to make sure it stays put
    _test_release_step "${version}" "${status}"
}

### Main ###

prepare_test_repo

print_test "Running 'make release' - no version argument"
expect_failure_running_make release
expect_make_output_to_contain "ERROR:.* not a valid semantic version"

faulty_versions=( '' '1' '1.2' 'a.2.3' '1.a.3' '1.2.a' '01.2.3' '1.02.3' '1.2.03' '1.2.3-?')
for version in "${faulty_versions[@]}"; do
    test_semver_faulty "$version"
done

# Test that stable branches are handled correctly
versions=('100' '100-rc0' '100-rc1')
for version in "${versions[@]}"; do
    test_release_stable "$version"
done

# Test with non-existing branches
# Only pre-releases are expected to work as we expect RCs or formal releases to happen on a branch (which must exist)
test_release '100.0.0-m0' 'shipyard' 'pre-release: true'
test_release '100.0.0-rc0' 'branch' 'branch: release-100.0' 'pre-release: true'
