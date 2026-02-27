#!/usr/bin/env bash
# stacks/rust.sh — Rust toolchain + quality/coverage tools
# Runs INSIDE container after base.sh
set -e
export DEBIAN_FRONTEND=noninteractive

echo "Installing Rust stack..."

# Rust toolchain (stable) — installs rustc, cargo, clippy, rustfmt
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Coverage
cargo install cargo-tarpaulin

# Security auditing
cargo install cargo-audit

echo "Rust stack complete"
