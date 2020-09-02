#!/usr/bin/env bash

set -e

source ${SCRIPTS_DIR}/lib/utils

/root/.local/bin/subctl verify --only "connectivity,service-discovery" --submariner-namespace ${SUBM_NS} --verbose --connection-timeout 20 --connection-attempts 4 \
    ${KUBECONFIGS_DIR}/kind-config-cluster1 \
    ${KUBECONFIGS_DIR}/kind-config-cluster2
