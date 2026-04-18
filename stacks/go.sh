#!/usr/bin/env bash
# stacks/go.sh — Go toolchain + quality/coverage tools
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Go stack..."

# Go toolchain
install_go_verified

# golangci-lint (meta-linter)
install_golangci_lint_verified

# govulncheck (security — install as ubuntu so GOPATH is /home/ubuntu/go)
su - ubuntu -c "export PATH=\$PATH:/usr/local/go/bin && go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}"

# Coverage: built-in via `go tool cover`, no install needed

echo "Go stack complete"
