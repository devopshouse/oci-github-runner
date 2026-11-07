# GitHub Actions Runner for OCI Container Instances

[![Build and Publish](https://github.com/devopshouse/oci-github-runner/actions/workflows/build-and-publish.yml/badge.svg)](https://github.com/devopshouse/oci-github-runner/actions/workflows/build-and-publish.yml)
[![Check Runner Version](https://github.com/devopshouse/oci-github-runner/actions/workflows/check-runner-version.yml/badge.svg)](https://github.com/devopshouse/oci-github-runner/actions/workflows/check-runner-version.yml)

A custom image based on `myoung34/github-runner`, intended for self-hosted runners on OCI Container Instances. It adds OCI CLI, Ansible, kubectl, and Helm, with an entrypoint that can read the GitHub token from OCI Vault.

For the complete setup, see the [configuration and operations guide](docs/guide.md). It covers Vault setup, token permissions, startup behavior, environment variables, workflow examples, and image maintenance.

## Why this project exists

This image provides the tools needed to deploy Kubernetes workloads and interact with OCI services without installing them during every job. Runner registration is handled by the upstream image; this repository adds the tools and Vault integration.

On Container Instances, a resource principal lets the runner retrieve its GitHub token without storing OCI API keys or the token in the container configuration. Networking, IAM policies, and runner scope remain part of your deployment setup.

## Included tools

| Purpose | Tools |
| --- | --- |
| Oracle Cloud | OCI CLI, installed with uv |
| Kubernetes | kubectl, Helm |
| Automation | Ansible, installed with uv |
| Base image | Docker, Docker Compose, Git, curl, wget, jq, yq, Python 3, make, GCC, G++ |

Docker commands require a working daemon and the permissions to use it. The tools inherited from the base image do not establish that Docker builds will work on Container Instances; validate against your runtime configuration.

## Pull the image

```bash
docker pull ghcr.io/devopshouse/oci-github-runner:latest
docker pull ghcr.io/devopshouse/oci-github-runner:2.338.2
```

Publication also creates `sha-<commit>` tags. Use an image digest when an immutable reference is required. The current publication workflow builds on an AMD64 runner and does not create a multi-platform manifest.

Container Instances need access to the registry through an internet gateway in a public subnet or a NAT gateway in a private subnet.

## Use on OCI Container Instances

The following example creates a repository runner using a token stored in OCI Vault. Replace the OCIDs, availability domain, and repository URL with your own values:

```bash
oci container-instances container-instance create \
  --compartment-id '<compartment-ocid>' \
  --availability-domain '<availability-domain>' \
  --display-name 'github-runner' \
  --shape 'CI.Standard.E4.Flex' \
  --shape-config '{"ocpus": 2, "memory_in_gbs": 8}' \
  --vnics '[{"subnetId": "<subnet-ocid>"}]' \
  --containers '[{
    "displayName": "runner",
    "imageUrl": "ghcr.io/devopshouse/oci-github-runner:2.338.2",
    "environmentVariables": {
      "RUNNER_NAME": "oci-runner",
      "RUNNER_SCOPE": "repo",
      "REPO_URL": "https://github.com/your-org/your-repo",
      "LABELS": "oci",
      "DISABLE_AUTO_UPDATE": "true",
      "OCI_CLI_AUTH": "resource_principal",
      "SECRET_ID": "<vault-secret-ocid>"
    }
  }]'
```

For organization runners, set `RUNNER_SCOPE=org` and `ORG_NAME`. For enterprise runners, set `RUNNER_SCOPE=ent` and `ENTERPRISE_NAME`. Use `RUNNER_GROUP` if the runner should join a specific group.

See the [upstream environment variables](https://github.com/myoung34/docker-github-actions-runner#environment-variables) for the full registration and runtime configuration.

Example job on the registered runner:

```yaml
jobs:
  deploy:
    runs-on: [self-hosted, oci]
    steps:
      - uses: actions/checkout@v7
      - name: Check OCI access
        run: oci iam region list
      - name: Deploy
        run: kubectl apply -f k8s/
```

Kubernetes credentials must be configured separately. OCI permissions for deployment jobs are determined by the resource principal's IAM policies.

## OCI Vault authentication

When `OCI_CLI_AUTH` is set, `pre-entrypoint.sh` reads the secret identified by `SECRET_ID`, decodes its base64 content, exports it as `ACCESS_TOKEN`, and starts the upstream `/entrypoint.sh`. Startup fails if the secret cannot be retrieved or decoded, or if the decoded token is empty.

When `OCI_CLI_AUTH` is unset, the script starts the upstream entrypoint directly. In that case, provide authentication through the upstream image's supported configuration, such as `ACCESS_TOKEN`.

### GitHub token

Store a GitHub personal access token in the Vault secret. The upstream entrypoint uses it to request runner registration and removal tokens.

| Runner scope | Token type | Minimum permission |
| --- | --- | --- |
| `repo` | Fine-grained PAT restricted to the repository | Repository Administration: read and write |
| `org` | Fine-grained PAT owned by the organization | Organization Self-hosted runners: read and write |
| `ent` | Classic PAT | `manage_runners:enterprise` |

For repository and organization runners, the token creator needs admin access to the corresponding scope. Set an expiration and rotate the Vault secret before it expires. The secret is read at startup; restart the container to load a rotated token. A static GitHub App installation token is unsuitable because it expires.

See GitHub's [self-hosted runner endpoints](https://docs.github.com/en/rest/actions/self-hosted-runners) for permission requirements.

### Resource principal

Create a dynamic group that matches the Container Instances in your runner compartment:

```text
ALL {resource.type = 'computecontainerinstance', resource.compartment.id = '<compartment-ocid>'}
```

Grant that group access to secret bundles in the compartment holding the secret:

```text
Allow dynamic-group github-runners to read secret-bundles in compartment id <vault-compartment-ocid>
```

Set `OCI_CLI_AUTH=resource_principal` and `SECRET_ID=<vault-secret-ocid>` on the container. The IAM policy must cover the secret's compartment, which may differ from the runner's compartment.

## Registries

GHCR is the default publication destination, authenticated with the workflow's `GITHUB_TOKEN` and `packages: write`. The GHCR package must be public for anonymous pulls.

OCIR is optional. Set repository variable `OCIR_ENABLED` to `true` and repository secret `PIPELINE_SECRETS` to:

```json
{
  "OCIR_URL": "<region>.ocir.io",
  "OCIR_NAMESPACE": "<tenancy-namespace>",
  "OCIR_USERNAME": "<tenancy-namespace>/<username>",
  "OCIR_PASSWORD": "<auth-token>"
}
```

The local `setup-registry` action reads these fields, masks credentials, and rejects missing values. OCIR publishes to `<OCIR_URL>/<OCIR_NAMESPACE>/oci-github-runner` with the same tags as GHCR. No OCIR secrets are required when the variable is unset.

## Automation

- **Check GitHub Runner Version:** runs daily at 04:00 UTC or manually. Checks upstream tags and opens a PR to update `.tool-versions`. An existing open PR for the same version is reused.
- **Create Tag and Release:** runs when `.tool-versions` changes on `main`, or manually. Creates a missing `v<runner-version>` tag and release; existing tags and releases are preserved.
- **Build and Publish Docker Image:** follows a successful release workflow or runs manually. Builds the image with the version from `.tool-versions` and publishes it to GHCR and, when enabled, OCIR.
- **Dependabot:** updates SHA-pinned GitHub Actions. Other tool versions are maintained in the Dockerfile.

Allow GitHub Actions to create pull requests in repository settings. CODEOWNERS assigns reviews to `@devopshouse/devops`. README-only changes do not trigger publication; image changes without a runner version update require a manual workflow run.

## Local development

```bash
version=$(awk '$1 == "github-runner" {print $2}' .tool-versions)
docker build --build-arg RUNNER_VERSION="$version" -t oci-runner:test .
docker run --rm --entrypoint bash oci-runner:test -c \
  'oci --version && ansible --version && kubectl version --client && helm version'
```

`make build` also reads the runner version from `.tool-versions` and tags the image with that version and `latest`. A Docker build without the version argument uses the Dockerfile's default, which may differ from `.tool-versions`.

Edit `.tool-versions` to change the runner version, keeping the format `github-runner X.Y.Z`. The `KUBECTL_VERSION`, `HELM_VERSION`, and `UV_VERSION` build arguments pin those tools. OCI CLI and Ansible are resolved at build time.

## Troubleshooting

- **Vault access denied:** check the dynamic group rule, secret OCID, and policy covering the secret's compartment.
- **Missing `SECRET_ID`:** setting `OCI_CLI_AUTH` enables Vault retrieval and makes `SECRET_ID` required.
- **Runner registration fails:** check the GitHub token's expiration, permissions, and runner scope.
- **Image pull denied:** check registry credentials, GHCR package visibility, and subnet connectivity.
- **Missing image tag:** inspect the publication workflow; a GitHub release can exist before the image build finishes.

## References

- [Base image and runner configuration](https://github.com/myoung34/docker-github-actions-runner)
- [GitHub Actions runner](https://github.com/actions/runner)
- [OCI Container Instances](https://docs.oracle.com/en-us/iaas/Content/container-instances/home.htm)
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm)

## Licensing and maintenance

Maintained by `@devopshouse/devops`. Open an issue for questions or bugs. This repository is licensed under [GPL-3.0](LICENSE); included third-party tools retain their respective licenses.
