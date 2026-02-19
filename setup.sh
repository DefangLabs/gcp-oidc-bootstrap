#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

PROJECT_ID="$1"

if [ -n "${2:-}" ]; then
    GITHUB_REPO="$2"
else
    # Extract the --print_file value from cloudshell_open command in history
    PRINT_FILE=$(cat ~/.bash_history | grep cloudshell_open | grep -oP '(?<=--print_file[=\s])\S+' | tail -1 | tr -d '"')

    if [ -z "$PRINT_FILE" ]; then
        echo -e "${YELLOW}Could not detect GitHub repository from Cloud Shell history.${RESET}"
        read -r -p "Enter the GitHub repository (e.g. owner/repo): " PRINT_FILE
        if [ -z "$PRINT_FILE" ]; then
            echo -e "${RED}No GitHub repository provided, exiting.${RESET}"
            exit 1
        fi
    fi
    GITHUB_REPO="$PRINT_FILE"
fi
GITHUB_BRANCH="main"

SAFE_REPO_NAME=$(echo "$GITHUB_REPO" | tr '[:upper:]' '[:lower:]' | tr '/_' '-')
POOL_NAME="${SAFE_REPO_NAME:0:26}-pool"
PROVIDER_NAME="${SAFE_REPO_NAME:0:23}-provider"

echo ""
echo -e "${BOLD}About to set up Workload Identity Federation with the following configuration:${RESET}"
echo -e "  ${DIM}Project ID:            ${RESET} ${CYAN}$PROJECT_ID${RESET}"
echo -e "  ${DIM}GitHub repo:           ${RESET} ${CYAN}$GITHUB_REPO${RESET}"
echo -e "  ${DIM}Branch:                ${RESET} ${CYAN}$GITHUB_BRANCH${RESET}"
echo -e "  ${DIM}Workload Identity Pool:${RESET} ${CYAN}$POOL_NAME${RESET}"
echo -e "  ${DIM}OIDC Provider:         ${RESET} ${CYAN}$PROVIDER_NAME${RESET}"
echo ""
read -r -p "Proceed? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Aborted.${RESET}"
    echo -e "To set a custom GitHub repository, pass it as the second argument:"
    echo -e "  ${DIM}bash setup.sh $PROJECT_ID <owner/repo>${RESET}"
    exit 0
fi

POOL_STATE=$(gcloud iam workload-identity-pools describe "$POOL_NAME" \
    --project="$PROJECT_ID" --location="global" \
    --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

if [ "$POOL_STATE" = "NOT_FOUND" ]; then
    gcloud iam workload-identity-pools create "$POOL_NAME" \
        --project="$PROJECT_ID" \
        --location="global" \
        --display-name="GitHub Actions Pool"
elif [ "$POOL_STATE" = "DELETED" ]; then
    echo -e "${YELLOW}Workload Identity Pool $POOL_NAME is deleted, undeleting...${RESET}"
    gcloud iam workload-identity-pools undelete "$POOL_NAME" \
        --project="$PROJECT_ID" \
        --location="global"
else
    echo -e "${DIM}Workload Identity Pool $POOL_NAME already exists, skipping${RESET}"
fi

PROVIDER_STATE=$(gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" \
    --project="$PROJECT_ID" --location="global" --workload-identity-pool="$POOL_NAME" \
    --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

if [ "$PROVIDER_STATE" = "NOT_FOUND" ]; then
    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
        --project="$PROJECT_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_NAME" \
        --display-name="GitHub Actions Provider" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
        --attribute-condition="assertion.repository == '${GITHUB_REPO}'"
elif [ "$PROVIDER_STATE" = "DELETED" ]; then
    echo -e "${YELLOW}OIDC Provider $PROVIDER_NAME is deleted, undeleting...${RESET}"
    gcloud iam workload-identity-pools providers undelete "$PROVIDER_NAME" \
        --project="$PROJECT_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_NAME"
    echo -e "${YELLOW}Updating provider config to ensure it is current...${RESET}"
    gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_NAME" \
        --project="$PROJECT_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_NAME" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
        --attribute-condition="assertion.repository == '${GITHUB_REPO}'"
else
    echo -e "${DIM}OIDC Provider $PROVIDER_NAME already exists, skipping${RESET}"
fi

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
PRINCIPAL="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_NAME/attribute.repository/$GITHUB_REPO"

# Wait a bit to ensure the provider is fully propagated
sleep 10

EXISTS=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --format="json(bindings)" | \
    jq --arg role "roles/admin" --arg member "$PRINCIPAL" \
        '.bindings[] | select(.role==$role) | .members[] | select(.==$member)' | wc -l)

if [ "$EXISTS" -eq 0 ]; then
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --quiet \
        --role="roles/admin" \
        --member="$PRINCIPAL"
else
    echo -e "${DIM}IAM binding for $GITHUB_REPO already exists, skipping${RESET}"
fi

echo ""
echo -e "${GREEN}${BOLD}Workload Identity setup complete!${RESET}"
echo ""
echo -e "To tear down this setup, run:"
echo -e "  ${DIM}bash teardown.sh $PROJECT_ID${RESET}"
