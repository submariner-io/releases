#!/usr/bin/env bash

set -e

# Always run on "main" org and not on forks that can be stale
export ORG=submariner-io

source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${DAPPER_SOURCE}/scripts/test/utils"

### Testing Functions ###

function _test_release_step() {
    print_test "Entire release process for version ${VERSION@Q} - current status ${status@Q}"

    expect_success_running_make release VERSION="${VERSION}"
    expect_success_running_make validate
    expect_success_running_make do-release
}

### Main ###

prepare_test_repo
status="shipyard"
extract_semver "${VERSION}"
[[ "${semver['pre']}" != "rc0" ]] || status="branch"

_test_release_step
sanitize_branch

while [[ -n "${NEXT_STATUS[${status}]}" ]]; do
    status="${NEXT_STATUS[${status}]}"
    _test_release_step
done

