#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

if [ -z "${1:-}" ]; then
    echo -e "${RED}Usage: bash teardown.sh <PROJECT_ID>${RESET}"
    exit 1
fi

PROJECT_ID="$1"

echo -e "Fetching active workload identity pools for project: ${CYAN}$PROJECT_ID${RESET}"
echo ""

mapfile -t POOL_IDS < <(gcloud iam workload-identity-pools list \
    --project="$PROJECT_ID" \
    --location="global" \
    --filter="state=ACTIVE" \
    --format="value(name.basename())")

if [ ${#POOL_IDS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No active workload identity pools found in project $PROJECT_ID.${RESET}"
    exit 0
fi

echo -e "${BOLD}Available Workload Identity Pools:${RESET}"
for i in "${!POOL_IDS[@]}"; do
    echo -e "  ${CYAN}$((i+1)))${RESET} ${POOL_IDS[$i]}"
done
echo ""

read -r -p "Select a pool to tear down (1-${#POOL_IDS[@]}): " SELECTION
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#POOL_IDS[@]}" ]; then
    echo -e "${RED}Invalid selection.${RESET}"
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
echo -e "${BOLD}The following resources will be deleted:${RESET}"
echo -e "  ${RED}-${RESET} Workload Identity Pool: ${CYAN}$POOL_ID${RESET} ${DIM}(and all its OIDC providers)${RESET}"
if [ -n "$IAM_BINDINGS" ]; then
    echo -e "  ${RED}-${RESET} IAM bindings:"
    while IFS= read -r binding; do
        ROLE="${binding%% *}"
        MEMBER="${binding#* }"
        echo -e "      ${DIM}$ROLE${RESET} -> ${CYAN}$MEMBER${RESET}"
    done <<< "$IAM_BINDINGS"
fi
echo ""

read -r -p "Proceed with teardown? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Aborted.${RESET}"
    exit 0
fi

if [ -n "$IAM_BINDINGS" ]; then
    echo -e "Removing IAM bindings..."
    while IFS= read -r binding; do
        ROLE="${binding%% *}"
        MEMBER="${binding#* }"
        gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
            --quiet \
            --role="$ROLE" \
            --member="$MEMBER"
    done <<< "$IAM_BINDINGS"
fi

echo -e "Deleting Workload Identity Pool: ${CYAN}$POOL_ID${RESET}..."
gcloud iam workload-identity-pools delete "$POOL_ID" \
    --project="$PROJECT_ID" \
    --location="global" \
    --quiet

echo ""
echo -e "${GREEN}${BOLD}Teardown complete!${RESET}"
