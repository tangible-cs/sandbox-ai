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
su - ubuntu -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'

# Coverage + security auditing
su - ubuntu -c 'source $HOME/.cargo/env && cargo install cargo-tarpaulin cargo-audit'

echo "Rust stack complete"
