pragma circom 2.2.1;

include "./node_modules/circomlib/circuits/bitify.circom";
include "./node_modules/circomlib/circuits/comparators.circom";
include "./node_modules/circomlib/circuits/poseidon.circom";

template VerifyFlag(maxLen) {
    signal input flag_bytes[maxLen];
    signal input actual_len;
    signal input solver[2];
    signal output hash_out;

    component actualLenBits = Num2Bits(8);
    actualLenBits.in <== actual_len;

    signal maxPlusOne <== maxLen + 1;
    component maxPlusBits = Num2Bits(8);
    maxPlusBits.in <== maxPlusOne;

    component lenLt = LessThan(8);
    lenLt.in[0] <== actual_len;
    lenLt.in[1] <== maxPlusOne;
    lenLt.out === 1;

    component byteCheck[maxLen];
    for (var i = 0; i < maxLen; i++) {
        byteCheck[i] = Num2Bits(8);
        byteCheck[i].in <== flag_bytes[i];
    }

    component isPastLen[maxLen];
    for (var i = 0; i < maxLen; i++) {
        isPastLen[i] = LessThan(8);
        isPastLen[i].in[0] <== i;
        isPastLen[i].in[1] <== actual_len;
        (1 - isPastLen[i].out) * flag_bytes[i] === 0;
    }

    signal solver_bound <== solver[0] * solver[1];
    solver_bound * 0 === 0;

    var nFields = 5;
    signal packed[nFields];

    for (var f = 0; f < 4; f++) {
        var sum = 0;
        for (var b = 0; b < 31; b++) {
            sum += flag_bytes[f * 31 + b] * (256 ** b);
        }
        packed[f] <== sum;
    }

    var lastSum = 0;
    for (var b = 0; b < 4; b++) {
        lastSum += flag_bytes[124 + b] * (256 ** b);
    }
    packed[4] <== lastSum;

    component hasher = Poseidon(6);
    hasher.inputs[0] <== actual_len;
    for (var f = 0; f < nFields; f++) {
        hasher.inputs[f + 1] <== packed[f];
    }
    hash_out <== hasher.out;
}

component main {public [solver]} = VerifyFlag(128);
