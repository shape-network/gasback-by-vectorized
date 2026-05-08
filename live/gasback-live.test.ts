import { describe, expect, test } from "bun:test";
import {
    DENOMINATOR,
    assertSpendWithinBudget,
    buildCanaryGasValues,
    computeOracle,
    parseWei,
    normalizePrivateKeyInput,
    receiptFee,
    stringifyReport,
} from "./gasback-live";
import type { TransactionReceipt } from "viem";

describe("gasback oracle", () => {
    test("computes payout and accrued delta with integer rounding", () => {
        const result = computeOracle({
            gasToBurn: 333n,
            baseFee: 100n,
            ratioNumerator: 600_000_000_000_000_000n,
            shareNumerator: 700_000_000_000_000_000n,
            maxBaseFee: 1_000n,
            gasbackBalanceBefore: 1_000_000n,
        });

        expect(result.ethFromGas).toBe(33_300n);
        expect(result.expectedPayout).toBe(19_980n);
        expect(result.expectedShare).toBe(23_310n);
        expect(result.expectedAccruedDelta).toBe(3_330n);
        expect(result.passThrough).toBe(false);
    });

    test("passes through when base fee exceeds max", () => {
        const result = computeOracle({
            gasToBurn: 30_000n,
            baseFee: 101n,
            ratioNumerator: DENOMINATOR,
            shareNumerator: DENOMINATOR,
            maxBaseFee: 100n,
            gasbackBalanceBefore: 3_030_000n,
        });

        expect(result.expectedPayout).toBe(0n);
        expect(result.expectedAccruedDelta).toBe(0n);
        expect(result.passThrough).toBe(true);
    });

    test("passes through when the local gasback buffer is insufficient", () => {
        const result = computeOracle({
            gasToBurn: 30_000n,
            baseFee: 100n,
            ratioNumerator: DENOMINATOR,
            shareNumerator: DENOMINATOR,
            maxBaseFee: 100n,
            gasbackBalanceBefore: 2_999_999n,
        });

        expect(result.expectedPayout).toBe(0n);
        expect(result.expectedAccruedDelta).toBe(0n);
        expect(result.passThrough).toBe(true);
    });
});

describe("canary guards", () => {
    test("selects zero, small, and bounded medium canaries", () => {
        expect(buildCanaryGasValues(120_000n)).toEqual([0n, 30_000n, 120_000n]);
        expect(buildCanaryGasValues(30_000n)).toEqual([0n, 30_000n]);
        expect(buildCanaryGasValues(1n)).toEqual([0n]);
    });

    test("parses decimal and hex wei values", () => {
        expect(parseWei("123", "VALUE")).toBe(123n);
        expect(parseWei("0x10", "VALUE")).toBe(16n);
        expect(() => parseWei("", "VALUE")).toThrow("VALUE is empty");
        expect(() => parseWei("-1", "VALUE")).toThrow("VALUE must be non-negative");
        expect(() => parseWei("1.2", "VALUE")).toThrow("VALUE must be a decimal or hex integer");
    });

    test("normalizes private keys without accepting malformed input", () => {
        const raw = "1".repeat(64);
        expect(normalizePrivateKeyInput(raw)).toBe(`0x${raw}`);
        expect(normalizePrivateKeyInput(`0x${raw}`)).toBe(`0x${raw}`);
        expect(() => normalizePrivateKeyInput("0x1")).toThrow("PRIVATE_KEY must be 32 bytes");
    });

    test("rejects estimated spend over the remaining budget", () => {
        expect(() => assertSpendWithinBudget(10n, 10n, "case")).not.toThrow();
        expect(() => assertSpendWithinBudget(11n, 10n, "case")).toThrow(
            "case estimated cost 11 exceeds remaining budget 10",
        );
    });
});

describe("reporting", () => {
    test("serializes bigint values as strings", () => {
        expect(stringifyReport({ value: 1n })).toBe('{\n  "value": "1"\n}');
    });

    test("adds OP Stack fee fields to execution fees when present", () => {
        const receipt = {
            gasUsed: 10n,
            effectiveGasPrice: 20n,
            l1Fee: "0x64",
        } as unknown as TransactionReceipt;
        expect(receiptFee(receipt)).toEqual({
            executionFee: 200n,
            extraReceiptFee: 100n,
            totalFee: 300n,
        });
    });
});
