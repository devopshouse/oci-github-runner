# OCI GitHub Runner: configuration and operations

Custom Docker image for GitHub Actions self-hosted runners, based on `myoung34/docker-github-actions-runner`, with the **OCI CLI** for use on **OCI Container Instances**.

[![Build and Publish](https://github.com/devopshouse/oci-github-runner/actions/workflows/build-and-publish.yml/badge.svg)](https://github.com/devopshouse/oci-github-runner/actions/workflows/build-and-publish.yml)
[![Check Runner Version](https://github.com/devopshouse/oci-github-runner/actions/workflows/check-runner-version.yml/badge.svg)](https://github.com/devopshouse/oci-github-runner/actions/workflows/check-runner-version.yml)

[Back to README](../README.md)

This guide retains the detailed setup instructions, startup flow, configuration examples, and development notes. Replace example OCIDs, names, regions, and URLs before use. Workflow examples assume an already registered runner and the credentials required by each service.

## Table of Contents

- [Overview](#overview)
- [Available Image](#available-image)
- [OCI Vault Integration](#oci-vault-integration)
- [Quick Start](#quick-start)
- [Automated Workflows](#automated-workflows)
- [Usage Examples](#usage-examples)
- [Development](#development)
- [Contributing](#contributing)

## Overview

Custom Docker image based on **`myoung34/docker-github-actions-runner`** with the **OCI CLI** for running GitHub Actions self-hosted runners on **OCI Container Instances**.

### Included Tools

#### Added by this custom image:

- **oci-cli** - Oracle Cloud Infrastructure CLI (to manage OCI resources)
- **ansible** - Configuration automation
- **kubectl** - Kubernetes CLI
- **helm** - Kubernetes package manager

#### Inherited from the base image (myoung34/github-runner):

- **docker** - Docker CLI and daemon
- **docker-compose** - Container orchestration
- **git** - Version control system
- **curl, wget** - Download tools
- **jq** - JSON processor
- **yq** - YAML processor
- **build-essential** - Build tools (gcc, make, etc.)
- **python3** - Python 3 with pip

### Features

- Based on the **myoung34/github-runner** image
- **OCI CLI** preinstalled for Oracle Cloud integration
- `pre-entrypoint.sh` script for custom setup
- Automatic updates through GitHub workflows
- Published to GitHub Container Registry (GHCR)
- **Optimized for OCI Container Instances**
- Well suited for serverless CI/CD pipelines on OCI

## Available Image

### GitHub Container Registry (GHCR)

```bash
# Latest version

docker pull ghcr.io/devopshouse/oci-github-runner:latest

# Specific version

docker pull ghcr.io/devopshouse/oci-github-runner:2.338.2
```

On OCI Container Instances, images in an external registry require a public subnet with an internet gateway or a private
subnet with a NAT gateway.

**Available tags:**
- `latest` - Latest stable version
- `{version}` - Specific runner version (e.g., 2.338.2)
- `sha-{commit}` - Commit that produced the image

## OCI Vault Integration

This image integrates with **OCI Vault** to fetch the GitHub authentication token at startup, so the token does not need to be set in the container configuration.

### How It Works

The image uses a `pre-entrypoint.sh` script that runs before the runner's original entrypoint. This script:

1. **Checks OCI authentication** (`OCI_CLI_AUTH`)
   - If it is not set, control passes straight to the original entrypoint
   - Supports `resource_principal` for Container Instances

2. **Fetches the GitHub access token from OCI Vault** (through `SECRET_ID`)
   - `SECRET_ID` is the OCID of a secret stored in OCI Vault
   - **This secret holds a GitHub personal access token (PAT) with the minimum permission to register the runner**
   - Uses the OCI CLI to access the Vault and retrieve the secret
   - The secret is returned in base64 format
   - Decodes it and exports it as `ACCESS_TOKEN`

3. **Hands control to the original entrypoint**
   - The runner starts with `ACCESS_TOKEN` already set
   - The runner uses this token to register with GitHub

### What Must Be in OCI Vault

The secret referenced by `SECRET_ID` must contain a **GitHub personal access token (PAT)** with only the minimum permission for the runner scope:

| `RUNNER_SCOPE` | Token type | Minimum permission |
|---|---|---|
| `repo` | Fine-grained PAT, restricted to the repository | Repository permissions → **Administration**: Read and write |
| `org` | Fine-grained PAT, with the organization as resource owner | Organization permissions → **Self-hosted runners**: Read and write |
| `ent` | Classic PAT | `manage_runners:enterprise` |

The token is used to generate the runner registration token when the runner starts and when it is removed.

- Do not use `admin:org`, `admin:enterprise`, or `repo` on classic tokens when a fine-grained option above is available.
- The GitHub documentation does not list fine-grained PAT support for the enterprise endpoint, so `ent` uses a classic
  PAT. Grant it only `manage_runners:enterprise`.
- For `repo` and `org`, the token creator needs admin access to the repository or organization.
- Set an expiration on the token and rotate the secret in the Vault before it expires.
- Do not store a GitHub App installation token in this secret: it expires, and the value in the Vault is static.

References: [self-hosted runner endpoints](https://docs.github.com/en/rest/actions/self-hosted-runners) and
[fine-grained PAT permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens).

**Example of creating the secret in OCI Vault:**

The `--secret-content-content` argument takes the token encoded as base64, without a trailing newline. Encoding is only the Vault transport format; the runner decodes it before use. You can also create the secret in the OCI Console by entering the token as plaintext.

```bash
# 1. Create the secret in OCI Vault with the GitHub token

oci vault secret create-base64 \
  --compartment-id "<compartment-ocid>" \
  --secret-name "github-runner-token" \
  --vault-id <vault-ocid> \
  --key-id <key-ocid> \
  --secret-content-content "<base64-encoded-github-token>"

# 2. Note the returned SECRET_ID (used in the container configuration)

# Example: ocid1.vaultsecret.oc1.<region>.<unique-id>

```

### Components

#### 1. Dockerfile

```dockerfile
# Install the OCI CLI in an isolated environment with uv

RUN uv tool install oci-cli

# Copy the pre-entrypoint script

COPY pre-entrypoint.sh /pre-entrypoint.sh
RUN chmod +x /pre-entrypoint.sh

# Set pre-entrypoint as the entrypoint

ENTRYPOINT ["/pre-entrypoint.sh"]
```

#### 2. pre-entrypoint.sh script

The following is an abbreviated explanation of the startup logic. The actual [pre-entrypoint.sh](../pre-entrypoint.sh) also checks OCI command failures, decoding errors, and empty tokens:

```bash
# 1. Check whether OCI_CLI_AUTH is set

if [ -z "${OCI_CLI_AUTH}" ]; then
  # If not, pass straight to the original entrypoint
  exec /entrypoint.sh "$@"
fi

# 2. Check whether SECRET_ID is set

if [ -z "$SECRET_ID" ]; then
  echo "Error: SECRET_ID is not defined"
  exit 1
fi

# 3. Fetch the secret from OCI Vault

SECRET_BASE64=$(oci secrets secret-bundle get \
  --secret-id "${SECRET_ID}" \
  --query 'data."secret-bundle-content"."content"' \
  --raw-output)

# 4. Decode the secret (base64)

ACCESS_TOKEN=$(echo "$SECRET_BASE64" | base64 -d)

# 5. Export it as an environment variable

export ACCESS_TOKEN

# 6. Hand control to the original entrypoint

exec /entrypoint.sh "$@"
```

#### 3. Container Instance configuration

Example HCL (Terraform) configuration:

```hcl
container_environment_variables = {
  RUNNER_NAME          = "oci-runner-amd64"
  RUNNER_GROUP         = "my-runner-group"
  RUNNER_SCOPE         = "ent"
  ENTERPRISE_NAME      = "your-enterprise"

  # OCI Vault Integration
  SECRET_ID            = "ocid1.vaultsecret.oc1.<region>.<unique-id>"
  OCI_CLI_AUTH         = "resource_principal"

  LABELS               = "oci,amd64"
}
```

### Variables Required for OCI Vault

| Variable | Required | Description |
|----------|----------|-------------|
| `OCI_CLI_AUTH` | Yes | Authentication method (`resource_principal`) |
| `SECRET_ID` | Yes | OCID of the OCI Vault secret that **holds the GitHub access token** |

**Important**: The secret in OCI Vault must contain a valid GitHub personal access token (PAT) with the minimum permission described in [What Must Be in OCI Vault](#what-must-be-in-oci-vault).

### How Resource Principal Works

On **OCI Container Instances**, configure a dynamic group and IAM policy to grant the resource principal access:

1. The Container Instance is matched by a **Dynamic Group**
2. The Dynamic Group has policies to access the Vault
3. The OCI CLI uses `resource_principal` automatically
4. No OCI API keys are required in the container; the GitHub token is retrieved from Vault

**Example policy:**

```
Allow dynamic-group github-runners to read secret-bundles in compartment id <compartment-ocid>
```

### Complete Flow

```
Container Instance starts
    ↓
pre-entrypoint.sh runs
    ↓
Checks OCI_CLI_AUTH and SECRET_ID
    ↓
OCI CLI authenticates through Resource Principal
    ↓
Fetches the GitHub access token from OCI Vault using SECRET_ID
    ↓
OCI Vault returns the secret in base64
    ↓
pre-entrypoint.sh decodes the secret
    ↓
Exports it as ACCESS_TOKEN
    ↓
Original entrypoint (/entrypoint.sh) starts
    ↓
Runner uses ACCESS_TOKEN to register with GitHub
    ↓
 Runner ready to execute workflows
```

### Complete Setup Example

#### 1. Create a GitHub personal access token

```
GitHub → Settings → Developer settings → Personal access tokens

Minimum permission, by runner scope:
- repo: fine-grained PAT, Repository permissions → Administration: Read and write
- org: fine-grained PAT, Organization permissions → Self-hosted runners: Read and write
- ent: classic PAT, manage_runners:enterprise
```

#### 2. Store it in OCI Vault

```bash
# Create the secret in the Vault

oci vault secret create-base64 \
  --compartment-id ocid1.compartment.oc1..aaa... \
  --secret-name "github-runner-token-prod" \
  --vault-id ocid1.vault.oc1.sa-saopaulo-1.aaa... \
  --key-id ocid1.key.oc1.sa-saopaulo-1.aaa... \
  --secret-content-content "<base64-encoded-github-token>"

# Output:

# {

# "data": {

# "id": "ocid1.vaultsecret.oc1.<region>.<unique-id>",

# ...

# }

# }

```

#### 3. Configure the Dynamic Group and policies

```hcl
# Dynamic Group for Container Instances

ALL {
  resource.type = 'computecontainerinstance',
  resource.compartment.id = 'ocid1.compartment.oc1..aaa...'
}

# Policy

Allow dynamic-group github-runners to read secret-bundles in compartment MyCompartment
```

#### 4. Create the Container Instance

```bash
oci container-instances container-instance create \
  --compartment-id ocid1.compartment.oc1..aaa... \
  --availability-domain "<availability-domain>" \
  --shape "CI.Standard.E4.Flex" \
  --shape-config '{"ocpus": 2, "memoryInGBs": 8}' \
  --display-name "oci-github-runner" \
  --vnics '[{"subnetId": "<subnet-ocid>"}]' \
  --containers '[{
    "imageUrl": "ghcr.io/devopshouse/oci-github-runner:latest",
    "environmentVariables": {
      "RUNNER_NAME": "oci-runner-prod",
      "RUNNER_SCOPE": "ent",
      "ENTERPRISE_NAME": "my-company",
      "SECRET_ID": "ocid1.vaultsecret.oc1.<region>.<unique-id>",
      "OCI_CLI_AUTH": "resource_principal"
    }
  }]'
```

#### 5. What happens internally

```bash
# pre-entrypoint.sh does the following:

1. Checks OCI_CLI_AUTH=resource_principal
2. Checks that SECRET_ID exists
3. Runs: oci secrets secret-bundle get --secret-id <SECRET_ID>
4. Receives: "<base64-encoded-github-token>" (base64)
5. Decodes: "<github-token>"
6. Exports: export ACCESS_TOKEN="<github-token>"
7. Runs: /entrypoint.sh (original runner entrypoint)
8. Runner uses ACCESS_TOKEN to register with GitHub
```

### Benefits of This Approach

- **Security**: The GitHub token is not stored in the container configuration
- **Centralized**: Token managed centrally in OCI Vault
- **Rotation**: Rotate the secret in Vault and restart the container to load the new token
- **Auditing**: All Vault access is logged in OCI Audit
- **OCI authentication**: Resource Principal removes the need for OCI API keys; the GitHub token is still required
- **Automatic**: Transparent setup, with no manual secret configuration

## Quick Start

### Using in GitHub Actions Workflows

```yaml
# .github/workflows/deploy.yml

name: Deploy with OCI
on: [push]

jobs:
  deploy:
    runs-on: self-hosted

    steps:
      - uses: actions/checkout@v7

      - name: Configure OCI CLI
        run: |
          oci --version

      - name: Deploy Application
        run: |
          echo "Deploy using OCI Container Instance"
```

### Running on OCI Container Instances

#### Basic example:

```bash
# Create a Container Instance with this image

oci container-instances container-instance create \
  --compartment-id "<compartment-ocid>" \
  --availability-domain "<availability-domain>" \
  --display-name "oci-github-runner-amd64" \
  --shape "CI.Standard.E4.Flex" \
  --shape-config '{"ocpus": 2, "memoryInGBs": 8}' \
  --vnics '[{"subnetId": "<subnet-ocid>"}]' \
  --containers '[{
    "displayName": "oci-github-runner-amd64",
    "imageUrl": "ghcr.io/devopshouse/oci-github-runner:latest",
    "environmentVariables": {
      "RUNNER_NAME": "oci-runner-amd64",
      "RUNNER_GROUP": "my-runner-group",
      "RUNNER_SCOPE": "ent",
      "RANDOM_RUNNER_SUFFIX": "false",
      "ENTERPRISE_NAME": "your-enterprise",
      "DISABLE_AUTO_UPDATE": "true",
      "LABELS": "oci,amd64",
      "SECRET_ID": "<vault-secret-ocid>",
      "OCI_CLI_AUTH": "resource_principal",
      "RUN_AS_ROOT": "true"
    }
  }]'
```

#### Supported environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `ACCESS_TOKEN` | GitHub token when Vault retrieval is disabled | Supply securely at runtime |
| `REPO_URL` | Repository URL for `RUNNER_SCOPE=repo` | `https://github.com/your-org/your-repo` |
| `ORG_NAME` | Organization for `RUNNER_SCOPE=org` | `your-org` |
| `RUNNER_NAME` | Runner name | `oci-runner-amd64` |
| `RUNNER_GROUP` | Runner group | `my-runner-group` |
| `RUNNER_SCOPE` | Scope (repo/org/ent) | `ent` |
| `RANDOM_RUNNER_SUFFIX` | Random suffix | `false` |
| `ENTERPRISE_NAME` | Enterprise name | `your-enterprise` |
| `DISABLE_AUTO_UPDATE` | Disable auto-update | `true` |
| `LABELS` | Custom labels | `oci,amd64` |
| `SECRET_ID` | OCID of the Vault secret | `ocid1.vaultsecret...` |
| `OCI_CLI_AUTH` | OCI auth method | `resource_principal` |
| `RUN_AS_ROOT` | Run as root | `true` |

**Note**: Vault retrieval requires both `OCI_CLI_AUTH` and `SECRET_ID`. If `OCI_CLI_AUTH` is unset, the original entrypoint starts directly; supply authentication through the upstream configuration, such as `ACCESS_TOKEN`.

## Automated Workflows

This repository has automated workflows to keep the image up to date:

### 1. Check GitHub Runner Version

**File**: `.github/workflows/check-runner-version.yml`

- Runs daily at **4:00 AM UTC**
- Checks for a new version of `myoung34/docker-github-actions-runner`
- Opens a PR automatically when an update is detected
- Requests review according to `.github/CODEOWNERS`

### 2. Create Tag and Release

**File**: `.github/workflows/create-tag-and-release.yml`

- Runs when `.tool-versions` is updated on the `main` branch
- Creates the `v{version}` tag automatically
- Generates complete release notes
- Publishes the release on GitHub

### 3. Build and Publish Docker Image

**File**: `.github/workflows/build-and-publish.yml`

- Runs after the "Create Tag and Release" workflow completes
- Builds the Docker image
- Publishes to GitHub Container Registry (GHCR)
- Publishes to OCIR when enabled
- Tags created: `{version}`, `latest`, and `sha-{commit}`

### Automated Flow

```
Schedule (daily at 4:00 AM UTC)
    ↓
Check Runner Version
    ↓
Detects a new version of myoung34/docker-github-actions-runner
    ↓
Opens a PR automatically
    ↓
Review + Merge
    ↓
Create Tag and Release → Creates tag v{version}
    ↓
Build & Publish → Publishes to GHCR
    ↓
 Updated image available
```

### Optional Publishing to OCIR

Publishing to OCIR is disabled by default. To enable it, configure the repository with:

| Setting | Type | Value |
|---|---|---|
| `OCIR_ENABLED` | Variable | `true` |
| `PIPELINE_SECRETS` | Secret | JSON with the fields below |

```json
{
  "OCIR_URL": "<region>.ocir.io",
  "OCIR_NAMESPACE": "<tenancy-namespace>",
  "OCIR_USERNAME": "<tenancy-namespace>/<username>",
  "OCIR_PASSWORD": "<auth-token>"
}
```

The image is published to `<OCIR_URL>/<OCIR_NAMESPACE>/oci-github-runner`, with the same tags as GHCR.

## Usage Examples

### Example 1: Tool Check

```yaml
name: Test Tools
on: [push]

jobs:
  test:
    runs-on: self-hosted

    steps:
      - uses: actions/checkout@v7

      - name: Show Tools
        run: |
          echo "=== Tool Versions ==="
          oci --version
          kubectl version --client
          helm version
          docker --version
          docker compose version
          git --version
          jq --version
          python3 --version
```

### Example 2: Build with Docker

```yaml
name: Build Docker Image
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: self-hosted

    steps:
      - uses: actions/checkout@v7

      - name: Build Image
        run: |
          docker build -t myapp:${{ github.sha }} .

      - name: Tag and Push
        run: |
          docker tag myapp:${{ github.sha }} myapp:latest
          # Push to a registry
```

### Example 3: Manage Container Instances with the OCI CLI

```yaml
name: Manage OCI Container Instances
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: self-hosted

    steps:
      - uses: actions/checkout@v7

      - name: Configure OCI CLI
        env:
          OCI_CLI_USER: ${{ secrets.OCI_USER_OCID }}
          OCI_CLI_TENANCY: ${{ secrets.OCI_TENANCY_OCID }}
          OCI_CLI_FINGERPRINT: ${{ secrets.OCI_FINGERPRINT }}
          OCI_CLI_KEY_CONTENT: ${{ secrets.OCI_PRIVATE_KEY }}
          OCI_CLI_REGION: sa-saopaulo-1
        run: |
          mkdir -p ~/.oci
          echo "$OCI_CLI_KEY_CONTENT" > ~/.oci/oci_api_key.pem
          chmod 600 ~/.oci/oci_api_key.pem

          cat > ~/.oci/config <<EOF
          [DEFAULT]
          user=$OCI_CLI_USER
          fingerprint=$OCI_CLI_FINGERPRINT
          tenancy=$OCI_CLI_TENANCY
          region=$OCI_CLI_REGION
          key_file=~/.oci/oci_api_key.pem
          EOF

      - name: List Container Instances
        run: |
          oci container-instances container-instance list \
            --compartment-id ${{ secrets.OCI_COMPARTMENT_ID }}

      - name: Create GitHub Runner Container Instance
        run: |
          oci container-instances container-instance create \
            --compartment-id ${{ secrets.OCI_COMPARTMENT_ID }} \
            --availability-domain ${{ secrets.OCI_AD }} \
            --display-name "oci-github-runner-amd64" \
            --shape "CI.Standard.E4.Flex" \
            --shape-config '{"ocpus": 2, "memoryInGBs": 8}' \
            --vnics '[{"subnetId": "<subnet-ocid>"}]' \
            --containers '[{
              "displayName": "oci-github-runner-amd64",
              "imageUrl": "ghcr.io/devopshouse/oci-github-runner:latest",
              "environmentVariables": {
                "RUNNER_NAME": "oci-runner-amd64",
                "RUNNER_GROUP": "my-runner-group",
                "RUNNER_SCOPE": "ent",
                "RANDOM_RUNNER_SUFFIX": "false",
                "ENTERPRISE_NAME": "${{ secrets.GITHUB_ENTERPRISE }}",
                "DISABLE_AUTO_UPDATE": "true",
                "LABELS": "oci,amd64",
                "SECRET_ID": "${{ secrets.VAULT_SECRET_OCID }}",
                "OCI_CLI_AUTH": "resource_principal",
                "RUN_AS_ROOT": "true"
              }
            }]'
```

### Example 4: Build and Deploy to Container Instances

```yaml
name: Build and Deploy to Container Instances
on: [push]

jobs:
  deploy:
    runs-on: self-hosted

    steps:
      - uses: actions/checkout@v7

      - name: Login OCIR
        env:
          OCIR_USER: ${{ secrets.OCIR_USERNAME }}
          OCIR_TOKEN: ${{ secrets.OCIR_TOKEN }}
          OCIR_REGION: ${{ secrets.OCIR_REGION }}
        run: |
          echo "$OCIR_TOKEN" | docker login $OCIR_REGION.ocir.io -u "$OCIR_USER" --password-stdin

      - name: Build and Push
        env:
          OCIR_REGION: ${{ secrets.OCIR_REGION }}
          OCIR_NAMESPACE: ${{ secrets.OCIR_NAMESPACE }}
        run: |
          docker build -t $OCIR_REGION.ocir.io/$OCIR_NAMESPACE/myapp:${{ github.sha }} .
          docker push $OCIR_REGION.ocir.io/$OCIR_NAMESPACE/myapp:${{ github.sha }}

      - name: Configure OCI CLI
        env:
          OCI_CLI_USER: ${{ secrets.OCI_USER_OCID }}
          OCI_CLI_TENANCY: ${{ secrets.OCI_TENANCY_OCID }}
          OCI_CLI_FINGERPRINT: ${{ secrets.OCI_FINGERPRINT }}
          OCI_CLI_KEY_CONTENT: ${{ secrets.OCI_PRIVATE_KEY }}
          OCI_CLI_REGION: ${{ secrets.OCIR_REGION }}
        run: |
          mkdir -p ~/.oci
          echo "$OCI_CLI_KEY_CONTENT" > ~/.oci/oci_api_key.pem
          chmod 600 ~/.oci/oci_api_key.pem

          cat > ~/.oci/config <<EOF
          [DEFAULT]
          user=$OCI_CLI_USER
          fingerprint=$OCI_CLI_FINGERPRINT
          tenancy=$OCI_CLI_TENANCY
          region=$OCI_CLI_REGION
          key_file=~/.oci/oci_api_key.pem
          EOF

      - name: Deploy to Container Instance
        run: |
          oci container-instances container-instance create \
            --compartment-id ${{ secrets.OCI_COMPARTMENT_ID }} \
            --availability-domain ${{ secrets.OCI_AD }} \
            --display-name "myapp-${{ github.sha }}" \
            --shape "CI.Standard.E4.Flex" \
            --shape-config '{"ocpus": 1, "memoryInGBs": 4}' \
            --vnics '[{"subnetId": "<subnet-ocid>"}]' \
            --containers '[{
              "displayName": "app",
              "imageUrl": "${{ secrets.OCIR_REGION }}.ocir.io/${{ secrets.OCIR_NAMESPACE }}/myapp:${{ github.sha }}"
            }]'
```

### Example 5: Complete Pipeline for OIC

```yaml
name: Complete CI/CD Pipeline for OIC
on:
  push:
    branches: [main]

jobs:
  build-and-deploy:
    runs-on: self-hosted

    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Build Application
        run: |
          docker build -t myapp:${{ github.sha }} .

      - name: Run Tests
        run: |
          docker run --rm myapp:${{ github.sha }} npm test

      - name: Configure OCI CLI
        env:
          OCI_CLI_USER: ${{ secrets.OCI_USER_OCID }}
          OCI_CLI_TENANCY: ${{ secrets.OCI_TENANCY_OCID }}
          OCI_CLI_FINGERPRINT: ${{ secrets.OCI_FINGERPRINT }}
          OCI_CLI_KEY_CONTENT: ${{ secrets.OCI_PRIVATE_KEY }}
          OCI_CLI_REGION: us-ashburn-1
        run: |
          mkdir -p ~/.oci
          echo "$OCI_CLI_KEY_CONTENT" > ~/.oci/oci_api_key.pem
          chmod 600 ~/.oci/oci_api_key.pem

          cat > ~/.oci/config <<EOF
          [DEFAULT]
          user=$OCI_CLI_USER
          fingerprint=$OCI_CLI_FINGERPRINT
          tenancy=$OCI_CLI_TENANCY
          region=$OCI_CLI_REGION
          key_file=~/.oci/oci_api_key.pem
          EOF

      - name: Push to OCIR
        env:
          OCIR_REGION: ${{ secrets.OCIR_REGION }}
          OCIR_NAMESPACE: ${{ secrets.OCIR_NAMESPACE }}
          OCIR_TOKEN: ${{ secrets.OCIR_TOKEN }}
        run: |
          echo "$OCIR_TOKEN" | docker login $OCIR_REGION.ocir.io \
            -u "$OCIR_NAMESPACE/${{ github.actor }}" \
            --password-stdin

          docker tag myapp:${{ github.sha }} \
            $OCIR_REGION.ocir.io/$OCIR_NAMESPACE/myapp:${{ github.sha }}

          docker push $OCIR_REGION.ocir.io/$OCIR_NAMESPACE/myapp:${{ github.sha }}

      - name: Deploy to OIC
        run: |
          # Trigger OIC integration or deploy
          curl -X POST "${{ secrets.OIC_WEBHOOK_URL }}" \
            -H "Content-Type: application/json" \
            -d '{
              "image": "${{ secrets.OCIR_REGION }}.ocir.io/${{ secrets.OCIR_NAMESPACE }}/myapp:${{ github.sha }}",
              "environment": "production"
            }'
```

## Development

### Local Build

```bash
# Build the image

docker build -t oci-github-runner:test \
  --build-arg RUNNER_VERSION=2.338.2 \
  .

# Test the image

docker run -it --rm --entrypoint bash oci-github-runner:test

# Check the installed tools

docker run --rm --entrypoint bash oci-github-runner:test -c "
  echo '=== Tool Versions ===' && \
  kubectl version --client && \
  helm version && \
  oci --version && \
  ansible --version && \
  git --version && \
  jq --version && \
  yq --version && \
  python3 --version
"
```

### Version Management

The `kubectl`, `helm`, and `uv` versions are pinned in `KUBECTL_VERSION`, `HELM_VERSION`, and `UV_VERSION` in the
`Dockerfile` and updated manually.

The runner version is managed in the `.tool-versions` file:

```bash
github-runner 2.338.2
```

#### Manual Update

```bash
# 1. Edit .tool-versions

vim .tool-versions

# 2. Update to the new version

# github-runner 2.338.2

# 3. Commit and push

git add .tool-versions
git commit -m "Update github-runner to 2.338.2"
git push

# 4. The workflows create the tag and build automatically

```

**Note**: The automated workflow checks daily and opens a PR when a new version is available.

### Adding a New Tool

1. Edit the `Dockerfile`:

```dockerfile
# Add a new tool

RUN apt-get update && apt-get install -y \
    new-tool \
    another-tool \
    && rm -rf /var/lib/apt/lists/*
```

2. Test locally:

```bash
docker build -t test .
docker run -it --rm --entrypoint bash test
# Check that the tool is available

which new-tool
new-tool --version
```

3. Add the new tool to the included tools section of this README

4. Open a PR. After merging image changes without a runner version update, run Create Tag and Release manually to trigger publication.

### Project Structure

```
.
├── .github/
│   ├── CODEOWNERS                      # Default reviewers
│   ├── dependabot.yml                  # Updates the SHA-pinned actions
│   ├── actions/
│   │   └── setup-registry/             # Reads the OCIR credentials
│   └── workflows/
│       ├── check-runner-version.yml    # Checks for new versions
│       ├── create-tag-and-release.yml  # Creates tags and releases
│       └── build-and-publish.yml       # Builds and publishes the image
├── .tool-versions                      # Runner version
├── Dockerfile                          # Image Dockerfile
├── LICENSE                             # GPL-3.0 license
├── Makefile                            # Local build and push
├── pre-entrypoint.sh                   # Fetches the token from OCI Vault
└── README.md                           # This file
```

## Image Information

### Size

```bash
# Check the registry for the compressed size of the selected image.

# Inspect a locally pulled image:

docker image inspect ghcr.io/devopshouse/oci-github-runner:2.338.2 --format '{{.Size}}'
```

### Base

- **Base image**: `myoung34/docker-github-actions-runner`
- **Repository**: https://github.com/myoung34/docker-github-actions-runner

### Environment Variables

See the official documentation for all variables:
https://github.com/myoung34/docker-github-actions-runner#environment-variables

**Main variables:**

- `RUNNER_NAME` - Runner name
- `ACCESS_TOKEN` - GitHub access token
- `REPO_URL` - Repository URL
- `ORG_NAME` - GitHub organization
- `LABELS` - Custom labels

## Security

- Based on a community-maintained image
- Automatic version updates
- Automated, traceable build
- Published to a public registry (GHCR)

## Contributing

1. Fork the repository
2. Create a branch for your feature (`git checkout -b feature/new-feature`)
3. Commit your changes (`git commit -am 'Add: new feature'`)
4. Push the branch (`git push origin feature/new-feature`)
5. Open a pull request

## License

This project is licensed under GPL-3.0. See the [LICENSE](../LICENSE) file for details.

## Useful Links

### Repositories

- **GitHub**: https://github.com/devopshouse/oci-github-runner
- **Container Registry (GHCR)**: https://github.com/devopshouse/oci-github-runner/pkgs/container/oci-github-runner
- **Base image**: https://github.com/myoung34/docker-github-actions-runner

### Documentation

- **GitHub Actions**: https://docs.github.com/en/actions
- **Self-hosted runners**: https://docs.github.com/en/actions/hosting-your-own-runners
- **OCI CLI**: https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm

## Support

- **Issues**: https://github.com/devopshouse/oci-github-runner/issues

## Runtime and publication notes

The published image currently targets AMD64; the build workflow does not assemble a multi-platform manifest. Docker commands require a reachable daemon and the permissions to use it. Validate Docker builds against your Container Instances runtime configuration. Kubernetes access requires a kubeconfig or another authentication method configured for the job.

Use a digest when an immutable image reference is required. A release can exist before its image finishes publishing. README-only changes do not trigger the release workflow; it watches `.tool-versions` on `main` and supports manual runs. Existing tags and releases are preserved by that workflow. The publication workflow checks out the branch head, so inspect its source revision when confirming which changes reached an image.

OCI CLI and Ansible are resolved at build time. kubectl, Helm, and uv have pinned Dockerfile build arguments. Pass `RUNNER_VERSION` explicitly or use `make build`; the Dockerfile's default may differ from `.tool-versions`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Vault access denied | Dynamic group membership, secret OCID, and the policy for the secret's compartment |
| Missing `SECRET_ID` | Setting `OCI_CLI_AUTH` enables Vault retrieval and requires `SECRET_ID` |
| Empty or undecodable secret | Store the GitHub token as the secret content, correctly encoded for the Vault API |
| Runner registration fails | Token expiration, runner scope, target repository or organization, and GitHub permissions |
| Image pull fails | Subnet connectivity, registry credentials, package visibility, and image tag |
| Docker cannot connect | Availability of a daemon and runtime permissions |
| kubectl cannot connect | Cluster endpoint connectivity and Kubernetes credentials |
| No version update PR | Actions PR permissions, existing update PR, and upstream API response |
| Release exists but image is missing | Build and Publish workflow status and registry destination |

The Vault secret is loaded once per startup. After rotating it, restart the container to load the replacement token. The resource principal's policies also apply to OCI commands executed by jobs; grant the deployment permissions those jobs need separately from secret access.
