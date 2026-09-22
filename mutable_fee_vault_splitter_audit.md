# MutableFeeVaultSplitter internal audit

Reviewed 2026-09-22 UTC. Scope: the new mutable ETH splitter, its imported ownership/reentrancy/transfer/math helpers, and local integration with the repository's Gasback. This is an internal code review with adversarial testing, not an independent security-company audit or formal verification.

## Verdict

No accounting insolvency, unauthorized share change, double withdrawal, or reassignment of earned whole wei was found in the tested scope. The audit found and fixed payout gas/return-data denial of service. Production readiness remains conditional on trusted recipient behavior and a rehearsal of the actual owner, recipients, percentages, fee vault, and Gasback deployment.

Confirmed deployment model: two fixed recipients, with a governance contract as the single owner. The intended change from immutable fee splitting is that an approved governance execution can update their relative weights. The splitter does not set Gasback's payout ratio or enforce a minimum allocation. With a timelock-based Governor, the timelock is the owner/executor; with direct proposal execution, the governance contract itself is the owner.

## Findings

| Severity | Finding | Resolution |
| --- | --- | --- |
| Medium, availability | Forwarding all gas during automatic payout lets a recipient exhaust gas and revert the deposit, blocking other payees and the fee vault withdrawal. | Fixed: automatic/sliced payouts use a 100,000-gas stipend. A failed recipient retains its claim; direct `release` permits a higher-gas retry. |
| Medium, availability | Copying arbitrary return/revert bytes lets a recipient exhaust the splitter's memory-expansion/copying gas, including after a successful payment. | Fixed: use the vendored Solady `trySafeTransferETH`, which does not copy return data. `PaymentFailed` now contains only recipient and amount. |
| Medium, integration, retained | A recipient can call Gasback during distribution, consume newly forwarded Gasback funding, and make the outer vault-pull check fail. The withdrawal and nested payouts roll back; the original cashback request returns zero. | Reproduced by `test_untrustedPayeeCanStillBlockGasbackViaCrossContractReentry`. Requires a malicious or unexpectedly calling configured recipient. Validate all recipient code and upgrade controls. Accepting untrusted recipients requires a separate Gasback/payout-flow change and review. |
| Existing Gasback behavior, not a mutable-splitter defect | The splitter forwards fees by allocation; Gasback independently decides whether it can fund a requested payout. Insufficient funding can roll back the vault pull and return zero cashback. | Preserved intentionally. A differential fuzz test compares the mutable and immutable splitters at the same positive allocation, vault balance, buffer and requested payout. Governance changes allocation without automatically changing Gasback's separate payout configuration. |

The gas and return-data regressions were run before the fix and failed against the original mutable implementation. The corresponding tests pass after the fix. The expensive-recipient test additionally establishes the intended automatic-payout cap and separate claim path.

## Accounting review

Let `R = balance + totalReleased`, `C = _checkpointReceived`, and `A[i] = _accrued[i]`. At every completed operation, `C` equals the sum of historical whole-wei credits. Current-interval income is `R - C`.

A recipient's entitlement is `A[i] + floor((R - C) * shares[i] / totalShares)`. Its claim subtracts its lifetime released amount. On an update, old interval earnings are added to each `A[i]`, and their sum is added to `C`. Only the unallocated remainder is evaluated under the new weights. Thus old whole-wei entitlements survive updates, including a change to zero shares.

Summed entitlements cannot exceed `R`, so summed unpaid claims cannot exceed the contract balance. Payments update both released counters before making an external call and restore them on failure. All entry points that change payout accounting or shares share one reentrancy guard. Forced ETH only increases `R`; tests also cover forced ETH arriving during a payout.

This is an accounting argument backed by tests, not a machine-checked proof over every possible EVM execution.

## Automated coverage

- Owner authorization; explicit factory-independent owner; two-step transfer, cancellation, replacement, acceptance and renunciation.
- Invalid owners/payees, empty/mismatched/zero-total shares, duplicate zero-share payees, self-payees, overflowed totals and full-precision multiplication with large weights.
- Zero and tiny deposits, cumulative rounding, whole-wei preservation, dust carry, repeated updates without income, 0%/100% allocations and later reactivation.
- Partially released income, rejecting recipients, all recipients failing, late recovery, direct claims, empty/reversed/oversized distribution slices.
- Gas-burning recipients in each position, return/revert-data bombs, expensive recipients, too little transaction gas and atomic rollback.
- Reentrancy into `receive`, `release`, `distribute` and `setShares`; cross-contract Gasback reentry is separately documented as a remaining integration risk.
- Constructor ETH, CREATE2 prefunding plus constructor funding, forced ETH, forced ETH during payout, nonempty calldata rejection.
- Real repository Gasback with a local vault: successful pull after share changes, insufficient-share rollback/recovery, and funds still in the vault using the split at withdrawal time.
- Four fuzz properties, including comparisons against the original OpenZeppelin-backed splitter, multi-payee accounting and mixed successful/failed payment histories.
- A stateful invariant using an append-only history model, with deposits, actual `SELFDESTRUCT` funding, share updates, claims, distribution slices, recipient rejection toggles, ownership transfers and unauthorized attempts. It checks exact historical entitlements, balances, immutable payees, total released, solvency and a dust bound after each operation.
- A two-recipient instance owned by OpenZeppelin TimelockController: approved-operation scheduling/execution, enforced delay, rejection of direct calls by proposer/recipients/other users, inability to change recipient count, and preservation of the split until execution. A differential fuzz test verifies the existing Gasback funding behavior against the immutable splitter. The production voting contract, quorum and proposal-approval logic are not supplied or audited here.

The intensive run uses 5,000 cases per fuzz property and 1,000 invariant runs of depth 100 (100,000 calls), with seed `0x20260922`. Reported source coverage is 61/62 lines (98.4%), 12/12 branches and 10/10 functions. The unreported line is the `_release` return statement; its true/false outcomes are exercised by both successful and failing claims. Coverage uses `--ir-minimum`, so it is separate from tests of the normal optimized artifact. These percentages are coverage metrics, not probabilities of safety.

Initial audit results: all 40 splitter tests passed, including 20,000 fuzz cases and 100,000 invariant calls with zero unexpected reverts. The full default suite passed 108 tests. The preserved Shape suite passed 123 tests, with one live-fork test skipped because its RPC was not configured. Formatting passed. The intensive splitter tests were rerun after a forced rebuild with the normal optimizer/IR settings.

Governance clarification follow-up: four additional tests passed, including 5,000 differential fuzz cases comparing Gasback behavior with the immutable splitter. The full default suite now passes 112 tests, with 44 splitter tests across the four suites. Production source and its reviewed hash are unchanged; only tests and documentation changed in this follow-up. These tests validate proposal execution through the standard timelock, not production voting or quorum rules.

Slither 0.10.1 analyzed 41 contracts with 94 detectors using full compiler build-info. Its mutable-splitter findings were triaged: the exact-zero payment test is intentional, the compiler-age heuristic is outdated, and caching array length is an optional gas optimization. No additional actionable mutable-splitter finding was identified. Findings in pre-existing contracts were outside this change's standalone scope. The tool initially could not consume the abbreviated Foundry build-info; supplying full build-info allowed the analysis to complete without changing dependencies.

Build settings: Solidity `0.8.34+commit.80d5c536`, optimizer enabled with 1,000 runs, via IR, Prague EVM. Solady is pinned to `4363564a984779b7eec3bff00ab1de3a9db4e2d5`; OpenZeppelin is 4.9.5. The [current Solidity bug list](https://docs.soliditylang.org/en/latest/bugs.html) includes later fixes involving mutually recursive internal functions, custom storage layouts near the storage boundary, and named custom errors inside `require`. Those triggering constructs were not found in the splitter's reachable implementation. The memory-byte deletion issue is outside the configured IR pipeline. This is a source-level applicability assessment; it does not certify the compiler.

Reviewed source SHA-256: `aa1c3ffc4096592904e2be63df09b3d029748da2aa053c704d3f38b7e2067f7f`. Runtime bytecode size: 3,276 bytes. Re-review changes to the source, dependencies, compiler or build settings before relying on these results.

## Required deployment rehearsal

1. **Use the actual deployment inputs.** Verify owner, ordered recipient list, weights, chain ID, CREATE2 salt and derived address. Verify deployed bytecode against the tested artifact and confirm the chain supports its EVM target. These exact inputs were not provided for this review.
2. **Exercise the actual governance system.** On a fork or testnet, run a proposal through voting, quorum/approval, any timelock, and execution of `setShares`. Verify the splitter owner is the contract making the final call. Demonstrate that a voter, recipient or unrelated caller cannot bypass it. If ownership migration is needed, execute both transfer and acceptance through the relevant controllers. Do not renounce ownership in production as a test.
3. **Exercise the complete fee route.** Run a real fee-vault withdrawal into the splitter, measure each recipient's balance/claim delta, change percentages, repeat, and verify `totalReleased` and residual balance. Include a Gasback call that triggers a vault pull, not only a direct ETH transfer.
4. **Confirm the existing Gasback funding policy.** Exercise governance-approved allocations with low/empty buffer and realistic vault balances. Confirm the same successful-payout or insufficient-funding behavior as the immutable splitter. No automatic payout-ratio adjustment or minimum splitter allocation is being added. Percentages apply when funds reach the splitter, not when fees originally accrued in the vault.
5. **Validate recipient code and realistic gas.** Use the actual recipient contracts and their order. Confirm each normal automatic payout succeeds with the stipend; if not, confirm its direct-release path is operationally acceptable. Check proxy upgrade/admin controls and ensure recipients cannot unexpectedly call Gasback. Measure total withdrawal and share-update gas for the actual recipient count under the real transaction/block limits.
6. **Run a small production canary after the rehearsal.** Verify explorer source, owner and recipient configuration, then observe a small real withdrawal and a subsequent approved allocation change before routing substantial fees. Keep a chain-operator recovery procedure for repointing the vault to a replacement splitter; the splitter cannot replace its recipients or its own code.

No production force-send is needed for this review: actual force-send, gas exhaustion and oversized return-data behaviors were exercised locally. Reproduce failures with disposable testnet recipients if desired. A permanently rejecting configured address can permanently retain its earned claim; there is deliberately no redirect or owner sweep. Do not send ERC20 tokens: this contract has no ERC20 release/recovery path.

## Confidence and limits

Subjective engineering confidence: approximately **90% in the standalone splitter accounting/access controls under the tested assumptions**, and **75% in production readiness before the actual deployment rehearsal**. These are not calibrated exploit probabilities, guarantees, or a substitute for an independent reviewer. The same assistant implemented and reviewed the code, so correlated blind spots remain. No test suite can establish that every odd case has been covered.

The largest outstanding uncertainties are the two real recipient implementations and upgradeability, production governance voting/execution, actual fee-vault behavior/gas, and the live funding configuration. No target-chain fork or production transaction was executed in this audit. The legacy live-fork test remains skipped without its RPC configuration. No formal verification, independent human review, or economic stress test using production traffic was performed.

## Reproduction

Final uncommitted-change review on 2026-09-22 reran these checks successfully:

| Command | Result |
| --- | --- |
| `forge test --match-path 'test/MutableFeeVaultSplitter*.t.sol' --fuzz-runs 5000 --ignored-error-codes 2424` | 44 passed; five fuzz properties with 5,000 cases each; invariant: 30 runs, 450 calls, zero reverts. |
| `forge test --summary --ignored-error-codes 2424` | 112 passed, zero failures or skips in the default profile. |
| `forge fmt --check` | Passed. |
| `git diff --check` | Passed. |

All four splitter test suites are committed as Solidity code under `test/`. The deeper invariant, legacy-profile, coverage and static-analysis results above came from the earlier audit runs. Foundry emitted a non-fatal permission warning when writing its external signature cache; test execution completed successfully.

```sh
forge test --match-contract 'MutableFeeVaultSplitter(Test|AdversarialTest)' --fuzz-runs 5000 --fuzz-seed 0x20260922
forge test --match-contract MutableFeeVaultSplitterGovernanceTest --fuzz-runs 5000 --fuzz-seed 0x20260922
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 forge test --match-contract MutableFeeVaultSplitterInvariantTest --fuzz-seed 0x20260922
forge test
FOUNDRY_PROFILE=shape-legacy forge test
forge fmt --check
forge coverage --match-contract 'MutableFeeVaultSplitter(Test|AdversarialTest)' --ir-minimum --report lcov
```
