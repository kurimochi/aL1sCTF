#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy_and_seed.sh [options]

Options:
  --network <env>                  Sui env name (default: testnet)
  --account <alias_or_address>     Sender account alias or 0x address (default: active address)
  --gas-budget <mist>              Gas budget for each tx (default: 200000000)
  --clock-id <object_id>           Clock object id (default: 0x6)

  --ctf-name <name>                CTF name (default: AL1S CTF)
  --ctf-arweave <txid>             CTF arweave tx id (default: ctf-meta)
  --ctf-start-ms <u64>             CTF start timestamp ms (default: now)
  --ctf-end-ms <u64>               CTF end timestamp ms (default: now + 1 day)

  --ctf-challenge-title <title>    CTF challenge title (default: Intro Challenge)
  --ctf-challenge-points <u64>     CTF challenge points (default: 100)
  --ctf-challenge-arweave <txid>   CTF challenge arweave tx id (default: ctf-challenge)
  --ctf-challenge-flag-hash <u256> CTF challenge flag hash u256 (default: 1)

  --standalone-title <title>       Standalone challenge title (default: Practice Challenge)
  --standalone-points <u64>        Standalone challenge points (default: 50)
  --standalone-arweave <txid>      Standalone challenge arweave tx id (default: standalone)
  --standalone-flag-hash <u256>    Standalone challenge flag hash u256 (default: 2)

  -h, --help                       Show help
EOF
}

NETWORK="testnet"
ACCOUNT_INPUT=""
GAS_BUDGET="200000000"
CLOCK_ID="0x6"

CTF_NAME="AL1S CTF"
CTF_ARWEAVE="ctf-meta"

NOW_MS=$(( $(date +%s) * 1000 ))
CTF_START_MS="${NOW_MS}"
CTF_END_MS="$(( NOW_MS + 86400000 ))"

CTF_CHALLENGE_TITLE="Intro Challenge"
CTF_CHALLENGE_POINTS="100"
CTF_CHALLENGE_ARWEAVE="ctf-challenge"
CTF_CHALLENGE_FLAG_HASH="1"

STANDALONE_TITLE="Practice Challenge"
STANDALONE_POINTS="50"
STANDALONE_ARWEAVE="standalone"
STANDALONE_FLAG_HASH="2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      NETWORK="$2"
      shift 2
      ;;
    --account)
      ACCOUNT_INPUT="$2"
      shift 2
      ;;
    --gas-budget)
      GAS_BUDGET="$2"
      shift 2
      ;;
    --clock-id)
      CLOCK_ID="$2"
      shift 2
      ;;
    --ctf-name)
      CTF_NAME="$2"
      shift 2
      ;;
    --ctf-arweave)
      CTF_ARWEAVE="$2"
      shift 2
      ;;
    --ctf-start-ms)
      CTF_START_MS="$2"
      shift 2
      ;;
    --ctf-end-ms)
      CTF_END_MS="$2"
      shift 2
      ;;
    --ctf-challenge-title)
      CTF_CHALLENGE_TITLE="$2"
      shift 2
      ;;
    --ctf-challenge-points)
      CTF_CHALLENGE_POINTS="$2"
      shift 2
      ;;
    --ctf-challenge-arweave)
      CTF_CHALLENGE_ARWEAVE="$2"
      shift 2
      ;;
    --ctf-challenge-flag-hash)
      CTF_CHALLENGE_FLAG_HASH="$2"
      shift 2
      ;;
    --standalone-title)
      STANDALONE_TITLE="$2"
      shift 2
      ;;
    --standalone-points)
      STANDALONE_POINTS="$2"
      shift 2
      ;;
    --standalone-arweave)
      STANDALONE_ARWEAVE="$2"
      shift 2
      ;;
    --standalone-flag-hash)
      STANDALONE_FLAG_HASH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required but not found" >&2
  exit 1
fi

ADDR_JSON="$(sui client addresses --json)"
ACTIVE_ADDRESS="$(printf '%s' "$ADDR_JSON" | jq -r '.activeAddress')"

resolve_account() {
  local input="$1"
  if [[ -z "$input" ]]; then
    printf '%s\n' "$ACTIVE_ADDRESS"
    return
  fi

  if [[ "$input" =~ ^0x[0-9a-fA-F]+$ ]]; then
    printf '%s\n' "$input"
    return
  fi

  local resolved
  resolved="$(printf '%s' "$ADDR_JSON" | jq -r --arg alias "$input" '.addresses[] | select(.[0] == $alias) | .[1]' | head -n1)"
  if [[ -z "$resolved" || "$resolved" == "null" ]]; then
    echo "Account alias not found: $input" >&2
    exit 1
  fi
  printf '%s\n' "$resolved"
}

normalize_u256() {
  local input="$1"

  if [[ "$input" =~ ^0x[0-9a-fA-F]+$ ]]; then
    python3 - "$input" <<'PY'
import sys
v = int(sys.argv[1], 16)
if v < 0 or v >= 2**256:
    raise SystemExit(1)
print(hex(v))
PY
    return
  fi

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    python3 - "$input" <<'PY'
import sys
v = int(sys.argv[1], 10)
if v < 0 or v >= 2**256:
    raise SystemExit(1)
print(hex(v))
PY
    return
  fi

  echo "Invalid u256 literal: ${input}" >&2
  echo "Use decimal digits or 0x-prefixed hex." >&2
  exit 1
}

SENDER="$(resolve_account "$ACCOUNT_INPUT")"
CTF_CHALLENGE_FLAG_HASH="$(normalize_u256 "$CTF_CHALLENGE_FLAG_HASH")"
STANDALONE_FLAG_HASH="$(normalize_u256 "$STANDALONE_FLAG_HASH")"

echo "==> switch env: ${NETWORK}"
sui client switch --env "$NETWORK" >/dev/null

echo "==> sender: ${SENDER}"

echo "==> publish package"
PUBLISH_JSON="$(sui client publish . --gas-budget "$GAS_BUDGET" --sender "$SENDER" --json)"

PACKAGE_ID="$(printf '%s' "$PUBLISH_JSON" | jq -r '.objectChanges[] | select(.type == "published") | .packageId' | head -n1)"
UPGRADE_CAP_ID="$(printf '%s' "$PUBLISH_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("0x2::package::UpgradeCap$"))) | .objectId' | head -n1)"
FLAG_VERIFIER_ID="$(printf '%s' "$PUBLISH_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::FlagVerifier$"))) | .objectId' | head -n1)"

echo "==> create ctf"
CREATE_CTF_JSON="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function create_ctf \
  --args "$CTF_NAME" "$CTF_ARWEAVE" "$CTF_START_MS" "$CTF_END_MS" "$CLOCK_ID" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --json)"

CTF_ID="$(printf '%s' "$CREATE_CTF_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::CTF$"))) | .objectId' | head -n1)"
CTF_ADMIN_CAP_ID="$(printf '%s' "$CREATE_CTF_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::CTFAdmin$"))) | .objectId' | head -n1)"

echo "==> grant one registration allowance to sender"
GRANT_CHALL_REG_CAP_JSON="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function batch_grant_chall_reg_caps \
  --args "$CTF_ID" "$CTF_ADMIN_CAP_ID" "[$SENDER]" "[1]" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --json)"

CHALL_REG_CAP_ID="$(printf '%s' "$GRANT_CHALL_REG_CAP_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::ChallRegCap$"))) | .objectId' | head -n1)"

echo "==> register ctf challenge"
CREATE_CTF_CHALLENGE_JSON="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function register_challenge_to_ctf \
  --args "$CTF_ID" "$CTF_CHALLENGE_TITLE" "$CTF_CHALLENGE_POINTS" "$CTF_CHALLENGE_ARWEAVE" "$CTF_CHALLENGE_FLAG_HASH" "$CHALL_REG_CAP_ID" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --json)"

CTF_CHALLENGE_ID="$(printf '%s' "$CREATE_CTF_CHALLENGE_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::Challenge$"))) | .objectId' | head -n1)"
CTF_CHALLENGE_AUTHOR_CAP_ID="$(printf '%s' "$CREATE_CTF_CHALLENGE_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::ChallengeAuthor$"))) | .objectId' | head -n1)"

echo "==> register standalone challenge"
CREATE_STANDALONE_CHALLENGE_JSON="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function register_challenge_standalone \
  --args "$STANDALONE_TITLE" "$STANDALONE_POINTS" "$STANDALONE_ARWEAVE" "$STANDALONE_FLAG_HASH" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --json)"

STANDALONE_CHALLENGE_ID="$(printf '%s' "$CREATE_STANDALONE_CHALLENGE_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::Challenge$"))) | .objectId' | head -n1)"
STANDALONE_CHALLENGE_AUTHOR_CAP_ID="$(printf '%s' "$CREATE_STANDALONE_CHALLENGE_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::ChallengeAuthor$"))) | .objectId' | head -n1)"

cat <<EOF

=== Deploy + Seed Result ===
NETWORK=${NETWORK}
SENDER=${SENDER}
PACKAGE_ID=${PACKAGE_ID}
UPGRADE_CAP_ID=${UPGRADE_CAP_ID}
FLAG_VERIFIER_ID=${FLAG_VERIFIER_ID}
CTF_ID=${CTF_ID}
CTF_ADMIN_CAP_ID=${CTF_ADMIN_CAP_ID}
CTF_CHALLENGE_ID=${CTF_CHALLENGE_ID}
CTF_CHALLENGE_AUTHOR_CAP_ID=${CTF_CHALLENGE_AUTHOR_CAP_ID}
STANDALONE_CHALLENGE_ID=${STANDALONE_CHALLENGE_ID}
STANDALONE_CHALLENGE_AUTHOR_CAP_ID=${STANDALONE_CHALLENGE_AUTHOR_CAP_ID}
EOF
