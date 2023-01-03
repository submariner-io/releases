#!/usr/bin/env bash

set -e

# Always run on "main" org and not on forks that can be stale
export ORG=submariner-io

source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${DAPPER_SOURCE}/scripts/test/utils"

### Testing Functions ###

function test_prerelease() {
    local version="$1"
    local expected="$2"

    # Generate an appropriate commit that will be picked up and processed by `do-release`
    yq -n ".version=\"${version}\" | .status=\"shipyard\"" > releases/vtest-prerelease.yaml
    git add releases/vtest-prerelease.yaml
    git commit -a -m "Testing pre-release"

    start_test "Testing pre-release for version ${version@Q}, expecting it to be ${expected}."
    expect_success_running_make do-release
    expect_make_output_to_contain "gh release create ${version}.* --prerelease=${expected}"
}

### Main ###

prepare_test_repo
test_prerelease v100.0.0 false
test_prerelease v100.0.0-rc0 true
test_prerelease v100.0.0-m0 true

