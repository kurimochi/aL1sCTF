module al1sctf::al1sctf;

use std::string::String;
use sui::clock::{Self, Clock};
use sui::groth16;
use sui::hash::blake2b256;
use sui::table::{Self, Table};

// ============ Error Codes ============

const E_INVALID_CTF_TIME_RANGE: u64 = 1;
const E_CTF_ALREADY_ENDED: u64 = 2;
const E_ADMIN_CAP_MISMATCH: u64 = 3;
const E_LENGTH_MISMATCH: u64 = 4;
const E_CHALLENGE_REG_CAP_NOT_FOUND: u64 = 5;
const E_CHALLENGE_REG_CAP_EXHAUSTED: u64 = 6;
const E_INVALID_FLAG_PROOF: u64 = 7;
const E_ALREADY_SOLVED: u64 = 8;
const E_CTF_NOT_STARTED: u64 = 9;
const E_CTF_ENDED: u64 = 10;
const E_CHALLENGE_NOT_IN_CTF: u64 = 11;

// ============ Structs ============

public struct CTF has key {
    id: UID,
    name: String,
    arweave_tx_id: String,
    start_time: u64,
    end_time: u64,
    challenges: vector<ID>,
    scoreboard: Table<address, u64>,
}

public struct Challenge has key {
    id: UID,
    ctf_id: Option<ID>,
    title: String,
    points: u64,
    arweave_tx_id: String,
    flag_hash: u256,
    solvers: vector<address>,
}

public struct ChallRegCaps has key {
    id: UID,
    allowances: Table<vector<u8>, u64>,
}

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

// ============ `init` Function ============

fun init(ctx: &mut TxContext) {
    // ChallRegCaps setup
    let reg_cap = ChallRegCaps {
        id: object::new(ctx),
        allowances: table::new(ctx),
    };
    transfer::share_object(reg_cap);

    // FlagVerifier setup
    let vk_bytes: vector<u8> =
        x"40096167602fc75b47846da1025b782af29e8fd12b76996552722ce0109cf1968eaa65aba5297864eb5543b916f5e9c7b1aa7ccc44650ee00d826c2001a6540a675ee8a9fa89828d7fc18f824423444a59f5d6b7e93bcac0076f50700b67028cedf692d95cbdde46ddda5ef7d422436779445c5e66006a42761e1f12efde0018c212f3aeb785e49712e7a9353349aaf1255dfb31b7bf60723a480d9293938e1977c0af80649a70e2b8d17c1d82f24908ac98ae37484aa2bf36a452b7665d5d24986c7b606830e5ce8dc0ecae7f905fde3f434350392086ffbee64973e3d64480040000000000000026f7d911ffc3b0b3ac63b2694005d0733e8985447c77d09bcaba1f0e6251e80c4ebd33b4d7f0b868da9f0878181a36eec9f2dd5bbd3007c3ac3c424c0fb95c905f133632cfdabff2a5e3aa1e2c2dcb20ef2cec3989de61695959f024167e30a7b64cd32befd9d3e6cd27e07ffe78689ce593b423b4dc43f3f570e3c47065388d";
    let pvk = groth16::prepare_verifying_key(&groth16::bn254(), &vk_bytes);
    transfer::share_object(FlagVerifier { id: object::new(ctx), pvk });
}

// ============ Helper Functions ============

fun make_chall_reg_caps_key(ctf_id: ID, addr: address): vector<u8> {
    let mut bytes = vector::empty();

    bytes.append(ctf_id.to_bytes());
    bytes.append(addr.to_bytes());

    blake2b256(&bytes)
}

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
    let len = challenge.solvers.length();
    let mut i = 0;
    while (i < len) {
        if (challenge.solvers[i] == solver) {
            return true
        };
        i = i + 1;
    };
    false
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
        challenges: vector::empty(),
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

entry fun batch_grant_chall_reg_cap(
    ctf: &CTF,
    chall_reg_caps: &mut ChallRegCaps,
    admin_cap: &CTFAdmin,
    recipients: vector<address>,
    amount: vector<u64>,
) {
    assert!(object::id(ctf) == admin_cap.ctf_id, E_ADMIN_CAP_MISMATCH);

    let len = recipients.length();
    assert!(len == amount.length(), E_LENGTH_MISMATCH);

    let mut i = 0;
    while (i < len) {
        let key = make_chall_reg_caps_key(admin_cap.ctf_id, recipients[i]);

        if (!chall_reg_caps.allowances.contains(key)) {
            chall_reg_caps.allowances.add(key, 0);
        };

        let remaining = chall_reg_caps.allowances.borrow_mut(key);
        *remaining = *remaining + amount[i];
        i = i + 1;
    };
}

entry fun register_challenge_to_ctf(
    ctf: &mut CTF,
    title: String,
    points: u64,
    arweave_tx_id: String,
    flag_hash: u256,
    chall_reg_caps: &mut ChallRegCaps,
    ctx: &mut TxContext,
) {
    let key = make_chall_reg_caps_key(object::id(ctf), ctx.sender());
    assert!(chall_reg_caps.allowances.contains(key), E_CHALLENGE_REG_CAP_NOT_FOUND);

    let remaining = chall_reg_caps.allowances.borrow_mut(key);
    assert!(*remaining > 0, E_CHALLENGE_REG_CAP_EXHAUSTED);
    *remaining = *remaining - 1;

    if (*remaining == 0) {
        chall_reg_caps.allowances.remove(key);
    };

    let challenge = Challenge {
        id: object::new(ctx),
        ctf_id: option::some(object::id(ctf)),
        title,
        points,
        arweave_tx_id,
        flag_hash,
        solvers: vector::empty(),
    };
    let author_cap = ChallengeAuthor { id: object::new(ctx), chall_id: object::id(&challenge) };

    ctf.challenges.push_back(object::id(&challenge));

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
        solvers: vector::empty(),
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
    assert!(
        verifier.verify_flag(proof_bytes, challenge.flag_hash, ctx.sender()),
        E_INVALID_FLAG_PROOF,
    );
    assert!(!has_solver(challenge, ctx.sender()), E_ALREADY_SOLVED);
    challenge.solvers.push_back(ctx.sender());
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
    submit_flag_to_challenge(challenge, verifier, proof_bytes, ctx);

    if (!ctf.scoreboard.contains(ctx.sender())) {
        ctf.scoreboard.add(ctx.sender(), 0);
    };

    let score = ctf.scoreboard.borrow_mut(ctx.sender());
    *score = *score + challenge.points;
}
