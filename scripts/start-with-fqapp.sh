#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
export RUSTUP_HOME="$project_dir/work/rustup"
export CARGO_HOME="$project_dir/work/cargo"
export PATH="$CARGO_HOME/bin:$PATH"

bridge_pid=""
cleanup() {
  if [[ -n "$bridge_pid" ]]; then
    kill "$bridge_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

cargo run --manifest-path "$project_dir/integrations/fqapp/rust/Cargo.toml" --bin docleaf_bridge &
bridge_pid=$!
npm run dev
