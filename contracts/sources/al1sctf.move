module al1sctf::al1sctf;

use std::string::String;
use sui::clock::{Self, Clock};
use sui::groth16;
use sui::table::{Self, Table};

// ============ Error Codes ============

const E_INVALID_CTF_TIME_RANGE: u64 = 1;
const E_CTF_ALREADY_ENDED: u64 = 2;
const E_ADMIN_CAP_MISMATCH: u64 = 3;
const E_LENGTH_MISMATCH: u64 = 4;
const E_CHALLENGE_REG_CAP_EXHAUSTED: u64 = 5;
const E_INVALID_FLAG_PROOF: u64 = 6;
const E_ALREADY_SOLVED: u64 = 7;
const E_CTF_NOT_STARTED: u64 = 8;
const E_CTF_ENDED: u64 = 9;
const E_CHALLENGE_NOT_IN_CTF: u64 = 10;
const E_INVALID_ALLOWANCE_AMOUNT: u64 = 11;
const E_CHALL_REG_CAP_MISMATCH: u64 = 12;

// ============ Structs ============

public struct CTF has key {
    id: UID,
    name: String,
    arweave_tx_id: String,
    start_time: u64,
    end_time: u64,
    scoreboard: Table<address, u64>,
}

public struct Challenge has key {
    id: UID,
    ctf_id: Option<ID>,
    title: String,
    points: u64,
    arweave_tx_id: String,
    flag_hash: u256,
    solvers: Table<address, SolverMarker>,
}

public struct SolverMarker has copy, drop, store {}

public struct FlagVerifier has key, store {
    id: UID,
    pvk: groth16::PreparedVerifyingKey,
}

// ============ Roles & Capabilities ============

public struct CTFAdmin has key, store {
    id: UID,
    ctf_id: ID,
}

public struct ChallengeAuthor has key, store {
    id: UID,
    chall_id: ID,
}

public struct ChallRegCap has key, store {
    id: UID,
    ctf_id: ID,
    allowance: u64,
}

// ============ `init` Function ============

fun init(ctx: &mut TxContext) {
    // FlagVerifier setup
    let vk_bytes: vector<u8> =
        x"40096167602fc75b47846da1025b782af29e8fd12b76996552722ce0109cf1968eaa65aba5297864eb5543b916f5e9c7b1aa7ccc44650ee00d826c2001a6540a675ee8a9fa89828d7fc18f824423444a59f5d6b7e93bcac0076f50700b67028cedf692d95cbdde46ddda5ef7d422436779445c5e66006a42761e1f12efde0018c212f3aeb785e49712e7a9353349aaf1255dfb31b7bf60723a480d9293938e1977c0af80649a70e2b8d17c1d82f24908ac98ae37484aa2bf36a452b7665d5d24986c7b606830e5ce8dc0ecae7f905fde3f434350392086ffbee64973e3d64480040000000000000026f7d911ffc3b0b3ac63b2694005d0733e8985447c77d09bcaba1f0e6251e80c4ebd33b4d7f0b868da9f0878181a36eec9f2dd5bbd3007c3ac3c424c0fb95c905f133632cfdabff2a5e3aa1e2c2dcb20ef2cec3989de61695959f024167e30a7b64cd32befd9d3e6cd27e07ffe78689ce593b423b4dc43f3f570e3c47065388d";
    let pvk = groth16::prepare_verifying_key(&groth16::bn254(), &vk_bytes);
    transfer::share_object(FlagVerifier { id: object::new(ctx), pvk });
}

// ============ Helper Functions ============

fun u256_to_le32_bytes(mut value: u256): vector<u8> {
    let mut bytes = vector::empty();
    let mut i = 0u8;
    while (i < 32) {
        bytes.push_back((value & 0xff) as u8);
        value = value >> 8;
        i = i + 1;
    };
    bytes
}

fun append_addr_half_as_le_u256(pi: &mut vector<u8>, addr: &vector<u8>, start: u64) {
    let mut i = 0u64;
    while (i < 16) {
        pi.push_back(addr[start + (15 - i)]);
        i = i + 1;
    };

    let mut j = 0u64;
    while (j < 16) {
        pi.push_back(0u8);
        j = j + 1;
    };
}

fun build_public_inputs(flag_hash: u256, solver: address): groth16::PublicProofInputs {
    let addr_bytes = solver.to_bytes();

    let mut pi_vec = vector::empty();
    pi_vec.append(u256_to_le32_bytes(flag_hash));
    append_addr_half_as_le_u256(&mut pi_vec, &addr_bytes, 16);
    append_addr_half_as_le_u256(&mut pi_vec, &addr_bytes, 0);

    groth16::public_proof_inputs_from_bytes(pi_vec)
}

// ============ Private Functions ============

fun verify_flag(
    verifier: &FlagVerifier,
    proof_bytes: vector<u8>,
    flag_hash: u256,
    solver: address,
): bool {
    let proof_points = groth16::proof_points_from_bytes(proof_bytes);

    let public_inputs = build_public_inputs(flag_hash, solver);

    groth16::verify_groth16_proof(&groth16::bn254(), &verifier.pvk, &public_inputs, &proof_points)
}

fun has_solver(challenge: &Challenge, solver: address): bool {
    challenge.solvers.contains(solver)
}

fun grant_chall_reg_cap_internal(
    admin_cap: &CTFAdmin,
    recipient: address,
    amount: u64,
    ctx: &mut TxContext,
) {
    let cap = ChallRegCap {
        id: object::new(ctx),
        ctf_id: admin_cap.ctf_id,
        allowance: amount,
    };
    transfer::public_transfer(cap, recipient);
}

fun solve_challenge_internal(
    challenge: &mut Challenge,
    verifier: &FlagVerifier,
    proof_bytes: vector<u8>,
    solver: address,
) {
    assert!(verifier.verify_flag(proof_bytes, challenge.flag_hash, solver), E_INVALID_FLAG_PROOF);
    assert!(!has_solver(challenge, solver), E_ALREADY_SOLVED);
    challenge.solvers.add(solver, SolverMarker {});
}

// ============ Entry Functions ============

entry fun create_ctf(
    name: String,
    arweave_tx_id: String,
    start_time: u64,
    end_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now_ms = clock::timestamp_ms(clock);
    assert!(start_time < end_time, E_INVALID_CTF_TIME_RANGE);
    assert!(now_ms < end_time, E_CTF_ALREADY_ENDED);

    let ctf = CTF {
        id: object::new(ctx),
        name,
        arweave_tx_id,
        start_time,
        end_time,
        scoreboard: table::new(ctx),
    };
    let admin_cap = CTFAdmin { id: object::new(ctx), ctf_id: object::id(&ctf) };

    transfer::share_object(ctf);
    transfer::public_transfer(admin_cap, ctx.sender());
}

entry fun change_ctf_name(ctf: &mut CTF, admin_cap: &CTFAdmin, new_name: String) {
    assert!(object::id(ctf) == admin_cap.ctf_id, E_ADMIN_CAP_MISMATCH);
    ctf.name = new_name;
}

entry fun change_ctf_arweave_tx_id(ctf: &mut CTF, admin_cap: &CTFAdmin, new_arweave_tx_id: String) {
    assert!(object::id(ctf) == admin_cap.ctf_id, E_ADMIN_CAP_MISMATCH);
    ctf.arweave_tx_id = new_arweave_tx_id;
}

entry fun grant_chall_reg_cap(
    ctf: &CTF,
    admin_cap: &CTFAdmin,
    recipient: address,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(object::id(ctf) == admin_cap.ctf_id, E_ADMIN_CAP_MISMATCH);
    assert!(amount > 0, E_INVALID_ALLOWANCE_AMOUNT);

    grant_chall_reg_cap_internal(admin_cap, recipient, amount, ctx);
}

entry fun batch_grant_chall_reg_caps(
    ctf: &CTF,
    admin_cap: &CTFAdmin,
    recipients: vector<address>,
    amounts: vector<u64>,
    ctx: &mut TxContext,
) {
    assert!(object::id(ctf) == admin_cap.ctf_id, E_ADMIN_CAP_MISMATCH);

    let len = recipients.length();
    assert!(len == amounts.length(), E_LENGTH_MISMATCH);

    let mut i = 0;
    while (i < len) {
        assert!(amounts[i] > 0, E_INVALID_ALLOWANCE_AMOUNT);
        i = i + 1;
    };

    i = 0;
    while (i < len) {
        grant_chall_reg_cap_internal(admin_cap, recipients[i], amounts[i], ctx);
        i = i + 1;
    }
}

entry fun register_challenge_to_ctf(
    ctf: &CTF,
    title: String,
    points: u64,
    arweave_tx_id: String,
    flag_hash: u256,
    cap: ChallRegCap,
    ctx: &mut TxContext,
) {
    assert!(cap.ctf_id == object::id(ctf), E_CHALL_REG_CAP_MISMATCH);
    assert!(cap.allowance > 0, E_CHALLENGE_REG_CAP_EXHAUSTED);

    let remaining = cap.allowance - 1;

    if (remaining > 0) {
        let mut mutable_cap = cap;
        mutable_cap.allowance = remaining;
        transfer::public_transfer(mutable_cap, ctx.sender());
    } else {
        let ChallRegCap { id, ctf_id: _, allowance: _ } = cap;
        id.delete();
    };

    let challenge = Challenge {
        id: object::new(ctx),
        ctf_id: option::some(object::id(ctf)),
        title,
        points,
        arweave_tx_id,
        flag_hash,
        solvers: table::new(ctx),
    };
    let author_cap = ChallengeAuthor { id: object::new(ctx), chall_id: object::id(&challenge) };

    transfer::share_object(challenge);
    transfer::public_transfer(author_cap, ctx.sender());
}

entry fun register_challenge_standalone(
    title: String,
    points: u64,
    arweave_tx_id: String,
    flag_hash: u256,
    ctx: &mut TxContext,
) {
    let challenge = Challenge {
        id: object::new(ctx),
        ctf_id: option::none(),
        title,
        points,
        arweave_tx_id,
        flag_hash,
        solvers: table::new(ctx),
    };
    let author_cap = ChallengeAuthor { id: object::new(ctx), chall_id: object::id(&challenge) };

    transfer::share_object(challenge);
    transfer::public_transfer(author_cap, ctx.sender());
}

entry fun submit_flag_to_challenge(
    challenge: &mut Challenge,
    verifier: &FlagVerifier,
    proof_bytes: vector<u8>,
    ctx: &TxContext,
) {
    solve_challenge_internal(challenge, verifier, proof_bytes, ctx.sender());
}

entry fun submit_flag_to_ctf(
    ctf: &mut CTF,
    challenge: &mut Challenge,
    proof_bytes: vector<u8>,
    verifier: &FlagVerifier,
    clock: &Clock,
    ctx: &TxContext,
) {
    let now_ms = clock::timestamp_ms(clock);
    assert!(ctf.start_time <= now_ms, E_CTF_NOT_STARTED);
    assert!(now_ms <= ctf.end_time, E_CTF_ENDED);
    assert!(challenge.ctf_id == option::some(object::id(ctf)), E_CHALLENGE_NOT_IN_CTF);
    solve_challenge_internal(challenge, verifier, proof_bytes, ctx.sender());

    if (!ctf.scoreboard.contains(ctx.sender())) {
        ctf.scoreboard.add(ctx.sender(), 0);
    };

    let score = ctf.scoreboard.borrow_mut(ctx.sender());
    *score = *score + challenge.points;
}
