# GCP Workload Identity Federation OIDC bootstrap using Cloud Shell

This project bootstraps **Workload Identity Federation (OIDC)** between an OIDC provider (e.g. GitHub repository) and Google Cloud Platform (GCP) project. It allows applications with OIDC credentials (e.g. GitHub Actions workflows with GITHUB_TOKEN) to authenticate to GCP without needing long-lived service account keys.

## What it does

Running the setup will configure the following in your GCP project:

1. **Workload Identity Pool** — a pool scoped to your GitHub repository
2. **OIDC Provider** — maps GitHub Actions OIDC tokens (issued by `token.actions.githubusercontent.com`) to GCP identities
3. **IAM binding** — grants the GitHub repo's principal the `roles/admin` role on the GCP project

Once set up, GitHub Actions workflows in the target repository can exchange a short-lived OIDC token for GCP credentials using `google-github-actions/auth`, with no stored secrets required.

## Prerequisites

- A GCP project where you have Owner or sufficient IAM permissions
- The target GitHub repository (e.g. `DefangLabs/defang-mvp`)

## Usage
Setup a [Cloud shell](https://cloud.google.com/shell) tutorial link with this repo as the `cloudshell_git_repo`, and with `cloudshell_tutorial` pointing to `setup.md` and `cloudshell_print` set to the target GitHub repository. This will allow you to run the setup script interactively in Cloud Shell, with the target repo pre-filled.

The tutorial will prompt you to select a GCP project and then run:

```bash
bash setup.sh <YOUR_PROJECT_ID>
```

The script reads the target GitHub repository from the Cloud Shell invocation context (`cloudshell_print` parameter) and is idempotent — re-running it safely skips resources that already exist.

## Example link

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https%3A%2F%2Fgithub.com%2FDefangLabs%2Fgcp-oidc-bootstrap&show=terminal&cloudshell_tutorial=setup.md&cloudshell_print=DefangLabs/gcp-oidc-bootstrap)
