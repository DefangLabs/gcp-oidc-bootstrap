# Setup Workload Identity Federation

Welcome! This will set up a Workload Identity Federation trust relationship between GitHub and GCP. This will allow you to authenticate to GCP using your GitHub credentials, without needing to manage service account keys.

## Step 1: Run the Setup Script
Click the icon below to run the setup script. It will prompt you for your GitHub repo name and handle the rest.

<walkthrough-project-setup></walkthrough-project-setup>

```bash
bash setup.sh <walkthrough-project-id/>
