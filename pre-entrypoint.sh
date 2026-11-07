#!/bin/bash

# Check if OCI_CLI_AUTH is defined and not empty
if [ -z "${OCI_CLI_AUTH}" ]; then
  echo "Warning: OCI_CLI_AUTH is not defined or is empty. Passing control to the original entrypoint..."
  exec /entrypoint.sh "$@"
fi

echo "Using OCI_CLI_AUTH=${OCI_CLI_AUTH}"

# Check if SECRET_ID is defined
if [ -z "$SECRET_ID" ]; then
  echo "Error: SECRET_ID is not defined. Cannot retrieve ACCESS_TOKEN."
  exit 1
fi

# Only stderr goes to the log: stdout carries the secret.
OCI_LOG=$(mktemp)

echo "Retrieving the encoded secret (base64)..."
if ! SECRET_BASE64=$(oci secrets secret-bundle get \
  --secret-id "${SECRET_ID}" \
  --query 'data."secret-bundle-content"."content"' \
  --raw-output 2> "$OCI_LOG"); then
  echo "Error: Failed to execute the 'oci' command to retrieve the encoded secret."
  echo "Full error output of the 'oci' command:"
  cat "$OCI_LOG"
  rm -f "$OCI_LOG"
  exit 1
fi
rm -f "$OCI_LOG"

# Check if the encoded secret is empty
if [ -z "$SECRET_BASE64" ]; then
  echo "Error: The encoded secret is empty. Check the value of SECRET_ID or the command parameters."
  exit 1
fi

# Decode the secret
echo "Decoding the secret..."
if ! ACCESS_TOKEN=$(printf '%s' "$SECRET_BASE64" | base64 -d); then
  echo "Error: Failed to decode the base64 encoded secret."
  exit 1
fi

# Check if the ACCESS_TOKEN was retrieved successfully
if [ -z "$ACCESS_TOKEN" ]; then
  echo "Error: ACCESS_TOKEN is empty after decoding."
  exit 1
fi

# Export ACCESS_TOKEN as an environment variable
export ACCESS_TOKEN
echo "ACCESS_TOKEN has been dynamically set."

# Pass control to the original entrypoint
exec /entrypoint.sh "$@"
