#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/measure_entry_gas.sh [options]

Measures gas for all entry functions in `al1sctf::al1sctf` via `sui client call --dry-run`.

Options:
  --network <env>                  Sui env name (default: testnet)
  --account <alias_or_address>     Sender account alias or 0x address (default: active address)
  --gas-budget <mist>              Gas budget per transaction (default: 200000000)
  --clock-id <object_id>           Clock object id (default: 0x6)
  -h, --help                       Show help

Notes:
  - This script publishes the package and creates seed objects on-chain.
  - `submit_flag_to_challenge` and `submit_flag_to_ctf` use an embedded proof byte array.
  - The proof is bound to a specific solver address via public inputs, so if sender does not
    match that address then submit dry-runs may fail with invalid proof.
EOF
}

NETWORK="testnet"
ACCOUNT_INPUT=""
GAS_BUDGET="200000000"
CLOCK_ID="0x6"
SUBMIT_FLAG_HASH="0x2035117803d9f6b2037eb3ce2ba52f72238c700d517703685baf59300add29b0"
PROOF_BYTES='[71,108,9,220,103,30,216,192,95,15,139,225,83,96,237,75,66,244,66,50,40,92,251,144,167,110,169,218,207,125,90,137,235,186,121,255,197,164,176,72,214,113,143,175,17,160,135,46,94,25,172,157,102,52,97,50,248,178,85,31,137,2,140,27,28,72,112,225,190,232,47,60,44,171,142,101,223,146,46,109,51,163,143,80,73,150,82,91,49,95,209,68,108,130,189,25,145,61,110,177,235,5,118,213,238,1,190,153,131,134,0,114,191,197,190,174,117,209,73,207,58,170,207,53,140,27,196,149]'

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

report_line() {
  local name="$1"
  local dry_json="$2"
  local status
  local error
  local computation
  local storage
  local rebate
  local non_refundable
  local total

  status="$(printf '%s' "$dry_json" | jq -r '.effects.status.status // .status.status // "unknown"')"
  error="$(printf '%s' "$dry_json" | jq -r '.effects.status.error // .status.error // ""')"
  computation="$(printf '%s' "$dry_json" | jq -r '.effects.gasUsed.computationCost // .gasUsed.computationCost // 0')"
  storage="$(printf '%s' "$dry_json" | jq -r '.effects.gasUsed.storageCost // .gasUsed.storageCost // 0')"
  rebate="$(printf '%s' "$dry_json" | jq -r '.effects.gasUsed.storageRebate // .gasUsed.storageRebate // 0')"
  non_refundable="$(printf '%s' "$dry_json" | jq -r '.effects.gasUsed.nonRefundableStorageFee // .gasUsed.nonRefundableStorageFee // 0')"
  total=$(( computation + storage - rebate ))

  printf '%-32s | %-7s | %12s | %12s | %12s | %12s | %12s\n' \
    "$name" "$status" "$computation" "$storage" "$rebate" "$non_refundable" "$total"

  if [[ -n "$error" && "$error" != "null" ]]; then
    printf '  error: %s\n' "$error"
  fi
}

SENDER="$(resolve_account "$ACCOUNT_INPUT")"

echo "==> switch env: ${NETWORK}"
sui client switch --env "$NETWORK" >/dev/null

echo "==> sender: ${SENDER}"
echo "==> publish package and create seed objects"

PUBLISH_JSON="$(sui client publish . --gas-budget "$GAS_BUDGET" --sender "$SENDER" --json)"

PACKAGE_ID="$(printf '%s' "$PUBLISH_JSON" | jq -r '.objectChanges[] | select(.type == "published") | .packageId' | head -n1)"
FLAG_VERIFIER_ID="$(printf '%s' "$PUBLISH_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::FlagVerifier$"))) | .objectId' | head -n1)"

NOW_MS=$(( $(date +%s) * 1000 ))
SEED_CTF_START_MS="$(( NOW_MS - 60000 ))"
SEED_CTF_END_MS="$(( NOW_MS + 86400000 ))"

CREATE_CTF_JSON="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function create_ctf \
  --args "seed-ctf" "seed-ctf-meta" "$SEED_CTF_START_MS" "$SEED_CTF_END_MS" "$CLOCK_ID" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --json)"

CTF_ID="$(printf '%s' "$CREATE_CTF_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::CTF$"))) | .objectId' | head -n1)"
CTF_ADMIN_CAP_ID="$(printf '%s' "$CREATE_CTF_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::CTFAdmin$"))) | .objectId' | head -n1)"

GRANT_CHALL_REG_CAP_JSON="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function batch_grant_chall_reg_caps \
  --args "$CTF_ID" "$CTF_ADMIN_CAP_ID" "[$SENDER]" "[10]" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --json)"

CHALL_REG_CAP_ID="$(printf '%s' "$GRANT_CHALL_REG_CAP_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::ChallRegCap$"))) | .objectId' | head -n1)"

CREATE_CTF_CHALLENGE_JSON="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function register_challenge_to_ctf \
  --args "$CTF_ID" "seed-ctf-challenge" "100" "seed-ctf-challenge-meta" "$SUBMIT_FLAG_HASH" "$CHALL_REG_CAP_ID" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --json)"

CTF_CHALLENGE_ID="$(printf '%s' "$CREATE_CTF_CHALLENGE_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::Challenge$"))) | .objectId' | head -n1)"

CREATE_STANDALONE_CHALLENGE_JSON="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function register_challenge_standalone \
  --args "seed-standalone" "50" "seed-standalone-meta" "$SUBMIT_FLAG_HASH" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --json)"

STANDALONE_CHALLENGE_ID="$(printf '%s' "$CREATE_STANDALONE_CHALLENGE_JSON" | jq -r '.objectChanges[] | select(.type == "created" and (.objectType | test("::al1sctf::Challenge$"))) | .objectId' | head -n1)"

echo
echo "==> dry-run gas report (all entry functions)"
printf '%-32s | %-7s | %12s | %12s | %12s | %12s | %12s\n' \
  "entry_function" "status" "computation" "storage" "rebate" "non_refund" "total"

DRY_CREATE_CTF="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function create_ctf \
  --args "report-ctf" "report-ctf-meta" "$SEED_CTF_START_MS" "$SEED_CTF_END_MS" "$CLOCK_ID" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "create_ctf" "$DRY_CREATE_CTF"

DRY_CHANGE_CTF_NAME="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function change_ctf_name \
  --args "$CTF_ID" "$CTF_ADMIN_CAP_ID" "renamed-ctf" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "change_ctf_name" "$DRY_CHANGE_CTF_NAME"

DRY_CHANGE_CTF_ARWEAVE="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function change_ctf_arweave_tx_id \
  --args "$CTF_ID" "$CTF_ADMIN_CAP_ID" "renamed-ctf-meta" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "change_ctf_arweave_tx_id" "$DRY_CHANGE_CTF_ARWEAVE"

DRY_GRANT_SINGLE="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function grant_chall_reg_cap \
  --args "$CTF_ID" "$CTF_ADMIN_CAP_ID" "$SENDER" "1" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "grant_chall_reg_cap" "$DRY_GRANT_SINGLE"

DRY_BATCH_GRANT="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function batch_grant_chall_reg_caps \
  --args "$CTF_ID" "$CTF_ADMIN_CAP_ID" "[$SENDER]" "[1]" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "batch_grant_chall_reg_caps" "$DRY_BATCH_GRANT"

DRY_REGISTER_CTF_CHALL="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function register_challenge_to_ctf \
  --args "$CTF_ID" "report-ctf-challenge" "200" "report-ctf-chall-meta" "0x3" "$CHALL_REG_CAP_ID" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "register_challenge_to_ctf" "$DRY_REGISTER_CTF_CHALL"

DRY_REGISTER_STANDALONE="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function register_challenge_standalone \
  --args "report-standalone" "80" "report-standalone-meta" "0x4" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "register_challenge_standalone" "$DRY_REGISTER_STANDALONE"

DRY_SUBMIT_CHALLENGE="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function submit_flag_to_challenge \
  --args "$STANDALONE_CHALLENGE_ID" "$FLAG_VERIFIER_ID" "$PROOF_BYTES" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "submit_flag_to_challenge" "$DRY_SUBMIT_CHALLENGE"

DRY_SUBMIT_CTF="$(sui client call \
  --package "$PACKAGE_ID" \
  --module al1sctf \
  --function submit_flag_to_ctf \
  --args "$CTF_ID" "$CTF_CHALLENGE_ID" "$PROOF_BYTES" "$FLAG_VERIFIER_ID" "$CLOCK_ID" \
  --gas-budget "$GAS_BUDGET" \
  --sender "$SENDER" \
  --dry-run \
  --json)"
report_line "submit_flag_to_ctf" "$DRY_SUBMIT_CTF"

echo
echo "==> context ids"
echo "PACKAGE_ID=$PACKAGE_ID"
echo "CTF_ID=$CTF_ID"
echo "CTF_ADMIN_CAP_ID=$CTF_ADMIN_CAP_ID"
echo "CHALL_REG_CAP_ID=$CHALL_REG_CAP_ID"
echo "CTF_CHALLENGE_ID=$CTF_CHALLENGE_ID"
echo "STANDALONE_CHALLENGE_ID=$STANDALONE_CHALLENGE_ID"
echo "FLAG_VERIFIER_ID=$FLAG_VERIFIER_ID"
