#!/usr/bin/env bash
# verify-images.sh — Verify quay.io images exist for a given release stage.
#
# Usage: verify-images.sh <org> <version> <stage> [release_file]
#   stage: shipyard | projects | installers | released
#   release_file: path to release YAML (required for z-release SHA lookups)
#
# Exit 0=all present, 1=any missing
set -euo pipefail

ORG="$1"
VERSION="$2"
STAGE="$3"
RELEASE_FILE="${4:-}"

IMAGE_TAG="${VERSION#v}"
PATCH=$(echo "$VERSION" | cut -d. -f3 | cut -d- -f1)
STABLE_BRANCH="release-$(echo "$VERSION" | cut -d. -f1-2)"
IMAGES_OK=true

check_image() {
    local image="$1"
    local tag="$2"
    if skopeo inspect --raw "docker://quay.io/submariner/${image}:${tag}" >/dev/null 2>&1; then
        echo "  OK  quay.io/submariner/${image}:${tag}"
    else
        echo "  MISSING  quay.io/submariner/${image}:${tag}"
        IMAGES_OK=false
    fi
}

case "$STAGE" in
    shipyard)
        echo "--- Verifying Shipyard images on quay.io ---"
        check_image "shipyard-dapper-base" "$IMAGE_TAG"
        ;;

    projects)
        echo "--- Verifying project images on quay.io ---"
        if [ "$PATCH" -gt 0 ]; then
            # z-release: images tagged release-X.Y-<12-char-commit>; use YAML component hashes
            if [ -z "$RELEASE_FILE" ] || [ ! -f "$RELEASE_FILE" ]; then
                echo "ERROR: Release file required for z-release image verification"
                exit 1
            fi
            SUBMARINER_SHA=$(grep "^  submariner:" "$RELEASE_FILE" | awk '{print $2}' | cut -c1-12)
            LIGHTHOUSE_SHA=$(grep "^  lighthouse:" "$RELEASE_FILE" | awk '{print $2}' | cut -c1-12)
            for IMAGE in submariner-gateway submariner-route-agent submariner-globalnet; do
                check_image "$IMAGE" "${STABLE_BRANCH}-${SUBMARINER_SHA}"
            done
            for IMAGE in lighthouse-agent lighthouse-coredns; do
                check_image "$IMAGE" "${STABLE_BRANCH}-${LIGHTHOUSE_SHA}"
            done
        else
            for IMAGE in submariner-gateway submariner-route-agent submariner-globalnet \
                         lighthouse-agent lighthouse-coredns; do
                check_image "$IMAGE" "$IMAGE_TAG"
            done
        fi
        ;;

    installers)
        echo "--- Verifying installer images on quay.io ---"
        if [ "$PATCH" -gt 0 ]; then
            # z-release: use YAML hash for operator; GitHub API for subctl
            if [ -z "$RELEASE_FILE" ] || [ ! -f "$RELEASE_FILE" ]; then
                echo "ERROR: Release file required for z-release image verification"
                exit 1
            fi
            OPERATOR_SHA=$(grep "^  submariner-operator:" "$RELEASE_FILE" | awk '{print $2}' | cut -c1-12)
            SUBCTL_SHA=$(gh api "repos/${ORG}/subctl/commits/${STABLE_BRANCH}" --jq '.sha' | cut -c1-12)
            check_image "submariner-operator" "${STABLE_BRANCH}-${OPERATOR_SHA}"
            check_image "subctl" "${STABLE_BRANCH}-${SUBCTL_SHA}"
        else
            for IMAGE in submariner-operator subctl; do
                check_image "$IMAGE" "$IMAGE_TAG"
            done
        fi
        ;;

    released)
        echo "--- Verifying all images on quay.io ---"
        for IMAGE in submariner-gateway submariner-route-agent submariner-globalnet \
                     lighthouse-agent lighthouse-coredns submariner-operator subctl; do
            check_image "$IMAGE" "$IMAGE_TAG"
        done
        ;;

    *)
        echo "ERROR: Unknown stage '$STAGE'. Expected: shipyard|projects|installers|released"
        exit 1
        ;;
esac

if [ "$IMAGES_OK" = false ]; then
    exit 1
fi
