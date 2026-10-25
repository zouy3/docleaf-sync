#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

blue='\033[0;34m'
green='\033[0;32m'
red='\033[0;31m'
reset='\033[0m'

say() { printf "${blue}[DocLeaf]${reset} %s\n" "$1"; }
fail() {
  printf "${red}[DocLeaf] %s${reset}\n" "$1"
  printf "\n按回车键关闭窗口…"
  read -r
  exit 1
}

command -v node >/dev/null 2>&1 || fail "未找到 Node.js，请先安装 Node.js 22 或更高版本：https://nodejs.org/"
command -v npm >/dev/null 2>&1 || fail "未找到 npm，请重新安装 Node.js。"
NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[[ "$NODE_MAJOR" -ge 22 ]] || fail "Node.js 版本过低，需要 22 或更高版本。当前版本：$(node -v)"

if [[ ! -d node_modules ]]; then
  say "首次运行，正在安装网页依赖…"
  npm install
fi

bridge_pid=""
web_pid=""
cleanup() {
  [[ -n "$web_pid" ]] && kill "$web_pid" 2>/dev/null || true
  [[ -n "$bridge_pid" ]] && kill "$bridge_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if curl -fsS http://127.0.0.1:8787/health >/dev/null 2>&1; then
  say "番茄书源服务已经运行。"
else
  BRIDGE_EXE="$PROJECT_DIR/integrations/fqapp/docleaf_bridge"
  if [[ -x "$BRIDGE_EXE" ]]; then
    say "正在启动预编译番茄书源…"
    "$BRIDGE_EXE" &
  else
    if [[ -x "$PROJECT_DIR/work/cargo/bin/cargo" ]]; then
      export RUSTUP_HOME="$PROJECT_DIR/work/rustup"
      export CARGO_HOME="$PROJECT_DIR/work/cargo"
      export PATH="$CARGO_HOME/bin:$PATH"
    fi
    command -v cargo >/dev/null 2>&1 || fail "未找到预编译书源或 Rust。请从 GitHub Releases 下载对应的 macOS 预编译包。"
    say "正在编译并启动番茄书源（首次编译可能需要几分钟）…"
    cargo run --manifest-path integrations/fqapp/rust/Cargo.toml --bin docleaf_bridge &
  fi
  bridge_pid=$!
fi

if curl -fsS http://localhost:3000/ >/dev/null 2>&1; then
  say "阅读器已经运行。"
else
  say "正在启动阅读器…"
  npm run dev &
  web_pid=$!
fi

for _ in $(seq 1 120); do
  if curl -fsS http://localhost:3000/ >/dev/null 2>&1 && curl -fsS http://127.0.0.1:8787/health >/dev/null 2>&1; then
    printf "${green}[DocLeaf] 启动完成：http://localhost:3000/${reset}\n"
    open http://localhost:3000/
    say "请保持此窗口开启；按 Control+C 可停止服务。"
    wait
    exit 0
  fi
  sleep 1
done

fail "启动超时，请查看上方日志。"
