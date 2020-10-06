#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/utils

file=$(readlink -f releases/target)
read_release_file

gh config set prompt disabled
gh release create "${release['version']}" --title "${release['name']}" --notes "${release['release-notes']}"

export GITHUB_TOKEN="${RELEASE_TOKEN}"

origin_url=$(git config --get remote.origin.url)
if [[ "$origin_url" =~ ^https:.* ]]; then
    release_repo=$(echo "$origin_url" | cut -f 4 -d'/')
elif [[ "$origin_url" =~ ^git@.* ]]; then
    release_repo=$(echo "$origin_url" | cut -f 4- -d'/' | cut -f 1 -d '.')
else
    echo "ERROR: Can't parse origin URL to extract origin repo: ${origin_url}"
    exit 1
fi

for project in ${PROJECTS[*]}; do
    gh release create "${release['version']}" --title "${release['name']}" --notes "${release['release-notes']}" --repo "${release_repo}/${project}" --target "${release["components.${project}"]}"
done
