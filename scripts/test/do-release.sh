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
}

function expect_prerelease() {
    local expected="$1"
    expect_make_output_to_contain "gh release create ${version}.* --prerelease=${expected}"
}

function expect_image_tagging() {
    local expected="${1:-${BASE_BRANCH}-[[:xdigit:]]*}"
    expect_make_output_to_contain "skopeo copy .*/shipyard-dapper-base:${expected} .*/shipyard-dapper-base:${version#v}$"
}

### Main ###

prepare_test_repo
git tag -f v100.0.0-rc999

version=v100.0.0
run_release
expect_prerelease false
expect_image_tagging 100.0.0-rc999

version=v100.0.0-rc0
run_release
expect_prerelease true
expect_image_tagging

version=v100.0.0-m0
run_release
expect_prerelease true
expect_image_tagging

version=v100.0.1
run_release
expect_prerelease false
expect_image_tagging
