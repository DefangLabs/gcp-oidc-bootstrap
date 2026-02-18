#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$1"

if [ -n "${2:-}" ]; then
    GITHUB_REPO="$2"
else
    # Extract the --print_file value from cloudshell_open command in history
    PRINT_FILE=$(cat ~/.bash_history | grep cloudshell_open | grep -oP '(?<=--print_file[=\s])\S+' | tail -1 | tr -d '"')

    if [ -z "$PRINT_FILE" ]; then
        echo "Could not detect GitHub repository from Cloud Shell history."
        read -r -p "Enter the GitHub repository (e.g. owner/repo): " PRINT_FILE
        if [ -z "$PRINT_FILE" ]; then
            echo "No GitHub repository provided, exiting."
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
echo "About to set up Workload Identity Federation with the following configuration:"
echo "  Project ID:             $PROJECT_ID"
echo "  GitHub repo:            $GITHUB_REPO"
echo "  Branch:                 $GITHUB_BRANCH"
echo "  Workload Identity Pool: $POOL_NAME"
echo "  OIDC Provider:          $PROVIDER_NAME"
echo ""
read -r -p "Proceed? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    echo "To set a custom GitHub repository, pass it as the second argument:"
    echo "  bash setup.sh $PROJECT_ID <owner/repo>"
    exit 0
fi

if ! gcloud iam workload-identity-pools describe "$POOL_NAME" --project="$PROJECT_ID" --location="global" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools create "$POOL_NAME" \
        --project="$PROJECT_ID" \
        --location="global" \
        --display-name="GitHub Actions Pool"
else
    echo "Workload Identity Pool $POOL_NAME already exists, skipping"
fi

if ! gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" \
        --project="$PROJECT_ID" --location="global" --workload-identity-pool="$POOL_NAME" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
        --project="$PROJECT_ID" \
        --location="global" \
        --workload-identity-pool="$POOL_NAME" \
        --display-name="GitHub Actions Provider" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
        --attribute-condition="assertion.repository == '${GITHUB_REPO}'"
else
    echo "OIDC Provider $PROVIDER_NAME already exists, skipping"
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
    echo "IAM binding for $GITHUB_REPO already exists, skipping"
fi

echo "Workload Identity setup complete!"
echo ""
echo "To tear down this setup, run:"
echo "  bash teardown.sh $PROJECT_ID"
