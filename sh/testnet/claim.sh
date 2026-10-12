
#!/bin/sh
# Claims bridged Fee Juice on Aztec testnet L2.
# Auto-detects if your account is deployed:
#   - Not deployed: deploys + claims in one atomic tx (Fee Juice pays for itself)
#   - Already deployed: calls FeeJuice.claim() directly
#
# The faucet UI pre-fills --claim-amount, --claim-secret, and --message-leaf-index.
# You only need to supply your --secret key.
#
# Usage (copy from the faucet UI — values are pre-filled):
#   curl -fsSL https://raw.githubusercontent.com/Nerofea/aztec-faucet/aztec-v6-rc3/sh/testnet/claim.sh | sh -s -- \
#     --secret <YOUR_SECRET_KEY> \
#     --claim-amount <pre-filled> \
#     --claim-secret <pre-filled> \
#     --message-leaf-index <pre-filled>
#
# SECURITY: Avoid passing real wallet secrets through shell history.
# MIGRATION: v6 SDK and claim-signing compatibility must be verified
# before this script is used to execute a transaction.

set -e

REPO_BRANCH="aztec-v6-rc3"
REPO_RAW="https://raw.githubusercontent.com/Nerofea/aztec-faucet/$REPO_BRANCH"

# spin <pid> <message> — animated braille spinner; prints ✓ or ✗ on completion
spin() {
  _pid=$1 _msg=$2 _i=0 _s=$(date +%s)
  while kill -0 "$_pid" 2>/dev/null; do
    _i=$(( (_i + 1) % 10 ))
    case $_i in
      0) _c='⠋' ;; 1) _c='⠙' ;; 2) _c='⠹' ;; 3) _c='⠸' ;; 4) _c='⠼' ;;
      5) _c='⠴' ;; 6) _c='⠦' ;; 7) _c='⠧' ;; 8) _c='⠇' ;; *) _c='⠏' ;;
    esac
    _e=$(( $(date +%s) - _s ))
    printf '\r  \033[36m%s\033[0m  %s  \033[2m%ds\033[0m' "$_c" "$_msg" "$_e"
    sleep 0.1
  done
  wait "$_pid" 2>/dev/null && _ok=0 || _ok=$?
  _e=$(( $(date +%s) - _s ))
  if [ "$_ok" = "0" ]; then
    printf '\r\033[K  \033[32m✓\033[0m  %s  \033[2m%ds\033[0m\n' "$_msg" "$_e"
  else
    printf '\r\033[K  \033[31m✗\033[0m  %s\n' "$_msg"
  fi
  return "$_ok"
}

printf '\n  Aztec Fee Juice Claim (testnet)\n\n'

mkdir -p ~/.aztec-devtools
cd ~/.aztec-devtools

# Restrict permissions on newly created local files.
umask 077

# Load shared version config (always fetch fresh so version bumps propagate)
curl -fsSL "$REPO_RAW/sh/versions.sh" -o .versions.sh || exit 1
. ./.versions.sh
AZTEC_SDK_NPM_TAG="${AZTEC_SDK_NPM_TAG:-6.0.0-rc.3}"
AZTEC_NODE_URL="${AZTEC_NODE_URL:-https://aztec-testnet.drpc.org}"

# Print installed version of a package, empty string if missing or unreadable
_pkg_ver() {
  PKG_TO_CHECK="$1" node -e \
    'try{process.stdout.write(require("./node_modules/" + process.env.PKG_TO_CHECK + "/package.json").version)}catch(e){}' \
    2>/dev/null
}

# Print the version that the registry's tag currently points at.
# Cached in ~/.aztec-devtools so we don't hit npm registry on every run.
_remote_pkg_ver() (
  # Per-package cache file — `/` in pkg names is invalid in filenames, replace with `-`.
  _pkg="$1"
  _tag="$2"
  _safe_pkg=$(printf '%s' "$_pkg" | tr '/' '-')
  _cache="$HOME/.aztec-devtools/.tag-${_safe_pkg}-${_tag}.txt"

  # Refresh cache if older than 6h (or missing)
  if [ ! -s "$_cache" ] ||
     [ -n "$(find "$_cache" -mmin +360 2>/dev/null)" ]; then
    _tmp=$(mktemp) || exit 1

    if npm view "${_pkg}@${_tag}" version > "$_tmp" &&
       [ -s "$_tmp" ]; then
      mv "$_tmp" "$_cache" || exit 1
    else
      rm -f "$_tmp"
      printf 'Error: Cannot verify %s@%s\n' "$_pkg" "$_tag" >&2
      exit 1
    fi
  fi

  tr -d '[:space:]' < "$_cache"
)

# Testnet packages are installed as @aztec-rc/* aliases so claim-fee-juice.mjs
# can import them from that scope without conflicting with devnet @aztec/* packages
_needs_install=0

# Verify that all required packages exist and match the selected SDK version.
for _pkg in wallets aztec.js stdlib; do
  _installed_ver="$(_pkg_ver "@aztec-rc/$_pkg")"

  _expected_ver="$(
    _remote_pkg_ver "@aztec-labs/$_pkg" "$AZTEC_SDK_NPM_TAG"
  )" || exit 1

  if [ -z "$_expected_ver" ]; then
    printf 'Error: No published version found for @aztec-labs/%s\n' \
      "$_pkg" >&2
    exit 1
  fi

  # Check if the @rc tag has moved past the cached version
  if [ "$_installed_ver" != "$_expected_ver" ]; then
    _needs_install=1
  fi
done

if [ "$_needs_install" = "1" ]; then
  printf '{"type":"module"}' > package.json
  rm -rf node_modules/@aztec-rc 2>/dev/null || true

  npm install --no-package-lock --no-audit \
    "@aztec-rc/wallets@npm:@aztec-labs/wallets@$AZTEC_SDK_NPM_TAG" \
    "@aztec-rc/aztec.js@npm:@aztec-labs/aztec.js@$AZTEC_SDK_NPM_TAG" \
    "@aztec-rc/stdlib@npm:@aztec-labs/stdlib@$AZTEC_SDK_NPM_TAG" \
    --silent > /dev/null 2>&1 &

  _npm_pid=$!
  spin "$_npm_pid" "Installing packages (@$AZTEC_SDK_NPM_TAG)" || exit 1
fi

# Download the matching claim implementation from the migration branch.
# Do not execute an older cached script if downloading fails.
curl -fsSL "$REPO_RAW/scripts/claim-fee-juice.mjs" \
  -o ~/.aztec-devtools/claim-fee-juice.mjs || exit 1

_out=$(mktemp)

REPO_BRANCH="$REPO_BRANCH" \
  node ~/.aztec-devtools/claim-fee-juice.mjs \
  "$@" --network testnet --node-url "$AZTEC_NODE_URL" \
  < /dev/null > "$_out" 2>&1 &

_node_pid=$!
set +e
spin "$_node_pid" "Claiming Fee Juice on Aztec testnet (this may take 1-2 min)"
_code=$?
set -e

# On success: show the full node output (spinner frames stripped).
# On failure: try to extract just "Error:" lines; if none, fall back to the
# full output so non-error messages (e.g. the .mjs usage banner when args
# are missing) are still visible instead of leaving the user with just ✗.
if [ "$_code" = "0" ]; then
  sed "s/.*$(printf '\r')//" "$_out" |
    grep -v "MaxListenersExceededWarning\|Use emitter.setMaxListeners\|--trace-warnings" || true
else
  _err=$(
    grep -a "Error:" "$_out" |
      sed "s/.*$(printf '\r')//;s/$(printf '\033')\[[0-9;]*m//g"
  ) || true

  if [ -n "$_err" ]; then
    printf '\n%s\n\n' "$_err"
  else
    sed "s/.*$(printf '\r')//;s/$(printf '\033')\[[0-9;]*m//g" "$_out" |
      grep -v "MaxListenersExceededWarning\|Use emitter.setMaxListeners\|--trace-warnings" || true
  fi
fi

rm -f "$_out"
exit "$_code"
