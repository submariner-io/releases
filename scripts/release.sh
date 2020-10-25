#!/usr/bin/env bash

set -e

source ${DAPPER_SOURCE}/scripts/lib/image_defs
source ${DAPPER_SOURCE}/scripts/lib/utils

file=$(readlink -f releases/target)
read_release_file

gh config set prompt disabled
gh release create "${release['version']}" projects/submariner-operator/dist/subctl-* --title "${release['name']}" --notes "${release['release-notes']}"

# Creating a local tag so that images are uploaded with it
git tag -f "${release['version']}"

export GITHUB_TOKEN="${RELEASE_TOKEN}"

origin_url=$(git config --get remote.origin.url)
if [[ "$origin_url" =~ ^https:.* ]]; then
    release_repo=$(echo "$origin_url" | cut -f 4 -d'/')
elif [[ "$origin_url" =~ ^git@.* ]]; then
    release_repo=$(echo "$origin_url" | cut -f 4- -d'/' | cut -f 1 -d '.')
else
    printerr "Can't parse origin URL to extract origin repo: ${origin_url}"
    exit 1
fi

errors=0
for project in ${PROJECTS[*]}; do
    clone_repo
    commit_ref=$(_git rev-parse --verify HEAD)
    gh release create "${release['version']}" --title "${release['name']}" --notes "${release['release-notes']}" --repo "${release_repo}/${project}" --target "$commit_ref" || errors=$((errors+1))
done

if [[ $errors > 0 ]]; then
    printerr "Failed to create release on ${errors} projects."
    exit 1
fi

images=""
for project in ${PROJECTS[*]}; do
    for image in ${project_images[${project}]}; do
        images+=" $image"
    done
done

make release RELEASE_ARGS="$images --tag ${release['version']}"

