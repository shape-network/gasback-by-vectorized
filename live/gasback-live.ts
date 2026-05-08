import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import {
    createPublicClient,
    createWalletClient,
    decodeEventLog,
    defineChain,
    encodeDeployData,
    getAddress,
    http,
    isAddress,
    keccak256,
    parseAbi,
    type Abi,
    type Address,
    type Hex,
    type PublicClient,
    type TransactionReceipt,
    type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const SHAPE_SEPOLIA_CHAIN_ID = 11011;
export const DEFAULT_GASBACK_ADDRESS = "0x21e34c5bea9253CDCd57671A1970BB31df4aBe83";
export const DEFAULT_SPLITTER_ADDRESS = "0x658E643b379b52Cd21605bFaF9C81e84713d8427";
export const DEFAULT_GASBACK_TEST_CALLER_ADDRESS =
    "0xA53D127f193858f5ef2Cf50dd1B3A94198ef811d";
export const DENOMINATOR = 1_000_000_000_000_000_000n;

const gasbackAbi = parseAbi([
    "function GASBACK_RATIO_DENOMINATOR() view returns (uint256)",
    "function gasbackRatioNumerator() view returns (uint256)",
    "function baseFeeVaultShareNumerator() view returns (uint256)",
    "function gasbackMaxBaseFee() view returns (uint256)",
    "function baseFeeVault() view returns (address)",
    "function accrued() view returns (uint256)",
]);

const splitterAbi = parseAbi([
    "function totalShares() view returns (uint256)",
    "function shares(address account) view returns (uint256)",
    "function releasable(address account) view returns (uint256)",
]);

const testCallerAbi = parseAbi(["function GASBACK() view returns (address)"]);

const vaultAddressAbi = parseAbi([
    "function recipient() view returns (address)",
    "function RECIPIENT() view returns (address)",
]);

const vaultUintAbi = parseAbi([
    "function withdrawalNetwork() view returns (uint256)",
    "function WITHDRAWAL_NETWORK() view returns (uint256)",
]);

export type GasbackOracleInput = {
    gasToBurn: bigint;
    baseFee: bigint;
    ratioNumerator: bigint;
    shareNumerator: bigint;
    maxBaseFee: bigint;
    gasbackBalanceBefore: bigint;
};

export type GasbackOracleOutput = {
    ethFromGas: bigint;
    expectedShare: bigint;
    expectedPayout: bigint;
    expectedAccruedDelta: bigint;
    passThrough: boolean;
};

export type LiveConfig = {
    rpcUrl: string;
    gasback: Address;
    splitter: Address;
    testCaller: Address;
    probe?: Address;
    maxWeiSpend?: bigint;
    maxGasToBurn?: bigint;
    reportPath: string;
};

type ForgeArtifact = {
    abi: Abi;
    bytecode: { object: Hex };
    deployedBytecode: { object: Hex };
};

type GasbackState = {
    ratioNumerator: bigint;
    shareNumerator: bigint;
    maxBaseFee: bigint;
    baseFeeVault: Address;
    accrued: bigint;
    balance: bigint;
};

type AuditReport = {
    chainId: number;
    addresses: {
        gasback: Address;
        splitter: Address;
        testCaller: Address;
    };
    deployment: {
        gasbackCodeHash: Hex;
        localGasbackCodeHash: Hex;
        gasbackCodeMatchesArtifact: boolean;
        gasbackCodeBytes: number;
        splitterCodeBytes: number;
        testCallerCodeBytes: number;
    };
    gasback: {
        ratioNumerator: string;
        baseFeeVaultShareNumerator: string;
        gasbackMaxBaseFee: string;
        baseFeeVault: Address;
        baseFeeVaultCodeBytes: number;
    };
    splitter: {
        totalShares: string;
        gasbackShares: string;
        impliedGasbackShareNumerator: string;
        matchesGasbackShareNumerator: boolean;
        releasableToGasback: string;
    };
    testCaller: {
        gasback: Address;
        matchesGasback: boolean;
    };
    vault: {
        recipientSupported: boolean;
        recipient?: Address;
        recipientMatchesSplitter?: boolean;
        withdrawalNetworkSupported: boolean;
        withdrawalNetwork?: string;
        withdrawalNetworkIsL2?: boolean;
    };
    failures: string[];
};

type ProbeEvent = {
    gasToBurn: bigint;
    blockBaseFee: bigint;
    payout: bigint;
    accruedBefore: bigint;
    accruedAfter: bigint;
    gasbackBalanceBefore: bigint;
    gasbackBalanceAfter: bigint;
};

type CanaryResult = {
    gasToBurn: string;
    transactionHash: Hex;
    blockNumber: string;
    payout: string;
    accruedDelta: string;
    expectedPayout: string;
    expectedAccruedDelta: string;
    gasbackBalanceBefore: string;
    gasbackBalanceAfter: string;
    probeBalanceDelta: string;
    executionFee: string;
    extraReceiptFee: string;
    totalFee: string;
    netProbeGainAfterFees: string;
    profitable: boolean;
    failures: string[];
};

type GasbackLiveReport = {
    generatedAt: string;
    mode: "report" | "canary";
    audit: AuditReport;
    probe?: Address;
    canaries: CanaryResult[];
    failures: string[];
};

export class GasbackLiveError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "GasbackLiveError";
    }
}

export function computeOracle(input: GasbackOracleInput): GasbackOracleOutput {
    const ethFromGas = input.gasToBurn * input.baseFee;
    const expectedShare = (ethFromGas * input.shareNumerator) / DENOMINATOR;
    let expectedPayout = (ethFromGas * input.ratioNumerator) / DENOMINATOR;
    let expectedAccruedDelta = expectedShare - expectedPayout;
    let passThrough = false;

    if (input.baseFee > input.maxBaseFee || expectedPayout > input.gasbackBalanceBefore) {
        expectedPayout = 0n;
        expectedAccruedDelta = 0n;
        passThrough = true;
    }

    return { ethFromGas, expectedShare, expectedPayout, expectedAccruedDelta, passThrough };
}

export function buildCanaryGasValues(maxGasToBurn: bigint): bigint[] {
    const candidates = [0n, 30_000n, 120_000n]
        .filter((value) => value <= maxGasToBurn)
        .filter((value, index, values) => values.indexOf(value) === index);
    if (candidates.length === 0 || candidates[0] !== 0n) {
        candidates.unshift(0n);
    }
    return candidates;
}

export function parseWei(value: string, name: string): bigint {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
        throw new GasbackLiveError(`${name} is empty`);
    }
    try {
        const parsed = trimmed.startsWith("0x") ? BigInt(trimmed) : BigInt(trimmed);
        if (parsed < 0n) {
            throw new GasbackLiveError(`${name} must be non-negative`);
        }
        return parsed;
    } catch (error) {
        if (error instanceof GasbackLiveError) {
            throw error;
        }
        throw new GasbackLiveError(`${name} must be a decimal or hex integer`);
    }
}

export function normalizePrivateKeyInput(value: string): Hex {
    return normalizePrivateKey(value);
}

function normalizePrivateKey(privateKey: string): Hex {
    const normalized = privateKey.startsWith("0x") ? privateKey : `0x${privateKey}`;
    if (!/^0x[0-9a-fA-F]{64}$/.test(normalized)) {
        throw new GasbackLiveError("PRIVATE_KEY must be 32 bytes");
    }
    return normalized as Hex;
}

function readPrivateKey(): Hex {
    const privateKey = process.env.PRIVATE_KEY;
    if (!privateKey) {
        throw new GasbackLiveError("PRIVATE_KEY is required");
    }
    return normalizePrivateKey(privateKey);
}

export function assertSpendWithinBudget(cost: bigint, remainingBudget: bigint, label: string) {
    if (cost > remainingBudget) {
        throw new GasbackLiveError(
            `${label} estimated cost ${cost.toString()} exceeds remaining budget ${remainingBudget.toString()}`,
        );
    }
}

export function receiptFee(receipt: TransactionReceipt): {
    executionFee: bigint;
    extraReceiptFee: bigint;
    totalFee: bigint;
} {
    const executionFee = receipt.gasUsed * receipt.effectiveGasPrice;
    const extraReceiptFee = ["l1Fee", "l1DataFee", "operatorFee"].reduce((sum, key) => {
        const value = (receipt as unknown as Record<string, unknown>)[key];
        return sum + unknownWei(value);
    }, 0n);
    return { executionFee, extraReceiptFee, totalFee: executionFee + extraReceiptFee };
}

export function stringifyReport(report: unknown): string {
    return JSON.stringify(
        report,
        (_key, value) => (typeof value === "bigint" ? value.toString() : value),
        2,
    );
}

async function main() {
    const mode = process.argv[2];
    if (mode === "local") {
        await runProcess("forge", ["test", "--offline", "--disable-labels"]);
        return;
    }
    if (mode === "fork") {
        const args = ["test", "--disable-labels", "--match-path", "test/GasbackLiveFork.t.sol"];
        if (!process.env.SHAPE_SEPOLIA_RPC_URL) {
            args.splice(1, 0, "--offline");
        }
        await runProcess("forge", args);
        return;
    }
    if (mode === "report") {
        const config = readConfig(false);
        const report = await buildReport(config);
        writeReport(config.reportPath, report);
        assertNoFailures(report.failures);
        return;
    }
    if (mode === "canary") {
        const config = readConfig(true);
        const report = await buildCanaryReport(config);
        writeReport(config.reportPath, report);
        assertNoFailures(report.failures);
        return;
    }

    throw new GasbackLiveError("Usage: bun run live/gasback-live.ts <local|fork|report|canary>");
}

function readConfig(requireCanary: boolean): LiveConfig {
    const rpcUrl = process.env.SHAPE_SEPOLIA_RPC_URL;
    if (!rpcUrl) {
        throw new GasbackLiveError("SHAPE_SEPOLIA_RPC_URL is required");
    }

    const config: LiveConfig = {
        rpcUrl,
        gasback: readAddress("GASBACK_ADDRESS", DEFAULT_GASBACK_ADDRESS),
        splitter: readAddress("SPLITTER_ADDRESS", DEFAULT_SPLITTER_ADDRESS),
        testCaller: readAddress("GASBACK_TEST_CALLER_ADDRESS", DEFAULT_GASBACK_TEST_CALLER_ADDRESS),
        probe: process.env.GASBACK_LIVE_PROBE_ADDRESS
            ? readAddress("GASBACK_LIVE_PROBE_ADDRESS", process.env.GASBACK_LIVE_PROBE_ADDRESS)
            : undefined,
        maxWeiSpend: process.env.MAX_WEI_SPEND
            ? parseWei(process.env.MAX_WEI_SPEND, "MAX_WEI_SPEND")
            : undefined,
        maxGasToBurn: process.env.MAX_GAS_TO_BURN
            ? parseWei(process.env.MAX_GAS_TO_BURN, "MAX_GAS_TO_BURN")
            : undefined,
        reportPath: process.env.REPORT_PATH ?? "gasback-live-report.json",
    };

    if (requireCanary) {
        if (!process.env.PRIVATE_KEY) {
            throw new GasbackLiveError("PRIVATE_KEY is required for canary mode");
        }
        if (config.maxWeiSpend === undefined) {
            throw new GasbackLiveError("MAX_WEI_SPEND is required for canary mode");
        }
        if (config.maxGasToBurn === undefined) {
            throw new GasbackLiveError("MAX_GAS_TO_BURN is required for canary mode");
        }
    }

    return config;
}

async function buildReport(config: LiveConfig): Promise<GasbackLiveReport> {
    const client = publicClient(config);
    const audit = await runAudit(config, client);
    return {
        generatedAt: new Date().toISOString(),
        mode: "report",
        audit,
        canaries: [],
        failures: [...audit.failures],
    };
}

async function buildCanaryReport(config: LiveConfig): Promise<GasbackLiveReport> {
    const client = publicClient(config);
    const wallet = walletClient(config);
    const audit = await runAudit(config, client);
    const report: GasbackLiveReport = {
        generatedAt: new Date().toISOString(),
        mode: "canary",
        audit,
        canaries: [],
        failures: [...audit.failures],
    };

    if (report.failures.length !== 0) {
        return report;
    }

    let remainingBudget = config.maxWeiSpend ?? 0n;
    const account = privateKeyToAccount(readPrivateKey());
    const probe = await resolveProbe(config, client, wallet, account.address, remainingBudget);
    report.probe = probe.address;
    remainingBudget -= probe.estimatedCost;

    const gasValues = buildCanaryGasValues(config.maxGasToBurn ?? 0n);
    for (const gasToBurn of gasValues) {
        const result = await runCanaryCase({
            config,
            client,
            wallet,
            probeAddress: probe.address,
            account: account.address,
            gasToBurn,
            remainingBudget,
        });
        remainingBudget -= result.estimatedCost;
        report.canaries.push(result.result);
        report.failures.push(...result.result.failures);
    }

    return report;
}

async function runAudit(config: LiveConfig, client: PublicClient): Promise<AuditReport> {
    const gasbackArtifact = loadArtifact("out/Gasback.sol/Gasback.json");
    const chainId = await client.getChainId();
    const gasbackCode = await getCode(client, config.gasback);
    const splitterCode = await getCode(client, config.splitter);
    const testCallerCode = await getCode(client, config.testCaller);

    const state = await readGasbackState(client, config.gasback);
    const [denominator, totalShares, gasbackShares, releasableToGasback, testCallerGasback] =
        await Promise.all([
            client.readContract({
                address: config.gasback,
                abi: gasbackAbi,
                functionName: "GASBACK_RATIO_DENOMINATOR",
            }),
            client.readContract({
                address: config.splitter,
                abi: splitterAbi,
                functionName: "totalShares",
            }),
            client.readContract({
                address: config.splitter,
                abi: splitterAbi,
                functionName: "shares",
                args: [config.gasback],
            }),
            client.readContract({
                address: config.splitter,
                abi: splitterAbi,
                functionName: "releasable",
                args: [config.gasback],
            }),
            client.readContract({
                address: config.testCaller,
                abi: testCallerAbi,
                functionName: "GASBACK",
            }),
        ]);

    const baseFeeVaultCode = await getCode(client, state.baseFeeVault);
    const impliedShare = totalShares === 0n ? 0n : (gasbackShares * DENOMINATOR) / totalShares;
    const liveCodeHash = keccak256(gasbackCode);
    const localCodeHash = keccak256(gasbackArtifact.deployedBytecode.object);
    const vault = await readVaultAudit(client, state.baseFeeVault, config.splitter);

    const report: AuditReport = {
        chainId,
        addresses: {
            gasback: config.gasback,
            splitter: config.splitter,
            testCaller: config.testCaller,
        },
        deployment: {
            gasbackCodeHash: liveCodeHash,
            localGasbackCodeHash: localCodeHash,
            gasbackCodeMatchesArtifact: liveCodeHash === localCodeHash,
            gasbackCodeBytes: byteLength(gasbackCode),
            splitterCodeBytes: byteLength(splitterCode),
            testCallerCodeBytes: byteLength(testCallerCode),
        },
        gasback: {
            ratioNumerator: state.ratioNumerator.toString(),
            baseFeeVaultShareNumerator: state.shareNumerator.toString(),
            gasbackMaxBaseFee: state.maxBaseFee.toString(),
            baseFeeVault: state.baseFeeVault,
            baseFeeVaultCodeBytes: byteLength(baseFeeVaultCode),
        },
        splitter: {
            totalShares: totalShares.toString(),
            gasbackShares: gasbackShares.toString(),
            impliedGasbackShareNumerator: impliedShare.toString(),
            matchesGasbackShareNumerator: impliedShare === state.shareNumerator,
            releasableToGasback: releasableToGasback.toString(),
        },
        testCaller: {
            gasback: getAddress(testCallerGasback),
            matchesGasback: getAddress(testCallerGasback) === config.gasback,
        },
        vault,
        failures: [],
    };

    if (chainId !== SHAPE_SEPOLIA_CHAIN_ID) {
        report.failures.push(`wrong chain id: expected ${SHAPE_SEPOLIA_CHAIN_ID}, got ${chainId}`);
    }
    if (gasbackCode === "0x") report.failures.push("gasback has no code");
    if (splitterCode === "0x") report.failures.push("splitter has no code");
    if (testCallerCode === "0x") report.failures.push("test caller has no code");
    if (!report.deployment.gasbackCodeMatchesArtifact) {
        report.failures.push("gasback deployed bytecode does not match local artifact");
    }
    if (denominator !== DENOMINATOR) {
        report.failures.push(`unexpected denominator: ${denominator.toString()}`);
    }
    if (state.ratioNumerator > state.shareNumerator) {
        report.failures.push("gasback ratio numerator exceeds base fee vault share numerator");
    }
    if (state.shareNumerator > DENOMINATOR) {
        report.failures.push("base fee vault share numerator exceeds denominator");
    }
    if (baseFeeVaultCode === "0x") {
        report.failures.push("base fee vault has no code");
    }
    if (totalShares === 0n) {
        report.failures.push("splitter total shares is zero");
    }
    if (gasbackShares === 0n) {
        report.failures.push("splitter gives gasback zero shares");
    }
    if (impliedShare !== state.shareNumerator) {
        report.failures.push(
            `splitter implied gasback share ${impliedShare.toString()} does not match gasback share numerator ${state.shareNumerator.toString()}`,
        );
    }
    if (!report.testCaller.matchesGasback) {
        report.failures.push("test caller points at a different gasback address");
    }
    if (vault.recipientSupported && !vault.recipientMatchesSplitter) {
        report.failures.push("base fee vault recipient does not match splitter");
    }
    if (vault.withdrawalNetworkSupported && !vault.withdrawalNetworkIsL2) {
        report.failures.push("base fee vault withdrawal network is not 1");
    }

    return report;
}

async function runCanaryCase(input: {
    config: LiveConfig;
    client: PublicClient;
    wallet: WalletClient;
    probeAddress: Address;
    account: Address;
    gasToBurn: bigint;
    remainingBudget: bigint;
}): Promise<{ estimatedCost: bigint; result: CanaryResult }> {
    if (input.config.maxGasToBurn !== undefined && input.gasToBurn > input.config.maxGasToBurn) {
        throw new GasbackLiveError(
            `gasToBurn ${input.gasToBurn.toString()} exceeds MAX_GAS_TO_BURN ${input.config.maxGasToBurn.toString()}`,
        );
    }

    const state = await readGasbackState(input.client, input.config.gasback);
    const block = await input.client.getBlock();
    const baseFee = block.baseFeePerGas ?? 0n;
    const preOracle = computeOracle({
        gasToBurn: input.gasToBurn,
        baseFee,
        ratioNumerator: state.ratioNumerator,
        shareNumerator: state.shareNumerator,
        maxBaseFee: state.maxBaseFee,
        gasbackBalanceBefore: state.balance,
    });

    if (input.gasToBurn !== 0n && preOracle.passThrough) {
        throw new GasbackLiveError(
            `refusing canary gasToBurn ${input.gasToBurn.toString()} because the current buffer would pass through`,
        );
    }

    const probeArtifact = loadArtifact("out/GasbackLiveProbe.sol/GasbackLiveProbe.json");
    await input.client.simulateContract({
        address: input.probeAddress,
        abi: probeArtifact.abi,
        functionName: "probe",
        args: [input.gasToBurn],
        account: input.account,
    });
    const gas = await input.client.estimateContractGas({
        address: input.probeAddress,
        abi: probeArtifact.abi,
        functionName: "probe",
        args: [input.gasToBurn],
        account: input.account,
    });
    const estimatedCost = gas * (await feeCap(input.client));
    assertSpendWithinBudget(
        estimatedCost,
        input.remainingBudget,
        `probe(${input.gasToBurn.toString()})`,
    );

    const probeBalanceBefore = await input.client.getBalance({ address: input.probeAddress });
    const hash = await input.wallet.writeContract({
        address: input.probeAddress,
        abi: probeArtifact.abi,
        functionName: "probe",
        args: [input.gasToBurn],
        account: input.account,
        chain: shapeSepolia(input.config.rpcUrl),
    });
    const receipt = await input.client.waitForTransactionReceipt({ hash });
    const probeBalanceAfter = await input.client.getBalance({ address: input.probeAddress });
    const event = decodeProbeResult(probeArtifact.abi, input.probeAddress, receipt);
    const fee = receiptFee(receipt);
    const accruedDelta = event.accruedAfter - event.accruedBefore;
    const probeBalanceDelta = probeBalanceAfter - probeBalanceBefore;
    const oracle = computeOracle({
        gasToBurn: event.gasToBurn,
        baseFee: event.blockBaseFee,
        ratioNumerator: state.ratioNumerator,
        shareNumerator: state.shareNumerator,
        maxBaseFee: state.maxBaseFee,
        gasbackBalanceBefore: event.gasbackBalanceBefore,
    });
    const netProbeGainAfterFees = probeBalanceDelta - fee.totalFee;
    const failures: string[] = [];

    if (event.payout !== oracle.expectedPayout) {
        failures.push(
            `payout mismatch: expected ${oracle.expectedPayout.toString()}, got ${event.payout.toString()}`,
        );
    }
    if (accruedDelta !== oracle.expectedAccruedDelta) {
        failures.push(
            `accrued delta mismatch: expected ${oracle.expectedAccruedDelta.toString()}, got ${accruedDelta.toString()}`,
        );
    }
    if (probeBalanceDelta !== event.payout) {
        failures.push(
            `probe balance delta ${probeBalanceDelta.toString()} does not equal payout ${event.payout.toString()}`,
        );
    }
    if (netProbeGainAfterFees > 0n) {
        failures.push(
            `profitable canary observed: net probe gain after fees ${netProbeGainAfterFees.toString()}`,
        );
    }

    return {
        estimatedCost,
        result: {
            gasToBurn: event.gasToBurn.toString(),
            transactionHash: receipt.transactionHash,
            blockNumber: receipt.blockNumber.toString(),
            payout: event.payout.toString(),
            accruedDelta: accruedDelta.toString(),
            expectedPayout: oracle.expectedPayout.toString(),
            expectedAccruedDelta: oracle.expectedAccruedDelta.toString(),
            gasbackBalanceBefore: event.gasbackBalanceBefore.toString(),
            gasbackBalanceAfter: event.gasbackBalanceAfter.toString(),
            probeBalanceDelta: probeBalanceDelta.toString(),
            executionFee: fee.executionFee.toString(),
            extraReceiptFee: fee.extraReceiptFee.toString(),
            totalFee: fee.totalFee.toString(),
            netProbeGainAfterFees: netProbeGainAfterFees.toString(),
            profitable: netProbeGainAfterFees > 0n,
            failures,
        },
    };
}

async function resolveProbe(
    config: LiveConfig,
    client: PublicClient,
    wallet: WalletClient,
    account: Address,
    remainingBudget: bigint,
): Promise<{ address: Address; estimatedCost: bigint }> {
    const artifact = loadArtifact("out/GasbackLiveProbe.sol/GasbackLiveProbe.json");
    if (config.probe) {
        const code = await getCode(client, config.probe);
        if (code === "0x") {
            throw new GasbackLiveError("GASBACK_LIVE_PROBE_ADDRESS has no code");
        }
        const target = await client.readContract({
            address: config.probe,
            abi: artifact.abi,
            functionName: "GASBACK",
        });
        if (getAddress(target as Address) !== config.gasback) {
            throw new GasbackLiveError("GASBACK_LIVE_PROBE_ADDRESS points at a different gasback");
        }
        return { address: config.probe, estimatedCost: 0n };
    }

    const data = encodeDeployData({
        abi: artifact.abi,
        bytecode: artifact.bytecode.object,
        args: [config.gasback],
    });
    const gas = await client.estimateGas({ account, data });
    const estimatedCost = gas * (await feeCap(client));
    assertSpendWithinBudget(estimatedCost, remainingBudget, "GasbackLiveProbe deployment");

    const hash = await wallet.deployContract({
        abi: artifact.abi,
        bytecode: artifact.bytecode.object,
        args: [config.gasback],
        account,
        chain: shapeSepolia(config.rpcUrl),
    });
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (!receipt.contractAddress) {
        throw new GasbackLiveError("probe deployment receipt did not include a contract address");
    }
    return { address: getAddress(receipt.contractAddress), estimatedCost };
}

async function readGasbackState(client: PublicClient, gasback: Address): Promise<GasbackState> {
    const [
        ratioNumerator,
        shareNumerator,
        maxBaseFee,
        baseFeeVault,
        accrued,
        balance,
    ] = await Promise.all([
        client.readContract({ address: gasback, abi: gasbackAbi, functionName: "gasbackRatioNumerator" }),
        client.readContract({
            address: gasback,
            abi: gasbackAbi,
            functionName: "baseFeeVaultShareNumerator",
        }),
        client.readContract({ address: gasback, abi: gasbackAbi, functionName: "gasbackMaxBaseFee" }),
        client.readContract({ address: gasback, abi: gasbackAbi, functionName: "baseFeeVault" }),
        client.readContract({ address: gasback, abi: gasbackAbi, functionName: "accrued" }),
        client.getBalance({ address: gasback }),
    ]);
    return {
        ratioNumerator,
        shareNumerator,
        maxBaseFee,
        baseFeeVault: getAddress(baseFeeVault),
        accrued,
        balance,
    };
}

async function readVaultAudit(
    client: PublicClient,
    vault: Address,
    expectedRecipient: Address,
): Promise<AuditReport["vault"]> {
    const recipient = await tryReadVaultAddress(client, vault, "recipient");
    const recipientFallback = recipient.supported
        ? recipient
        : await tryReadVaultAddress(client, vault, "RECIPIENT");
    const network = await tryReadVaultUint(client, vault, "withdrawalNetwork");
    const networkFallback = network.supported
        ? network
        : await tryReadVaultUint(client, vault, "WITHDRAWAL_NETWORK");

    return {
        recipientSupported: recipientFallback.supported,
        recipient: recipientFallback.value,
        recipientMatchesSplitter: recipientFallback.value
            ? getAddress(recipientFallback.value) === expectedRecipient
            : undefined,
        withdrawalNetworkSupported: networkFallback.supported,
        withdrawalNetwork: networkFallback.value?.toString(),
        withdrawalNetworkIsL2: networkFallback.value === undefined ? undefined : networkFallback.value === 1n,
    };
}

async function tryReadVaultAddress(
    client: PublicClient,
    address: Address,
    functionName: "recipient" | "RECIPIENT",
): Promise<{ supported: boolean; value?: Address }> {
    try {
        const value = await client.readContract({
            address,
            abi: vaultAddressAbi,
            functionName,
        });
        return { supported: true, value: getAddress(value) };
    } catch {
        return { supported: false };
    }
}

async function tryReadVaultUint(
    client: PublicClient,
    address: Address,
    functionName: "withdrawalNetwork" | "WITHDRAWAL_NETWORK",
): Promise<{ supported: boolean; value?: bigint }> {
    try {
        const value = await client.readContract({
            address,
            abi: vaultUintAbi,
            functionName,
        });
        return { supported: true, value };
    } catch {
        return { supported: false };
    }
}

function publicClient(config: LiveConfig): PublicClient {
    return createPublicClient({
        chain: shapeSepolia(config.rpcUrl),
        transport: http(config.rpcUrl),
    });
}

function walletClient(config: LiveConfig): WalletClient {
    return createWalletClient({
        account: privateKeyToAccount(readPrivateKey()),
        chain: shapeSepolia(config.rpcUrl),
        transport: http(config.rpcUrl),
    });
}

function shapeSepolia(rpcUrl: string) {
    return defineChain({
        id: SHAPE_SEPOLIA_CHAIN_ID,
        name: "Shape Sepolia",
        nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
        rpcUrls: { default: { http: [rpcUrl] } },
    });
}

async function getCode(client: PublicClient, address: Address): Promise<Hex> {
    return (await client.getBytecode({ address })) ?? "0x";
}

async function feeCap(client: PublicClient): Promise<bigint> {
    const fees = await client.estimateFeesPerGas().catch(() => undefined);
    if (fees?.maxFeePerGas !== undefined) {
        return fees.maxFeePerGas;
    }
    return client.getGasPrice();
}

function decodeProbeResult(abi: Abi, probe: Address, receipt: TransactionReceipt): ProbeEvent {
    for (const log of receipt.logs) {
        if (getAddress(log.address) !== probe) continue;
        try {
            const decoded = decodeEventLog({ abi, data: log.data, topics: log.topics });
            if (decoded.eventName !== "ProbeResult") continue;
            return decoded.args as unknown as ProbeEvent;
        } catch {
            continue;
        }
    }
    throw new GasbackLiveError("ProbeResult event not found in transaction receipt");
}

function loadArtifact(path: string): ForgeArtifact {
    if (!existsSync(path)) {
        throw new GasbackLiveError(`missing artifact ${path}; run forge build first`);
    }
    return JSON.parse(readFileSync(path, "utf8")) as ForgeArtifact;
}

function readAddress(name: string, fallback: string): Address {
    const value = process.env[name] ?? fallback;
    if (!isAddress(value)) {
        throw new GasbackLiveError(`${name} is not a valid address`);
    }
    return getAddress(value);
}

function byteLength(hex: Hex): number {
    return hex === "0x" ? 0 : (hex.length - 2) / 2;
}

function unknownWei(value: unknown): bigint {
    if (typeof value === "bigint") return value;
    if (typeof value === "number") return BigInt(value);
    if (typeof value === "string" && value.length !== 0) return BigInt(value);
    return 0n;
}

function assertNoFailures(failures: string[]) {
    if (failures.length !== 0) {
        throw new GasbackLiveError(failures.join("\n"));
    }
}

function writeReport(path: string, report: GasbackLiveReport) {
    const parent = dirname(path);
    if (parent !== "." && !existsSync(parent)) {
        mkdirSync(parent, { recursive: true });
    }
    writeFileSync(path, `${stringifyReport(report)}\n`);
}

function runProcess(command: string, args: string[]): Promise<void> {
    return new Promise((resolve, reject) => {
        const child = spawn(command, args, { stdio: "inherit", env: process.env });
        child.on("error", reject);
        child.on("exit", (code) => {
            if (code === 0) {
                resolve();
            } else {
                reject(new GasbackLiveError(`${command} ${args.join(" ")} exited with ${code}`));
            }
        });
    });
}

if (import.meta.main) {
    main().catch((error) => {
        console.error(error instanceof Error ? error.message : error);
        process.exit(1);
    });
}
