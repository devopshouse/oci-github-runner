#!/usr/bin/env bash
set -euo pipefail

image=${1:?Usage: test-image.sh IMAGE [amd64|arm64]}
arch=${2:-}

docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
if [ -n "$arch" ]; then
  actual=$(docker image inspect --format '{{.Architecture}}' "$image")
  if [ "$actual" != "$arch" ]; then
    echo "Expected $arch image, got $actual" >&2
    exit 1
  fi
fi

docker run --rm --entrypoint bash "$image" -ec '
  test -x /pre-entrypoint.sh
  test -x /entrypoint.sh
  test -x /actions-runner/bin/Runner.Listener
  docker --version
  docker compose version
  kubectl version --client
  helm version --short
  oci --version
  ansible --version
  git --version
  jq --version
  yq --version
  python3 --version
  make --version
'

# Test the actual wrapper with a fake Vault and upstream entrypoint in a disposable container.
# No cloud credentials or GitHub registration are needed.
docker run --rm --user root --entrypoint bash "$image" -euc '
  printf "#!/bin/bash\nprintf upstream-ok\n" > /entrypoint.sh
  chmod +x /entrypoint.sh
  unset OCI_CLI_AUTH SECRET_ID ACCESS_TOKEN
  test "$(/pre-entrypoint.sh | tail -1)" = upstream-ok

  export OCI_CLI_AUTH=resource_principal
  if /pre-entrypoint.sh >/dev/null 2>&1; then
    echo "Missing SECRET_ID should fail" >&2
    exit 1
  fi

  export SECRET_ID=test-secret
  oci() { printf %s "${MOCK_SECRET}"; }
  export -f oci
  export MOCK_SECRET=$(printf %s test-token | base64)
  printf "#!/bin/bash\ntest \"\$ACCESS_TOKEN\" = test-token\n" > /entrypoint.sh
  /pre-entrypoint.sh

  for MOCK_SECRET in "" "not-base64"; do
    export MOCK_SECRET
    if /pre-entrypoint.sh >/dev/null 2>&1; then
      echo "Invalid Vault content should fail" >&2
      exit 1
    fi
  done
  oci() { return 1; }
  export -f oci
  if /pre-entrypoint.sh >/dev/null 2>&1; then
    echo "Vault command failure should fail" >&2
    exit 1
  fi
'
