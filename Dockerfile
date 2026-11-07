# Runner version build argument with its default value
ARG RUNNER_VERSION=2.325.0
ARG UBUNTU_VERSION=ubuntu-noble

# Use the myoung34/github-runner base image with the specified version
FROM docker.io/myoung34/github-runner:${RUNNER_VERSION}-${UBUNTU_VERSION}

ARG KUBECTL_VERSION=v1.37.2
ARG HELM_VERSION=v4.3.1
ARG UV_VERSION=0.13.7

# Install kubectl and Helm, verifying the published checksums
RUN ARCH="$(dpkg --print-architecture)" && \
    KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" && \
    curl -fsSLo /usr/local/bin/kubectl "${KUBECTL_URL}" && \
    echo "$(curl -fsSL "${KUBECTL_URL}.sha256")  /usr/local/bin/kubectl" | sha256sum -c - && \
    chmod 0755 /usr/local/bin/kubectl && \
    HELM_TAR="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" && \
    cd /tmp && \
    curl -fsSLO "https://get.helm.sh/${HELM_TAR}" && \
    curl -fsSL "https://get.helm.sh/${HELM_TAR}.sha256sum" | sha256sum -c - && \
    tar -xzf "${HELM_TAR}" --strip-components=1 -C /usr/local/bin "linux-${ARCH}/helm" && \
    rm -f "${HELM_TAR}"

# Install the OCI CLI and Ansible in isolated environments with uv, verifying the published checksum
RUN UV_TAR="uv-$(uname -m)-unknown-linux-gnu.tar.gz" && \
    UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_TAR}" && \
    cd /tmp && \
    curl -fsSLO "${UV_URL}" && \
    curl -fsSL "${UV_URL}.sha256" | sha256sum -c - && \
    mkdir /tmp/uv && \
    tar -xzf "${UV_TAR}" --strip-components=1 -C /tmp/uv && \
    export UV_NO_CACHE=1 UV_PYTHON_PREFERENCE=only-system UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin && \
    /tmp/uv/uv tool install oci-cli && \
    /tmp/uv/uv tool install --with-executables-from ansible-core ansible && \
    rm -rf /tmp/uv "${UV_TAR}"

# Copy the pre-entrypoint script into the container
COPY pre-entrypoint.sh /pre-entrypoint.sh

# Make the script executable
RUN chmod +x /pre-entrypoint.sh

# Set the new script as the entrypoint and keep original CMD
ENTRYPOINT ["/pre-entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
