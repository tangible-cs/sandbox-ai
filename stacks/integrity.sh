#!/usr/bin/env bash

stack_linux_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "x64" ;;
    arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; return 1 ;;
  esac
}

stack_go_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    *) echo "Unsupported Go architecture: $(dpkg --print-architecture)" >&2; return 1 ;;
  esac
}

stack_rustup_target() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "x86_64-unknown-linux-gnu" ;;
    arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) echo "Unsupported rustup architecture: $(dpkg --print-architecture)" >&2; return 1 ;;
  esac
}

stack_uv_asset_name() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "uv-x86_64-unknown-linux-gnu.tar.gz" ;;
    arm64) echo "uv-aarch64-unknown-linux-gnu.tar.gz" ;;
    *) echo "Unsupported uv architecture: $(dpkg --print-architecture)" >&2; return 1 ;;
  esac
}

require_integrity_var() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || { echo "Missing integrity manifest value: ${name}" >&2; return 1; }
}

append_bashrc_line_once() {
  local line="$1"
  local bashrc="/home/ubuntu/.bashrc"
  grep -Fqx "$line" "$bashrc" 2>/dev/null || echo "$line" >> "$bashrc"
}

verify_file_digest() {
  local algorithm="$1" expected="$2" file="$3"
  require_integrity_var expected >/dev/null
  case "$algorithm" in
    sha256) printf '%s  %s\n' "$expected" "$file" | sha256sum -c - >/dev/null ;;
    sha512) printf '%s  %s\n' "$expected" "$file" | sha512sum -c - >/dev/null ;;
    *) echo "Unsupported digest algorithm: ${algorithm}" >&2; return 1 ;;
  esac
}

download_verified_asset() {
  local url="$1" algorithm="$2" expected="$3" output="$4"
  curl -fsSL "$url" -o "$output"
  verify_file_digest "$algorithm" "$expected" "$output"
}

npm_install_global_verified() {
  local package_name="$1" version="$2" expected_integrity="$3"
  local actual_integrity
  actual_integrity=$(npm view "${package_name}@${version}" dist.integrity)
  [[ "$actual_integrity" == "$expected_integrity" ]] \
    || { echo "Integrity mismatch for ${package_name}@${version}" >&2; return 1; }
  npm install -g "${package_name}@${version}"
}

install_node_runtime() {
  local arch version url checksum archive tmpdir
  arch=$(stack_linux_arch)
  version="${NODE_VERSION}"
  case "$arch" in
    x64) checksum="${NODE_SHA256_X64}" ;;
    arm64) checksum="${NODE_SHA256_ARM64}" ;;
    *) echo "Unsupported Node.js architecture: ${arch}" >&2; return 1 ;;
  esac
  url="https://nodejs.org/dist/${version}/node-${version}-linux-${arch}.tar.xz"
  tmpdir=$(mktemp -d)
  archive="${tmpdir}/node.tar.xz"

  download_verified_asset "$url" sha256 "$checksum" "$archive"
  rm -rf /usr/local/lib/node_modules /usr/local/include/node /usr/local/share/doc/node
  tar -xJf "$archive" -C /usr/local --strip-components=1
  hash -r
  rm -rf "$tmpdir"
}

install_bun_verified() {
  local arch checksum tag asset url tmpdir bun_dir bun_binary
  arch=$(stack_linux_arch)
  tag="${BUN_TAG}"
  asset="bun-linux-${arch}.zip"
  case "$arch" in
    x64) checksum="${BUN_SHA256_X64}" ;;
    arm64) checksum="${BUN_SHA256_ARM64}" ;;
    *) echo "Unsupported Bun architecture: ${arch}" >&2; return 1 ;;
  esac
  url="https://github.com/oven-sh/bun/releases/download/${tag}/${asset}"
  tmpdir=$(mktemp -d)

  download_verified_asset "$url" sha256 "$checksum" "${tmpdir}/${asset}"
  unzip -q "${tmpdir}/${asset}" -d "$tmpdir"
  bun_dir=$(find "$tmpdir" -maxdepth 1 -type d -name 'bun-linux-*' | head -1)
  bun_binary="${bun_dir}/bun"
  install -d -m 0755 /home/ubuntu/.bun/bin
  install -m 0755 "$bun_binary" /home/ubuntu/.bun/bin/bun
  chown -R ubuntu:ubuntu /home/ubuntu/.bun
  append_bashrc_line_once 'export PATH=$HOME/.bun/bin:$PATH'
  rm -rf "$tmpdir"
}

install_uv_verified() {
  local asset checksum url tmpdir uv_bin uvx_bin
  asset=$(stack_uv_asset_name)
  case "$(dpkg --print-architecture)" in
    amd64) checksum="${UV_SHA256_X64}" ;;
    arm64) checksum="${UV_SHA256_ARM64}" ;;
    *) echo "Unsupported uv architecture: $(dpkg --print-architecture)" >&2; return 1 ;;
  esac
  url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${asset}"
  tmpdir=$(mktemp -d)

  download_verified_asset "$url" sha256 "$checksum" "${tmpdir}/${asset}"
  tar -xzf "${tmpdir}/${asset}" -C "$tmpdir"
  uv_bin=$(find "$tmpdir" -type f -name uv | head -1)
  uvx_bin=$(find "$tmpdir" -type f -name uvx | head -1)
  install -m 0755 "$uv_bin" /usr/local/bin/uv
  install -m 0755 "$uvx_bin" /usr/local/bin/uvx
  rm -rf "$tmpdir"
}

install_go_verified() {
  local arch checksum url tmpdir archive
  arch=$(stack_go_arch)
  case "$arch" in
    amd64) checksum="${GO_SHA256_AMD64}" ;;
    arm64) checksum="${GO_SHA256_ARM64}" ;;
    *) echo "Unsupported Go architecture: ${arch}" >&2; return 1 ;;
  esac
  url="https://go.dev/dl/${GO_VERSION}.linux-${arch}.tar.gz"
  tmpdir=$(mktemp -d)
  archive="${tmpdir}/go.tar.gz"

  download_verified_asset "$url" sha256 "$checksum" "$archive"
  rm -rf /usr/local/go
  tar -xzf "$archive" -C /usr/local
  append_bashrc_line_once 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin'
  rm -rf "$tmpdir"
}

install_golangci_lint_verified() {
  local arch checksum version asset url tmpdir archive lint_bin
  arch=$(stack_go_arch)
  version="${GOLANGCI_LINT_VERSION}"
  case "$arch" in
    amd64) checksum="${GOLANGCI_LINT_SHA256_AMD64}" ;;
    arm64) checksum="${GOLANGCI_LINT_SHA256_ARM64}" ;;
    *) echo "Unsupported golangci-lint architecture: ${arch}" >&2; return 1 ;;
  esac
  asset="golangci-lint-${version#v}-linux-${arch}.tar.gz"
  url="https://github.com/golangci/golangci-lint/releases/download/${version}/${asset}"
  tmpdir=$(mktemp -d)
  archive="${tmpdir}/${asset}"

  download_verified_asset "$url" sha256 "$checksum" "$archive"
  tar -xzf "$archive" -C "$tmpdir"
  lint_bin=$(find "$tmpdir" -type f -name golangci-lint | head -1)
  install -m 0755 "$lint_bin" /usr/local/bin/golangci-lint
  rm -rf "$tmpdir"
}

install_rustup_verified() {
  local target checksum url binary tmpdir
  target=$(stack_rustup_target)
  case "$(dpkg --print-architecture)" in
    amd64) checksum="${RUSTUP_SHA256_X64}" ;;
    arm64) checksum="${RUSTUP_SHA256_ARM64}" ;;
    *) echo "Unsupported rustup architecture: $(dpkg --print-architecture)" >&2; return 1 ;;
  esac
  url="https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${target}/rustup-init"
  tmpdir=$(mktemp -d)
  binary="${tmpdir}/rustup-init"

  download_verified_asset "$url" sha256 "$checksum" "$binary"
  chmod +x "$binary"
  su - ubuntu -c "${binary} -y --profile default"
  append_bashrc_line_once 'source "$HOME/.cargo/env"'
  rm -rf "$tmpdir"
}

install_dotnet_sdk_verified() {
  local arch checksum url tmpdir archive
  arch=$(stack_linux_arch)
  case "$arch" in
    x64)
      checksum="${DOTNET_SDK_SHA512_X64}"
      url="https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-linux-x64.tar.gz"
      ;;
    arm64)
      checksum="${DOTNET_SDK_SHA512_ARM64}"
      url="https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-linux-arm64.tar.gz"
      ;;
    *)
      echo "Unsupported .NET architecture: ${arch}" >&2
      return 1
      ;;
  esac
  tmpdir=$(mktemp -d)
  archive="${tmpdir}/dotnet-sdk.tar.gz"

  download_verified_asset "$url" sha512 "$checksum" "$archive"
  rm -rf /usr/share/dotnet
  install -d -m 0755 /usr/share/dotnet
  tar -xzf "$archive" -C /usr/share/dotnet
  ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
  append_bashrc_line_once 'export PATH=$PATH:$HOME/.dotnet/tools'
  rm -rf "$tmpdir"
}

install_unison_verified() {
  local arch checksum asset tmpdir archive ucm_binary
  arch=$(stack_linux_arch)
  case "$arch" in
    x64)
      checksum="${UNISON_SHA256_X64}"
      asset="ucm-linux-x64.tar.gz"
      ;;
    arm64)
      checksum="${UNISON_SHA256_ARM64}"
      asset="ucm-linux-arm64.tar.gz"
      ;;
    *)
      echo "Unsupported Unison architecture: ${arch}" >&2
      return 1
      ;;
  esac
  tmpdir=$(mktemp -d)
  archive="${tmpdir}/${asset}"

  download_verified_asset "https://github.com/unisonweb/unison/releases/download/${UNISON_TAG}/${asset}" sha256 "$checksum" "$archive"
  tar -xzf "$archive" -C "$tmpdir"
  ucm_binary=$(find "$tmpdir" -type f -name ucm | head -1)
  install -m 0755 "$ucm_binary" /usr/local/bin/ucm
  rm -rf "$tmpdir"
}
