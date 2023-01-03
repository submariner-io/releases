#!/usr/bin/env bash

set -e

# Always run on "main" org and not on forks that can be stale
export ORG=submariner-io

source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${DAPPER_SOURCE}/scripts/test/utils"

### Testing Functions ###

function run_release() {

    # Generate an appropriate commit that will be picked up and processed by `do-release`
    yq -n ".version=\"${version}\" | .status=\"shipyard\"" > releases/vtest-do-release.yaml
    git add releases/vtest-do-release.yaml
    git commit -a -m "Testing do-release"

    start_test "Testing do-release for version ${version@Q}."
    expect_success_running_make do-release

    # Simulate the tag being created, for any operation that relies on it
    git tag -f "$version"
}

function expect_prerelease() {
    local expected="$1"
    expect_make_output_to_contain "gh release create ${version}.* --prerelease=${expected}"
}

function expect_image_tagging() {
    local expected="${1:-${BASE_BRANCH}-[[:xdigit:]]*}"
    expect_make_output_to_contain "skopeo copy .*/shipyard-dapper-base:${expected} .*/shipyard-dapper-base:${version#v}$"
}

function expect_latest() {
    local expected="$1"
    expect_make_output_to_contain "gh release create ${version}.* --latest=${expected}"
}

### Main ###

prepare_test_repo
git tag -f v99.0.0

# New version while "devel" is still not officially released should be latest
version=v99.0.1
run_release
expect_prerelease false
expect_latest true

version=v100.0.0-m0
run_release
expect_prerelease true
expect_latest false
expect_image_tagging

version=v100.0.0-rc0
run_release
expect_prerelease true
expect_latest false
expect_image_tagging

version=v100.0.0
run_release
expect_prerelease false
expect_latest true
expect_image_tagging 100.0.0-rc0

# New "stable" release shouldn't be marked as latest, as an even newer GA exists
version=v99.0.2
run_release
expect_prerelease false
expect_latest false

# New GA for latest "stable" release should be marked latest
version=v100.0.1
run_release
expect_prerelease false
expect_latest true
expect_image_tagging
