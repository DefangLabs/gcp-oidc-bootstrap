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
        read -r -p "Enter the GitHub access path (e.g. owner/repo/branch/main or owner): " PRINT_FILE
        if [ -z "$PRINT_FILE" ]; then
            echo -e "${RED}No GitHub repository provided, exiting.${RESET}"
            exit 1
        fi
    fi
    GITHUB_REPO="$PRINT_FILE"
fi

# Parse the 4-segment format: {org}/{repo}/{refType}/{refPattern}
# Empty segments are treated as wildcards (*)
IFS='/' read -r -a _PARTS <<< "$GITHUB_REPO"
ORG="${_PARTS[0]:-}"
REPO="${_PARTS[1]:-}"
REF_TYPE="${_PARTS[2]:-}"
REF_PATTERN="${_PARTS[3]:-}"
unset _PARTS

[ -z "$REPO" ] && REPO="*"
[ -z "$REF_TYPE" ] && REF_TYPE="all"
[ -z "$REF_PATTERN" ] && REF_PATTERN="*"

# Build the repository condition (org-level or specific repo)
if [ "$REPO" = "*" ]; then
    REPO_CONDITION="assertion.repository_owner == '${ORG}'"
else
    REPO_CONDITION="assertion.repository == '${ORG}/${REPO}'"
fi

# Build the full attribute condition based on refType
case "$REF_TYPE" in
    branch)
        if [ "$REF_PATTERN" = "*" ]; then
            ATTR_CONDITION="$REPO_CONDITION"
        else
            ATTR_CONDITION="${REPO_CONDITION} && assertion.ref == 'refs/heads/${REF_PATTERN}'"
        fi
        ;;
    environment)
        if [ "$REF_PATTERN" = "*" ]; then
            ATTR_CONDITION="$REPO_CONDITION"
        else
            ATTR_CONDITION="${REPO_CONDITION} && assertion.environment == '${REF_PATTERN}'"
        fi
        ;;
    *)  # all or unrecognized
        ATTR_CONDITION="$REPO_CONDITION"
        ;;
esac

# Build safe names for pool/provider (no wildcards or special chars)
if [ "$REPO" = "*" ]; then
    SAFE_REPO_NAME=$(echo "$ORG" | tr '[:upper:]' '[:lower:]' | tr '/_' '-')
else
    SAFE_REPO_NAME=$(echo "$ORG/$REPO" | tr '[:upper:]' '[:lower:]' | tr '/_' '-')
fi
POOL_NAME="${SAFE_REPO_NAME:0:26}-pool"
PROVIDER_NAME="${SAFE_REPO_NAME:0:23}-provider"

echo ""
echo -e "${BOLD}About to set up Workload Identity Federation with the following configuration:${RESET}"
echo -e "  ${DIM}Project ID:            ${RESET} ${CYAN}$PROJECT_ID${RESET}"
echo -e "  ${DIM}GitHub org:            ${RESET} ${CYAN}$ORG${RESET}"
echo -e "  ${DIM}GitHub repo:           ${RESET} ${CYAN}$REPO${RESET}"
echo -e "  ${DIM}Ref type:              ${RESET} ${CYAN}$REF_TYPE${RESET}"
echo -e "  ${DIM}Ref pattern:           ${RESET} ${CYAN}$REF_PATTERN${RESET}"
echo -e "  ${DIM}Workload Identity Pool:${RESET} ${CYAN}$POOL_NAME${RESET}"
echo -e "  ${DIM}OIDC Provider:         ${RESET} ${CYAN}$PROVIDER_NAME${RESET}"
echo ""
read -r -p "Proceed? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Aborted.${RESET}"
    echo -e "To set a custom GitHub repository, pass it as the second argument:"
    echo -e "  ${DIM}bash setup.sh $PROJECT_ID <owner/repo/refType/refPattern>${RESET}"
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
        --attribute-condition="${ATTR_CONDITION}"
else 
    if [ "$PROVIDER_STATE" = "DELETED" ]; then
        echo -e "${YELLOW}OIDC Provider $PROVIDER_NAME is deleted, undeleting...${RESET}"
        gcloud iam workload-identity-pools providers undelete "$PROVIDER_NAME" \
            --project="$PROJECT_ID" \
            --location="global" \
            --workload-identity-pool="$POOL_NAME"
    fi
    echo -e "${YELLOW}Updating provider config to ensure it is current...${RESET}"
    gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_NAME" \
        --project="$PROJECT_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_NAME" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
        --attribute-condition="${ATTR_CONDITION}"
fi

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
if [ "$REPO" = "*" ]; then
    PRINCIPAL="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_NAME/attribute.repository_owner/$ORG"
else
    PRINCIPAL="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_NAME/attribute.repository/$ORG/$REPO"
fi

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
    echo -e "${DIM}IAM binding for $ORG/$REPO already exists, skipping${RESET}"
fi

echo ""
echo -e "${GREEN}${BOLD}Workload Identity setup complete!${RESET}"
echo ""
echo -e "To tear down this setup, run:"
echo -e "  ${DIM}bash teardown.sh $PROJECT_ID${RESET}"
