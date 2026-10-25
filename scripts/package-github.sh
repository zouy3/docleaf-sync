#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
git rev-parse --verify HEAD >/dev/null
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "请先提交源码改动；打包仅包含当前 Git 提交，不包含缓存、签名或阅读数据。" >&2
  exit 1
fi
mkdir -p release
git archive --format=zip --prefix=docleaf-sync/ --output=release/docleaf-sync-source.zip HEAD
echo "已生成：$project_dir/release/docleaf-sync-source.zip"
