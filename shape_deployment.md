# Gasback Deployment Guide (non-7702)

This guide deploys [RIP-7767](https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7767.md) gasback
on an OP Stack chain **without EIP-7702**. `Gasback` is deployed as an ordinary contract, and the
base fee vault pays an immutable `FeeVaultSplitter` that routes fees to their configured destinations.
Its Gasback/buyback allocation goes to a `MutableFeeVaultSplitter`, which splits that allocation
between Gasback and the buyback recipient. DUNE decides these weights first; governance does later.

## Architecture

```
  BaseFeeVault.withdraw()
    └── FeeVaultSplitter (immutable fee routing)
          ├── other fee destinations
          └── MutableFeeVaultSplitter (Gasback/buyback allocation)
                ├── Gasback
                └── buyback recipient

  contract calls Gasback ──► Gasback pulls BaseFeeVault when short of ETH

  Mutable weights: DUNE Safe initially, governance executor later.

  ┌────────────────┐  slot 0 = Gasback address (written by the system address)
  │ GasbackBeacon  │  read by anyone for discoverability
  │ 0x0000…892f    │
  └────────────────┘
```

Key facts that shape the whole flow:

- `Gasback`'s admin functions (`withdraw`, `setGasbackRatioNumerator`, `setGasbackMaxBaseFee`,
  `setBaseFeeVault`) are guarded by `onlySystemOrThis`. Without EIP-7702 there is no EOA equal to
  `address(this)`, so **only the system address `0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE` can
  reconfigure the contract after deployment.** Constructor defaults are what you get otherwise.
- `FeeVaultSplitter` payees and shares are **immutable** — fixed in its constructor.
  One of its payees is the downstream `MutableFeeVaultSplitter` for Gasback/buyback.
- `MutableFeeVaultSplitter` keeps Gasback and the buyback recipient fixed but lets its owner
  update their relative weights within that allocation. Its ownership moves from the deployment
  controller to the DUNE Safe, then to the governance executor. This ownership only controls the
  splitter's shares.
- The base fee vault's `RECIPIENT`, `MIN_WITHDRAWAL_AMOUNT` and `WITHDRAWAL_NETWORK` are
  **immutables in the predeploy**, so they are set at genesis or by upgrading the predeploy.

Because `RECIPIENT` is baked into the fee vault, deploy contracts with CREATE2 so their addresses
can be computed _before_ the chain config is finalized.

## Prerequisites

- Foundry (`forge`, `cast`) — this repo pins `solc 0.8.34`, `evm_version = prague`, `via_ir`,
  `optimizer_runs = 1000` in [foundry.toml](foundry.toml).
- Nick's CREATE2 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` deployed on the chain.
- An RPC URL and a funded deployer key.

```bash
forge install && forge build
```

---

## Part 1 — Contract deployment

Deployer role. Contract deployment is permissionless. The mutable splitter ownership handoff
also requires its current owner and an approved transaction executed by the DUNE Safe.

### 1. Compute the `Gasback` address

```bash
cast create2 --salt 0x0000000000000000000000000000000000000000000000000000000000000000 --init-code $(forge inspect src/Gasback.sol:Gasback bytecode)
```

Record this as `GASBACK`. It is deterministic for the pinned compiler settings, so you can hand it
to the chain operator before anything is on-chain.

### 2. Compute both splitter addresses

#### Gasback/buyback: `MutableFeeVaultSplitter`

`INITIAL_OWNER` is the nonzero deployment controller that will perform the ownership handoff;
pass it explicitly because the CREATE2 factory is not the intended owner. Confirm `DUNE_SAFE`
on the target chain and confirm `BUYBACK_RECIPIENT`, the fixed destination for buyback funds.
The DUNE Safe's ownership role is separate from the buyback recipient's payment role.

Pick the two fixed payees and DUNE-approved initial relative weights. The following 80/20 weights
are illustrative; use the approved values before computing the address.

```bash
MUTABLE_ARGS=$(cast abi-encode "constructor(address,address[],uint256[])" "$INITIAL_OWNER" "[$GASBACK,$BUYBACK_RECIPIENT]" "[80,20]")
MUTABLE_INIT=$(forge inspect src/MutableFeeVaultSplitter.sol:MutableFeeVaultSplitter bytecode)${MUTABLE_ARGS:2}
cast create2 --salt 0x0000000000000000000000000000000000000000000000000000000000000000 --init-code "$MUTABLE_INIT"
```

Record this as `MUTABLE_SPLITTER`. DUNE and later governance can change these Gasback/buyback
weights without changing the upstream fee allocations. Record ordered payees, initial weights,
initial owner and derived address. See [Mutable fee vault splitter](mutable_fee_vault_splitter.md).

#### Fee routing: immutable `FeeVaultSplitter`

Keep the immutable splitter as the base fee vault recipient. Configure `MUTABLE_SPLITTER` as
its payee for the Gasback/buyback allocation, alongside the other required fee destinations.
Its payees and weights cannot change later. Keep the set small and trusted: the complete nested
push-payment route must fit within the vault withdrawal's gas budget.

```bash
# Illustrative routing: 80% to Gasback/buyback, 20% to the operator treasury.
# Use the complete approved fee destinations and fixed weights for production.
ARGS=$(cast abi-encode "constructor(address[],uint256[])" "[$MUTABLE_SPLITTER,$TREASURY]" "[80,20]")
INIT=$(forge inspect src/FeeVaultSplitter.sol:FeeVaultSplitter bytecode)${ARGS:2}
cast create2 --salt 0x0000000000000000000000000000000000000000000000000000000000000000 --init-code "$INIT"
```

Record this as `SPLITTER`. **This immutable splitter is the base fee vault's `RECIPIENT`.**
For example, an 80% upstream allocation and 80/20 downstream weights route 64% of total fees
to Gasback, 16% to buyback and 20% to the treasury.

### 3. Deploy Gasback and both splitters

```bash
cast send 0x4e59b44847b379578588920cA78FbF26c0B4956C \
  0x0000000000000000000000000000000000000000000000000000000000000000$(forge inspect src/Gasback.sol:Gasback bytecode | cut -c3-) \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

```bash
cast send 0x4e59b44847b379578588920cA78FbF26c0B4956C \
  0x0000000000000000000000000000000000000000000000000000000000000000${INIT:2} \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

Deploy the downstream mutable splitter using its own initcode:

```bash
cast send 0x4e59b44847b379578588920cA78FbF26c0B4956C \
  0x0000000000000000000000000000000000000000000000000000000000000000${MUTABLE_INIT:2} \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

Confirm the deployed addresses match the ones computed in steps 1 and 2.

Constructor defaults on `Gasback` are:

| Parameter               | Default                                      | Meaning                                        |
| ----------------------- | -------------------------------------------- | ---------------------------------------------- |
| `gasbackRatioNumerator` | `0.6 ether`                                  | 60% of the base fee paid is refunded           |
| `gasbackMaxBaseFee`     | `type(uint256).max`                          | never becomes a pass-through on high base fees |
| `baseFeeVault`          | `0x4200000000000000000000000000000000000019` | OP Stack base fee vault predeploy              |

If you want different values, the chain operator must set them (Part 2, step 5).

#### Mutable splitter: transfer ownership to the DUNE Safe

Complete this before Part 2 routes fees to the mutable splitter. Every transaction below targets
`MUTABLE_SPLITTER`, sends zero ETH, and uses a normal **CALL**, not a delegatecall.

1. Confirm `owner()` equals `INITIAL_OWNER` and verify the target-chain DUNE Safe address,
   signers and threshold.
2. From `INITIAL_OWNER`, execute `transferOwnership(DUNE_SAFE)`. Generate the calldata with:
   ```bash
   cast calldata "transferOwnership(address)" "$DUNE_SAFE"
   ```
3. Confirm `pendingOwner()` equals `DUNE_SAFE`. The initial owner retains authority until
   acceptance.
4. Through the DUNE Safe, approve and execute a transaction calling `acceptOwnership()` on
   `MUTABLE_SPLITTER`. A signer calling directly from their EOA cannot accept for the Safe.
   ```bash
   cast calldata "acceptOwnership()"
   ```
5. Verify `owner()` equals `DUNE_SAFE` and `pendingOwner()` is the zero address:
   ```bash
   cast call "$MUTABLE_SPLITTER" "owner()(address)" --rpc-url "$RPC_URL"
   cast call "$MUTABLE_SPLITTER" "pendingOwner()(address)" --rpc-url "$RPC_URL"
   ```

The DUNE Safe can now update shares until the later governance handoff. The buyback payment-recipient
role is separate from ownership; transferring ownership does not change payees or shares.
For a weight update, the Safe executes a CALL to `MUTABLE_SPLITTER` with zero ETH and calldata
such as `cast calldata "setShares(uint256[])" "[60,40]"`, using DUNE-approved weights in the
original order: Gasback, then buyback. After the governance handoff, governance executes that call.

### 4. Fund the `Gasback` buffer

```bash
cast send $GASBACK --value 1ether --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

Base fees only land in the vault at the end of a block, so this ETH is the working buffer that pays
callers _within_ a block. If `Gasback` runs dry it silently becomes a pass-through (returns 0 and
burns no gas), so keep the buffer topped up and don't drain it.

### 5. Deploy the `GasbackBeacon`

Use the published initcode from [deployments.md](deployments.md) verbatim — it was compiled with
`solc 0.8.28`, `evm = london`, `optimization = 1000` and only that exact initcode lands on the
canonical address `0x000000000000BF89b7D537A213dcE1830A9b892f`.

```bash
cast send 0x4e59b44847b379578588920cA78FbF26c0B4956C \
  0x00000000000000000000000000000000000000005f84120a09d32902eeb3e2bc608080604052346013576060908160198239f35b600080fdfe3d5460405273fffffffffffffffffffffffffffffffffffffffe33186024573d353d55005b60206040f3fea26469706673582212209d2f812fc493cd5f17299625503f2130b74e11905b49e764be5b9dd350173df964736f6c634300081c0033 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

The beacon starts empty. Writing the `Gasback` address into it is a chain-operator step.

### 6. (Optional) Verify the contracts

```bash
./build_create2_deployments.sh   # writes create2/<Contract>/input.json for standard-json verification
forge verify-contract $GASBACK src/Gasback.sol:Gasback --rpc-url $RPC_URL
```

---

## Part 2 — Chain operator setup

These steps require control of the chain's genesis config or of the L1 `ProxyAdminOwner`, plus the
ability to insert a deposit transaction from the system address.
For the mutable splitter, confirm the DUNE Safe accepted ownership in Part 1 before routing fees.
The later governance handoff requires DUNE Safe approval and governance execution, independently
of chain-operator privileges.

### 1. `RECIPIENT` → the `FeeVaultSplitter`

Set the base fee vault's recipient to `SPLITTER` from Part 1, step 2. This is what routes base fees
into the immutable fee router, which forwards the Gasback/buyback allocation to
`MUTABLE_SPLITTER` and distributes the remaining allocations to the other fee destinations.

### 2. `WITHDRAWAL_NETWORK` → L2 (`1`)

Must be **L2**. With the default `L1` (`0`), `withdraw()` bridges fees to L1 and `Gasback` can never
pull from the vault. With `L2`, `withdraw()` does a direct send to `RECIPIENT` on this chain, which
triggers `FeeVaultSplitter.receive()` and distributes to payees.

### 3. `MIN_WITHDRAWAL_AMOUNT` → low

`Gasback.triggerBaseFeeVaultWithdraw` calls `withdraw()` on the vault, which reverts if the vault
holds less than `MIN_WITHDRAWAL_AMOUNT`. Set it comfortably below the ETH a single refund needs,
accounting for both splits — `Gasback` receives the upstream Gasback/buyback allocation
multiplied by its current downstream weight. The OP Stack
default of `10 ether` is far too high; something on the order of `0.00001 ether` is a reasonable
starting point. Too high and refills stall and gasback degrades to a pass-through.

**How to apply steps 1–3:**

- **New chain:** set these in the deploy config used to build the L2 genesis:
  ```json
  {
    "baseFeeVaultRecipient": "<SPLITTER>",
    "baseFeeVaultWithdrawalNetwork": 1,
    "baseFeeVaultMinimumWithdrawalAmount": "0x2386f26fc10000"
  }
  ```
- **Existing chain:** these are immutables inside the `BaseFeeVault` implementation, not proxy
  storage. Deploy a new `BaseFeeVault` implementation with the three constructor values above, then
  upgrade the proxy at `0x4200000000000000000000000000000000000019` through the predeploy
  `ProxyAdmin` at `0x4200000000000000000000000000000000000018`. Call any pending `withdraw()` before
  the upgrade so no fees are stranded under the old recipient.

### 4. Write the beacon

`GasbackBeacon` stores the canonical `Gasback` address in slot 0. Its fallback only accepts a write
when `msg.sender` is the system address `0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE`; every other
caller gets slot 0 returned as 32 bytes. So the write must be a deposit / network-upgrade
transaction with:

| Field   | Value                                        |
| ------- | -------------------------------------------- |
| `from`  | `0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE` |
| `to`    | `0x000000000000BF89b7D537A213dcE1830A9b892f` |
| `value` | `0`                                          |
| `data`  | `GASBACK` left-padded to 32 bytes            |

```bash
cast abi-encode "f(address)" $GASBACK   # produces the 32-byte data payload
```

Verify from any account:

```bash
cast call 0x000000000000BF89b7D537A213dcE1830A9b892f 0x --rpc-url $RPC_URL
# → 0x000000000000000000000000<GASBACK>
```

### 5. (Optional) Tune the `Gasback` parameters

Only needed if you want values other than the constructor defaults. Same mechanism — a deposit
transaction from the system address, this time `to = GASBACK`:

```bash
cast calldata "setGasbackRatioNumerator(uint256)" 900000000000000000   # 90% refund
cast calldata "setGasbackMaxBaseFee(uint256)" <wei>                    # pass-through above this
cast calldata "setBaseFeeVault(address)" 0x4200000000000000000000000000000000000019
```

`withdraw(address,uint256)` on `Gasback` is available the same way if you ever need to recover ETH
from the buffer.

### 6. Mutable splitter: transfer ownership from the DUNE Safe to governance

Perform this later, once the governance contract and its execution path are deployed and ready.
Until acceptance completes, the DUNE Safe remains the splitter owner.

1. Confirm the governance executor can call both `acceptOwnership()` and `setShares(uint256[])`
   on `MUTABLE_SPLITTER` through the approved proposal/execution flow. Set `GOVERNANCE_EXECUTOR` to the
   contract making the final call: the timelock if the Governor uses one, or the governance
   contract if it executes directly. Verify its nonzero address and bytecode on the target chain.
2. Through the DUNE Safe, approve and execute a normal CALL to `MUTABLE_SPLITTER`, with zero ETH and
   calldata generated by:
   ```bash
   cast calldata "transferOwnership(address)" "$GOVERNANCE_EXECUTOR"
   ```
3. Verify `owner()` is still `DUNE_SAFE` and `pendingOwner()` equals `GOVERNANCE_EXECUTOR`.
4. Through governance, propose, approve, schedule if required, and execute a normal CALL to
   `MUTABLE_SPLITTER` with zero ETH and `acceptOwnership()` calldata:
   ```bash
   cast calldata "acceptOwnership()"
   ```
   The call must originate from `GOVERNANCE_EXECUTOR`; a voter, proposer or Safe signer cannot
   accept on its behalf.
5. Verify `owner()` equals `GOVERNANCE_EXECUTOR` and `pendingOwner()` is the zero address using
   the read calls from Part 1. Record both handoff transactions. Subsequent `setShares` calls
   must execute through governance; the DUNE Safe no longer has owner authority.

Ownership transfer preserves fixed payees, current shares and accrued claims. Do not use
`renounceOwnership()` for either handoff: it permanently disables share updates.

---

## Verification checklist

```bash
# Beacon points at the gasback contract
cast call 0x000000000000BF89b7D537A213dcE1830A9b892f 0x --rpc-url $RPC_URL

# Gasback config
cast call $GASBACK "gasbackRatioNumerator()(uint256)" --rpc-url $RPC_URL
cast call $GASBACK "gasbackMaxBaseFee()(uint256)"     --rpc-url $RPC_URL
cast call $GASBACK "baseFeeVault()(address)"          --rpc-url $RPC_URL

# Base fee vault config (older predeploys use RECIPIENT()/MIN_WITHDRAWAL_AMOUNT()/WITHDRAWAL_NETWORK())
cast call 0x4200000000000000000000000000000000000019 "recipient()(address)"            --rpc-url $RPC_URL
cast call 0x4200000000000000000000000000000000000019 "minWithdrawalAmount()(uint256)"  --rpc-url $RPC_URL
cast call 0x4200000000000000000000000000000000000019 "withdrawalNetwork()(uint8)"      --rpc-url $RPC_URL  # must be 1

# Immutable fee router forwards the Gasback/buyback allocation to the mutable splitter
cast call "$SPLITTER" "shares(address)(uint256)" "$MUTABLE_SPLITTER" --rpc-url "$RPC_URL"

# Mutable splitter forwards to the two fixed recipients
cast call "$MUTABLE_SPLITTER" "payee(uint256)(address)" 0 --rpc-url "$RPC_URL" # GASBACK
cast call "$MUTABLE_SPLITTER" "payee(uint256)(address)" 1 --rpc-url "$RPC_URL" # BUYBACK_RECIPIENT
cast call "$MUTABLE_SPLITTER" "shares(address)(uint256)" "$GASBACK" --rpc-url "$RPC_URL"
cast call "$MUTABLE_SPLITTER" "shares(address)(uint256)" "$BUYBACK_RECIPIENT" --rpc-url "$RPC_URL"
cast call "$MUTABLE_SPLITTER" "owner()(address)" --rpc-url "$RPC_URL"
cast call "$MUTABLE_SPLITTER" "pendingOwner()(address)" --rpc-url "$RPC_URL"

# Buffer is funded
cast balance $GASBACK --rpc-url $RPC_URL
```

Before launch, rehearse a vault withdrawal through **both** splitters and verify all fee
destinations receive their configured allocations. After DUNE or governance changes the mutable
weights, repeat and confirm only the Gasback/buyback allocation changes internally.

End-to-end smoke test — call `Gasback` with a 32-byte `gasToBurn` and check the refund:

```bash
cast send $GASBACK $(cast abi-encode "f(uint256)" 100000) --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

A non-zero returned `ethToGive` and an ETH balance increase on the caller means the wiring works. A
zero return means `Gasback` was out of ETH or the base fee exceeded `gasbackMaxBaseFee`.

## Gotchas

- **Pass-through is silent.** Insufficient ETH, a reverting vault, or a base fee above
  `gasbackMaxBaseFee` all make `Gasback` return `0` without reverting. Monitor its balance.
- **`tx.gasprice` must be non-zero.** The fallback rejects zero-gasprice calls to block
  L1→L2 deposits from farming gasback.
- **Calldata must be exactly 32 bytes.** Anything else reverts.
- **Fixed routing and recipients.** The upstream immutable splitter fixes all fee destinations
  and their allocations, including the mutable splitter address. The downstream mutable splitter
  fixes its two recipients; DUNE and later governance can update only their weights. Replacing
  either splitter requires updating the upstream route, potentially including a vault upgrade.
- **If a distribution ever fails**, funds are not lost: anyone can call
  `distribute(uint256 start, uint256 end)` to release payees in bounded chunks.
