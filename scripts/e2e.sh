#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/utils
source ${SCRIPTS_DIR}/lib/debug_functions
source ${SCRIPTS_DIR}/lib/utils

determine_target_release
declare_kubeconfig

# TODO: Add bask service-discovery tests once theyre stable
subctl verify --only "connectivity" --submariner-namespace ${SUBM_NS} --verbose --connection-timeout 20 --connection-attempts 4 \
    ${KUBECONFIGS_DIR}/kind-config-cluster1 \
    ${KUBECONFIGS_DIR}/kind-config-cluster2
