#!/usr/bin/env bash

set -e

# shellcheck source=scripts/lib/utils
. "${DAPPER_SOURCE}/scripts/lib/utils"
. "${SCRIPTS_DIR}/lib/debug_functions"
. "${SCRIPTS_DIR}/lib/utils"

determine_target_release
declare_kubeconfig

# TODO: Add bask service-discovery tests once theyre stable
subctl verify --only "connectivity" --submariner-namespace "${SUBM_NS}" --verbose --connection-timeout 20 --connection-attempts 4 \
    "${KUBECONFIGS_DIR}/kind-config-cluster1" \
    "${KUBECONFIGS_DIR}/kind-config-cluster2"
