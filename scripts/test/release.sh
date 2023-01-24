#!/usr/bin/env bash

set -e

# Always run on "main" org and not on forks that can be stale
export ORG=submariner-io

source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${DAPPER_SOURCE}/scripts/test/utils"

### General Functions ###

function expect_in_file() {
    local expected="^${1}$"
    local file="${file:-releases/v${version}.yaml}"

    if ! grep -E "${expected}" "${file}" > /dev/null; then
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

    start_test "'make release' - stable branch '${version}'"
    expect_failure_running_make release VERSION="$version"
    expect_make_output_to_contain "ERROR:.* must be based on .*${branch}"
}

function test_semver_faulty() {
    start_test "'make release' - faulty version '$1'"
    expect_failure_running_make release "VERSION=$1"
    expect_make_output_to_contain "ERROR: .*${1}.* not a valid semantic version"
}

function test_update_hashes() {
    local status="$1"
    local file='releases/vtest-update-hashes.yaml'
    shift
    start_test "'make release' - update hashes for status '$status'"

    # Generate a fake commit that will be updated
    yq -n ".version=\"v0.100.0-m0\" | .status=\"${status}\"" > "$file"
    git add "$file"
    git commit -a -m "Testing update hashes"

    expect_success_running_make release UPDATE=yes
    expect_in_file "status: ${status}"
    for component; do
        expect_in_file "  ${component}: [0-9a-f]{40}"
    done
}

function _test_release_step() {
    local version="$1"
    local status="$2"

    start_test "'make release' - version '${version}' expecting status '${status}'"
    expect_success_running_make release "VERSION=${version}"

    expect_in_file "version: v${version}"
    expect_in_file "status: ${status}"
}

function test_release() {
    local version="$1"
    local status="$2"
    local branch="$3"

    _test_release_step "${version}" "${status}"

    if [[ -n "$branch" ]]; then
        expect_in_file "branch: ${branch}"

        # Since the branch is expected to exist, the script will fail, so remove it for testing
        VERSION="${version}" sanitize_branch
    fi

    while [[ -n "${NEXT_STATUS[${status}]}" ]]; do
        status="${NEXT_STATUS[${status}]}"
        _test_release_step "${version}" "${status}"
    done

    # Run final step again to make sure it stays put
    _test_release_step "${version}" "${status}"
}

### Main ###

prepare_test_repo

start_test "'make release' - no version argument"
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
test_release '100.0.0-m0' 'shipyard'
test_release '100.0.0-rc0' 'branch' 'release-100.0'

# Reset test repo for further testing
cd "${DAPPER_SOURCE}"
prepare_test_repo

# Test updating release hashes
expect_success_running_make release UPDATE=yes
expect_make_output_to_contain "Couldn't detect a target release file, skipping."
test_update_hashes shipyard shipyard
test_update_hashes admiral admiral
test_update_hashes projects "${PROJECTS_PROJECTS[@]}"
test_update_hashes installers "${INSTALLER_PROJECTS[@]}"
test_update_hashes released subctl
