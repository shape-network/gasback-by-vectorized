# Mutable fee vault splitter

[`MutableFeeVaultSplitter`](src/MutableFeeVaultSplitter.sol) distributes incoming ETH automatically to fixed recipients. Its owner can change their relative shares using `setShares(uint256[])`.

## Source and review boundary

The existing [`FeeVaultSplitter`](src/FeeVaultSplitter.sol) came through the Vectorized Gasback history ([PR #19](https://github.com/Vectorized/gasback/pull/19), commit `c84ebcadc5a243ebfbf128938efcf46186800daa`). It wraps [OpenZeppelin Contracts 4.9.5 PaymentSplitter](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.5/contracts/finance/PaymentSplitter.sol), adding automatic ETH distribution and failed-payment handling.

OpenZeppelin's [PaymentSplitter](https://docs.openzeppelin.com/contracts/4.x/api/finance#PaymentSplitter) fixes shares at construction. Its lifetime accounting cannot safely support a share setter: lowering a share after payments have been released can make the next claim underflow; raising another share can incorrectly grant additional claims on past income.

The mutable contract adapts that cumulative ETH accounting and the existing push-payment behavior. It directly imports the repository's OpenZeppelin 4.9.5 `Ownable2Step`, `ReentrancyGuard`, and `Math.mulDiv`, and Solady's `SafeTransferLib.trySafeTransferETH`. It checkpoints earnings before changing shares. This accounting and payment-handling adaptation is new code; it is not an audited OpenZeppelin mutable splitter. See the [internal audit and deployment checks](mutable_fee_vault_splitter_audit.md).

[0xSplits V2](https://github.com/0xSplits/splits-contracts-monorepo/blob/main/packages/splits-v2/src/splitters/SplitWalletV2.sol) supports owner-updated recipients and allocations and has a [published audit](https://github.com/0xSplits/splits-contracts-monorepo/blob/main/audits/splits-v2.md). Its [PushSplit](https://github.com/0xSplits/splits-contracts-monorepo/blob/main/packages/splits-v2/src/splitters/push/PushSplit.sol) depends on a warehouse and explicit distribution calls. It is not a direct replacement for this fee vault's automatic forwarding, so no 0xSplits code was copied.

## Configuration and ownership

The intended deployment has **two fixed recipients and one governance-contract owner**. The owner is an authorization role, not a third payment recipient. Voting and proposal approval live in the governance system; the splitter only verifies the caller executing an approved update.

Deploy with `constructor(address owner_, address[] payees_, uint256[] shares_)`, using two entries in each array. Pass the governance executor explicitly as `owner_`, including when deploying through a CREATE2 factory. If the Governor executes through a timelock, the timelock must own the splitter because it makes the call. If the governance contract executes proposals directly, that contract is the owner. The owner must be nonzero.

- Recipients are set once. They must be unique and cannot be zero or the splitter itself.
- Shares are relative weights, in the original recipient order. `[60, 40]` means 60% and 40%; `[6250, 3750]` means 62.5% and 37.5%.
- Only the owner can call `setShares`. The array length must match the recipient count. Weights may be zero, but their sum must be positive and fit in `uint256`.
- Updates emit `SharesUpdated` and cannot add, remove, or replace recipients.
- Ownership transfer uses `transferOwnership(newOwner)` followed by `acceptOwnership()` from the new owner. `renounceOwnership()` permanently freezes the current shares; payments continue.

The owner controls future allocations among the fixed recipients, including assigning one recipient 100%. There is no owner withdrawal to an arbitrary address.

An approved proposal executes `setShares([20, 80])`, for example, to allocate 20% to the first recipient and 80% to the second. A vote or queued proposal alone does not change allocation: the update takes effect when the executor calls the splitter. The existing constructor remains generic like the immutable splitter; deploying with two recipients permanently fixes that instance to two.

As in the immutable splitter, allocation determines how incoming fees are forwarded. The splitter does not change Gasback's separate payout ratio, impose a minimum Gasback allocation, or guarantee Gasback always has enough funds. Insufficient-funding behavior comes from Gasback itself and also occurs with the immutable splitter at the same allocation; it is not a defect introduced by mutable percentages.

## Earnings when shares change

Before an update, the contract records each recipient's earned whole wei under the previous shares, including unpaid or failed transfers and ETH received without invoking `receive`. Updating shares makes no external calls and does not require recipients to accept payment.

For example, 10 ETH received at 60/40 earns 6 ETH and 4 ETH. After changing to 20/80, the next 10 ETH earns 2 ETH and 8 ETH. Lifetime entitlements are 8 ETH and 12 ETH, even if an earlier transfer failed. A recipient changed to 0% can still claim earlier earnings.

Within each unchanged-share interval, accounting is cumulative, matching PaymentSplitter's rounding behavior. At an update, unallocated rounding dust, less than one wei per recipient in aggregate, rolls into the new shares. Previously earned whole wei remain allocated to their original recipients.

The boundary is receipt by this splitter. ETH still held by the base fee vault when shares change will use the new shares when subsequently withdrawn into the splitter.

## Payments and deployment

`receive()` attempts payment to all recipients. Anyone can retry with `release(payee)` or `distribute(start, end)`; funds always go to the configured recipient. Automatic and sliced payouts request a 100,000-gas stipend per recipient. Direct `release` forwards available gas, allowing more expensive recipients to claim separately. Solady's transfer helper copies no recipient return data. Failed transfers emit `PaymentFailed(address,uint256)` and retain the claim; revert payloads are deliberately not included. All payment entry points and share updates use the same reentrancy guard.

Keep the recipient list small and trusted. Transaction gas still scales with recipient count, and the transaction must have enough gas for all attempted payouts and accounting. The splitter's reentrancy guard does not protect Gasback itself: a recipient that calls Gasback during distribution can cause the original cashback request to return zero. An actual regression test demonstrates this remaining integration risk. Sliced distribution retries ETH already in the splitter; it cannot recover a reverted vault withdrawal by itself.

This version supports ETH only. It does not expose PaymentSplitter's ERC20 release functions or an ERC20 recovery function. Constructor funding is claimable through `release` or `distribute`; it does not trigger automatic distribution.

This is a separate deployment, not an upgrade to an existing immutable splitter. Existing deployment scripts and `shape_deployment.md` still target `FeeVaultSplitter`. To use the mutable version, deploy its bytecode with its three constructor arguments and have the chain operator configure the base fee vault recipient to its address. Old claims remain in the old splitter. CREATE2 addresses must be recalculated with the mutable bytecode and constructor arguments.

## Validation

`test/MutableFeeVaultSplitter.t.sol` covers ownership, invalid configurations, automatic ETH payments to Gasback, preserved claims after updates and failures, zero shares, rounding dust, constructor and forced funding, large weights, reentrancy, and distribution slices. The adversarial suite adds gas and return-data attacks, CREATE2 prefunding, forced ETH during payment, and vault/Gasback integration. The invariant suite compares randomized operation sequences against a historical-interval accounting model.

`test/MutableFeeVaultSplitterGovernance.t.sol` verifies a two-recipient deployment owned by the vendored OpenZeppelin TimelockController: scheduled execution, delay enforcement, unchanged pre-execution earnings, direct-call rejection and fixed recipient count. A differential fuzz test checks Gasback funding and payout behavior against the immutable splitter at the same positive allocation. This tests the governance execution boundary, not an unspecified production voting/quorum implementation.

```sh
forge test --match-contract MutableFeeVaultSplitterTest
forge test
FOUNDRY_PROFILE=shape-legacy forge test
forge fmt --check
```
