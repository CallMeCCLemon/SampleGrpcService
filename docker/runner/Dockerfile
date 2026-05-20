# Self-hosted GitHub Actions runner image for this project's cluster.
#
# Based on myoung34/github-runner which handles runner registration/deregistration
# automatically on Pod start/stop. We layer in kubectl, helm, Go, and Node.js,
# which are needed by the project Makefile but not present in the base image.
#
# Tools already included by the base image:
#   docker CLI, git, make, curl, jq, unzip, wget, build-essential
#
# Build and push (from dev machine):
#   make runner-build

FROM myoung34/github-runner:latest

ARG TARGETARCH

# Install kubectl (latest stable)
RUN KUBECTL_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt) && \
    curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/${TARGETARCH}/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl

# Install helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Go (kept in sync with go.mod's `go` directive).
ARG GO_VERSION=1.25.0
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" | tar -C /usr/local -xz && \
    ln -sf /usr/local/go/bin/go /usr/local/bin/go && \
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# Make Go discoverable for the actions-runner shell, regardless of how it
# bootstraps PATH. The symlinks above cover login shells; this covers cases
# where the runner spawns commands without sourcing /etc/profile.
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOTOOLCHAIN="local"

# Install Node.js 22 LTS (used by web/ tooling and any vitest workflows).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*
