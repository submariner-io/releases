#!/usr/bin/env bash

set -e

source ${SCRIPTS_DIR}/lib/utils
source ${DAPPER_SOURCE}/scripts/lib/utils

file=$(readlink -f releases/target)
read_release_file

export VERSION="${release["components.submariner-operator"]}"
curl -Ls https://get.submariner.io | bash

ln -f -s /root/.local/bin/subctl /go/bin/subctl
subctl version
