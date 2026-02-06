# Gasback

A barebones implementation of a gasback contract that implements [RIP-7767](https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7767.md).

## Suggested setup for OP stack chains

### Requirements

- The `baseFeeVault` is deployed at `0x4200000000000000000000000000000000000019`.
- The `WITHDRAWAL_NETWORK` of the `baseFeeVault` is set to `1`.
- The `baseFeeVault` recipient is set to `ShapePaymentSplitter`.
- `Gasback` receives only its configured share from `ShapePaymentSplitter`.

### Via script

See `script/DeployGasback.s.sol` and `script/DeployShapePaymentSplitter.s.sol` for deployment scripts.

These scripts require you to have `PRIVATE_KEY` in your environment.

For more information on how to run a foundry script, see `https://getfoundry.sh/guides/scripting-with-solidity`.

### Manual steps

1. Deploy the `Gasback` contract.

2. Deploy `ShapePaymentSplitter` with `Gasback` as one of the payees.

3. Set the `baseFeeVault` recipient to the deployed `ShapePaymentSplitter`.

4. Configure `Gasback` via authorized calls:

   - `setBaseFeeVault(address)`  
     `0x4200000000000000000000000000000000000019`
   - `setBaseFeeVaultShareNumerator(uint256)`  
     `600000000000000000` (`0.6 ether`) and ensure it matches the splitter allocation for `Gasback`.
   - `setGasbackRatioNumerator(uint256)`  
     Must be less than or equal to `setBaseFeeVaultShareNumerator`.
   - `setGasbackMaxBaseFee(uint256)`  
     `115792089237316195423570985008687907853269984665640564039457584007913129639935`  

5. Put or leave some ETH in `Gasback`.
   The ETH acts as a buffer that is temporarily dished out to contracts calling `Gasback` in the span of a single block.
   The base fees collected in a block will only be accrued into the `baseFeeVault` at the end of a block.
   Try not to empty ETH from `Gasback` while actively serving gasback payouts.
