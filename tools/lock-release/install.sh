#!/bin/bash
# 安装 lock-release：扩展装进 IDE 的扩展目录，CLI 软链到 ~/.local/bin。
#   ./install.sh                      # 默认装到 Trae CN
#   ./install.sh ~/.vscode/extensions # 也可指定 VS Code 的扩展目录
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
read -r PUBLISHER NAME VERSION <<<"$(node -p "[require('$SRC/extension/package.json').publisher, require('$SRC/extension/package.json').name, require('$SRC/extension/package.json').version].join(' ')")"
EXT_DIR_NAME="$PUBLISHER.$NAME-$VERSION"

TARGETS=("${@:-$HOME/.trae-cn/extensions}")
for base in ${TARGETS[@]}; do
  base="${base/#\~/$HOME}"
  dest="$base/$EXT_DIR_NAME"
  mkdir -p "$dest"
  cp "$SRC/extension/package.json" "$SRC/extension/extension.js" "$SRC/release.js" "$dest/"
  echo "扩展已安装: $dest"
done

mkdir -p "$HOME/.local/bin"
ln -sf "$SRC/release.js" "$HOME/.local/bin/lock-release"
chmod +x "$SRC/release.js" "$HOME/.local/bin/lock-release"
echo "CLI 已软链: $HOME/.local/bin/lock-release -> $SRC/release.js"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "注意: $HOME/.local/bin 不在 PATH 里，需在 ~/.zshrc 加: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo "IDE 里执行「Developer: Reload Window」后生效。"
