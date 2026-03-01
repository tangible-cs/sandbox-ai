#!/usr/bin/env bash
# stacks/go.sh — Go toolchain + quality/coverage tools
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Go stack..."

# Go toolchain (latest stable)
GO_VERSION=$(curl -sL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version')
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" \
  | tar -C /usr/local -xzf -
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> /home/ubuntu/.bashrc

# golangci-lint (meta-linter)
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b /usr/local/bin

# govulncheck (security — install as ubuntu so GOPATH is /home/ubuntu/go)
su - ubuntu -c 'export PATH=$PATH:/usr/local/go/bin && go install golang.org/x/vuln/cmd/govulncheck@latest'

# Coverage: built-in via `go tool cover`, no install needed

echo "Go stack complete"
