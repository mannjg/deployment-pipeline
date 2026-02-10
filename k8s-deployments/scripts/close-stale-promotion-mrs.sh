#!/bin/bash
set -euo pipefail

: "${PROMO_ENCODED_PROJECT:?PROMO_ENCODED_PROJECT is required}"
: "${PROMO_TARGET:?PROMO_TARGET is required}"
: "${PROMO_PREFIX:?PROMO_PREFIX is required}"
: "${GITLAB_URL:?GITLAB_URL is required}"
: "${BUILD_URL:?BUILD_URL is required}"

STALE_MRS=$(./scripts/gitlab-api.sh GET \
    "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/merge_requests?state=opened&target_branch=${PROMO_TARGET}" \
    2>/dev/null | jq -r --arg prefix "${PROMO_PREFIX}${PROMO_TARGET}-" \
    '[.[] | select(.source_branch | startswith($prefix))] | .[] | "\(.iid) \(.source_branch)"')

if [ -z "${STALE_MRS}" ]; then
    echo "No stale promotion MRs found for ${PROMO_TARGET}"
    exit 0
fi

echo "${STALE_MRS}" | while read -r MR_IID MR_BRANCH; do
    [ -z "${MR_IID}" ] && continue
    echo "Closing stale promotion MR !${MR_IID} (branch: ${MR_BRANCH})"

    # Add comment explaining supersession
    ./scripts/gitlab-api.sh POST \
        "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/merge_requests/${MR_IID}/notes" \
        --data "{\"body\":\"Superseded by promotion from build ${BUILD_URL}\"}" \
        >/dev/null 2>&1 || echo "Warning: Could not add comment to MR !${MR_IID}"

    # Close the MR
    ./scripts/gitlab-api.sh PUT \
        "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/merge_requests/${MR_IID}" \
        --data '{"state_event":"close"}' \
        >/dev/null 2>&1 || echo "Warning: Could not close MR !${MR_IID}"

    # Delete the stale source branch
    ENCODED_BRANCH=$(echo "${MR_BRANCH}" | sed 's|/|%2F|g')
    ./scripts/gitlab-api.sh DELETE \
        "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/repository/branches/${ENCODED_BRANCH}" \
        >/dev/null 2>&1 || echo "Warning: Could not delete branch ${MR_BRANCH}"
done
