#!/usr/bin/env bash

set -e

# Always run on "main" org and not on forks that can be stale
export GITHUB_REPOSITORY_OWNER=submariner-io

source "${DAPPER_SOURCE}/scripts/lib/utils"
source "${DAPPER_SOURCE}/scripts/test/utils"

### Testing Functions ###

function _test_release_step() {
    print_test "Entire release process for version ${VERSION@Q} - current status ${status@Q}"

    _make release VERSION="${VERSION}" || exit_error "Running 'make release' failed"
    _make validate || exit_error "Running 'make validate' failed"
    _make do-release || exit_error "Running 'make do-release' failed"
}

### Main ###

base_commit=$(git rev-parse HEAD)
trap reset_git EXIT

status="shipyard"
extract_semver "${VERSION}"
[[ "${semver['pre']}" != "rc0" ]] || status="branch"

_test_release_step
sanitize_branch

while [[ -n "${NEXT_STATUS[${status}]}" ]]; do
    status="${NEXT_STATUS[${status}]}"
    _test_release_step
done

