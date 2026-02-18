#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: bash teardown.sh <PROJECT_ID>"
    exit 1
fi

PROJECT_ID="$1"

echo "Fetching active workload identity pools for project: $PROJECT_ID"
echo ""

mapfile -t POOL_IDS < <(gcloud iam workload-identity-pools list \
    --project="$PROJECT_ID" \
    --location="global" \
    --filter="state=ACTIVE" \
    --format="value(name.basename())")

if [ ${#POOL_IDS[@]} -eq 0 ]; then
    echo "No active workload identity pools found in project $PROJECT_ID."
    exit 0
fi

echo "Available Workload Identity Pools:"
for i in "${!POOL_IDS[@]}"; do
    echo "  $((i+1))) ${POOL_IDS[$i]}"
done
echo ""

read -r -p "Select a pool to tear down (1-${#POOL_IDS[@]}): " SELECTION
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#POOL_IDS[@]}" ]; then
    echo "Invalid selection."
    exit 1
fi

POOL_ID="${POOL_IDS[$((SELECTION-1))]}"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
POOL_PRINCIPAL_PREFIX="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_ID/"

# Find IAM bindings associated with this pool
IAM_BINDINGS=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --format="json(bindings)" | \
    jq -r --arg prefix "$POOL_PRINCIPAL_PREFIX" \
        '.bindings[]? | .role as $role | .members[]? | select(startswith($prefix)) | "\($role) \(.)"')

echo ""
echo "The following resources will be deleted:"
echo "  - Workload Identity Pool: $POOL_ID (and all its OIDC providers)"
if [ -n "$IAM_BINDINGS" ]; then
    echo "  - IAM bindings:"
    while IFS= read -r binding; do
        ROLE="${binding%% *}"
        MEMBER="${binding#* }"
        echo "      $ROLE -> $MEMBER"
    done <<< "$IAM_BINDINGS"
fi
echo ""

read -r -p "Proceed with teardown? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

if [ -n "$IAM_BINDINGS" ]; then
    echo "Removing IAM bindings..."
    while IFS= read -r binding; do
        ROLE="${binding%% *}"
        MEMBER="${binding#* }"
        gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
            --quiet \
            --role="$ROLE" \
            --member="$MEMBER"
    done <<< "$IAM_BINDINGS"
fi

echo "Deleting Workload Identity Pool: $POOL_ID..."
gcloud iam workload-identity-pools delete "$POOL_ID" \
    --project="$PROJECT_ID" \
    --location="global" \
    --quiet

echo ""
echo "Teardown complete!"
