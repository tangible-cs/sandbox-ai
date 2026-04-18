#!/usr/bin/env bash
# stacks/rust.sh — Rust toolchain + quality/coverage tools
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Rust stack..."

# Build dependencies for cargo-tarpaulin (needs openssl-sys)
apt-get update
apt-get install -y pkg-config libssl-dev
apt-get clean && rm -rf /var/lib/apt/lists/*

# Rust toolchain (stable, installed as ubuntu) — installs rustc, cargo, clippy, rustfmt
install_rustup_verified

# Coverage + security auditing
su - ubuntu -c "source \$HOME/.cargo/env && cargo install cargo-tarpaulin --version ${CARGO_TARPAULIN_VERSION} && cargo install cargo-audit --version ${CARGO_AUDIT_VERSION}"

echo "Rust stack complete"
