# Gasback Deployment Guide (non-7702)

This guide deploys [RIP-7767](https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7767.md) gasback
on an OP Stack chain **without EIP-7702**. `Gasback` is deployed as an ordinary contract, and the
base fee vault pays a `FeeVaultSplitter` that forwards a share of base fees to it.

## Architecture

```
  contract calls gasback ──┐
                           ▼
                     ┌───────────┐  pulls when short of ETH   ┌──────────────────┐
                     │  Gasback  │ ─────────────────────────► │   BaseFeeVault   │
                     │ (holds a  │                            │ 0x42...0019      │
                     │ ETH buffer)│                           │ RECIPIENT =      │
                     └───────────┘                            │  FeeVaultSplitter│
                           ▲                                  └────────┬─────────┘
                           │  share of base fees                       │ withdraw()
                           │                                           ▼
                           └────────────────────────────── ┌────────────────────┐
                                                           │  FeeVaultSplitter  │
                                                           │  (push payments)   │
                                                           └────────┬───────────┘
                                                                    │
                                                                    ▼
                                                          chain operator treasury,
                                                          other payees…

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

Deployer role. Every step is permissionless; nothing here needs chain-operator privileges.

### 1. Compute the `Gasback` address

```bash
cast create2 --salt 0x0000000000000000000000000000000000000000000000000000000000000000 --init-code $(forge inspect src/Gasback.sol:Gasback bytecode)
```

Record this as `GASBACK`. It is deterministic for the pinned compiler settings, so you can hand it
to the chain operator before anything is on-chain.

### 2. Compute the `FeeVaultSplitter` address

Pick the payee set and shares now — they cannot be changed later. `GASBACK` must be one of them.
Keep the set **small and trusted**: distribution is push-based, so a payee that burns a lot of gas
in its `receive()` can make the vault's `withdraw()` run out of gas, and a payee ordered after
`GASBACK` can re-enter it during distribution (see the note in
[FeeVaultSplitter.sol](src/FeeVaultSplitter.sol:43)).

```bash
# Example: 80% to gasback, 20% to the operator treasury.
ARGS=$(cast abi-encode "constructor(address[],uint256[])" "[$GASBACK,$TREASURY]" "[80,20]")
INIT=$(forge inspect src/FeeVaultSplitter.sol:FeeVaultSplitter bytecode)${ARGS:2}
cast create2 --salt 0x0000000000000000000000000000000000000000000000000000000000000000 --init-code $INIT
```

Record this as `SPLITTER`. **This is the address the chain operator sets as `RECIPIENT`.**

### 3. Deploy both contracts

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

Confirm the deployed addresses match the ones computed in steps 1 and 2.

Constructor defaults on `Gasback` are:

| Parameter               | Default                                      | Meaning                                        |
| ----------------------- | -------------------------------------------- | ---------------------------------------------- |
| `gasbackRatioNumerator` | `0.6 ether`                                  | 60% of the base fee paid is refunded           |
| `gasbackMaxBaseFee`     | `type(uint256).max`                          | never becomes a pass-through on high base fees |
| `baseFeeVault`          | `0x4200000000000000000000000000000000000019` | OP Stack base fee vault predeploy              |

If you want different values, the chain operator must set them (Part 2, step 4).

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

### 1. `RECIPIENT` → the `FeeVaultSplitter`

Set the base fee vault's recipient to `SPLITTER` from Part 1, step 2. This is what routes base fees
into gasback.

### 2. `WITHDRAWAL_NETWORK` → L2 (`1`)

Must be **L2**. With the default `L1` (`0`), `withdraw()` bridges fees to L1 and `Gasback` can never
pull from the vault. With `L2`, `withdraw()` does a direct send to `RECIPIENT` on this chain, which
triggers `FeeVaultSplitter.receive()` and distributes to payees.

### 3. `MIN_WITHDRAWAL_AMOUNT` → low

`Gasback.triggerBaseFeeVaultWithdraw` calls `withdraw()` on the vault, which reverts if the vault
holds less than `MIN_WITHDRAWAL_AMOUNT`. Set it comfortably below the ETH a single refund needs,
accounting for the split — `Gasback` only receives its share of each withdrawal. The OP Stack
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

# Gasback is a payee of the splitter
cast call $SPLITTER "shares(address)(uint256)" $GASBACK --rpc-url $RPC_URL

# Buffer is funded
cast balance $GASBACK --rpc-url $RPC_URL
```

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
- **The splitter set is permanent.** Getting payees or shares wrong means deploying a new splitter
  _and_ re-pointing `RECIPIENT`, which is a predeploy upgrade.
- **If a distribution ever fails**, funds are not lost: anyone can call
  `distribute(uint256 start, uint256 end)` to release payees in bounded chunks.
