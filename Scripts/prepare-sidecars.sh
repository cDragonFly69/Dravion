#!/bin/sh
# Fetches the OpenCode sidecar (MIT) at a pinned version into .sidecars/; the binary is not committed.
# OpenCode runs the API connections (OpenAI-compatible, Responses, Anthropic) of local Relay tasks.
set -eu
VERSION=1.19.5
INTEGRITY="sha512-0MbSbKkmwVHtgP31GJyyECe6QVy4T7W4Wp7s2TsmXHTPPyf01ne3dWSX97X9dkNK28Lc6kt+zMPQUP/9GgDLZg=="
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/.sidecars"
[ "$(uname -m)" = arm64 ] || { echo "This build targets Apple Silicon." >&2; exit 1; }
if [ -x "$OUT/opencode" ] && [ "$("$OUT/opencode" --version 2>/dev/null)" = "$VERSION" ]; then
  echo "OpenCode $VERSION already prepared"; exit 0
fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && npm pack --silent "opencode-darwin-arm64@$VERSION" >/dev/null && npm pack --silent "opencode-ai@$VERSION" >/dev/null )
ACTUAL="sha512-$(openssl dgst -sha512 -binary "$WORK/opencode-darwin-arm64-$VERSION.tgz" | base64)"
[ "$ACTUAL" = "$INTEGRITY" ] || { echo "opencode-darwin-arm64@$VERSION integrity mismatch" >&2; exit 1; }
mkdir -p "$WORK/bin" "$WORK/cli" "$OUT/licenses"
tar -xzf "$WORK/opencode-darwin-arm64-$VERSION.tgz" -C "$WORK/bin"
tar -xzf "$WORK/opencode-ai-$VERSION.tgz" -C "$WORK/cli"
install -m 755 "$WORK/bin/package/bin/opencode" "$OUT/opencode"
cp "$WORK/cli/package/LICENSE" "$OUT/licenses/OpenCode-MIT.txt"
echo "OpenCode $("$OUT/opencode" --version) prepared in $OUT"
