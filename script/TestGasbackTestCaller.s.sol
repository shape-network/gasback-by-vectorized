// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GasbackTestCaller} from "../src/test/GasbackTestCaller.sol";

interface IGasbackRead {
    function gasbackRatioNumerator() external view returns (uint256);
    function baseFeeVaultShareNumerator() external view returns (uint256);
    function gasbackMaxBaseFee() external view returns (uint256);
    function accrued() external view returns (uint256);
}

contract TestGasbackTestCallerScript is Script {
    error WrongChain(uint256 chainId);
    error InvalidCallerAddress(address caller);
    error InvalidGasbackAddress(address gasback);
    error CallerBalanceDecreased(uint256 beforeBalance, uint256 afterBalance);
    error CallerBalanceDeltaMismatch(uint256 expectedDelta, uint256 observedDelta);
    error AccruedDecreased(uint256 beforeAccrued, uint256 afterAccrued);
    error UnexpectedZeroGasResult(uint256 payout, uint256 accruedDelta);
    error PayoutExceedsTrackedShare(uint256 payout, uint256 trackedFromGas);
    error UnexpectedPayoutWithZeroRatio(uint256 payout);
    error EqualRatioShareMismatch(uint256 payout, uint256 trackedFromGas);
    error ExpectedPassThrough(uint256 realizedBaseFee, uint256 maxBaseFee, uint256 payout);

    uint256 internal constant SHAPE_SEPOLIA_CHAIN_ID = 11011;
    uint256 internal constant DEFAULT_GAS_TO_BURN = 30_000;
    address internal constant DEFAULT_SHAPE_SEPOLIA_CALLER =
        0x746E1dA1Dd0705640e93B1b8a4Db820fE29d19A5;

    function run() external {
        if (block.chainid != SHAPE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        address callerAddress =
            vm.envOr("GASBACK_TEST_CALLER_ADDRESS", DEFAULT_SHAPE_SEPOLIA_CALLER);
        if (callerAddress.code.length == 0) revert InvalidCallerAddress(callerAddress);

        GasbackTestCaller caller = GasbackTestCaller(payable(callerAddress));
        address gasbackAddress = caller.GASBACK();
        if (gasbackAddress.code.length == 0) revert InvalidGasbackAddress(gasbackAddress);

        IGasbackRead gasback = IGasbackRead(gasbackAddress);
        uint256 gasToBurn = vm.envOr("GAS_TO_BURN", DEFAULT_GAS_TO_BURN);

        console2.log("Shape Sepolia chain id:", block.chainid);
        console2.log("GasbackTestCaller:", callerAddress);
        console2.log("Gasback:", gasbackAddress);
        console2.log("Configured gasToBurn for nonzero case:", gasToBurn);

        _runCase(privateKey, caller, gasback, 0);
        _runCase(privateKey, caller, gasback, gasToBurn);

        console2.log("All checks passed.");
    }

    function _runCase(uint256 privateKey, GasbackTestCaller caller, IGasbackRead gasback, uint256 gasToBurn)
        internal
    {
        uint256 ratioNumerator = gasback.gasbackRatioNumerator();
        uint256 shareNumerator = gasback.baseFeeVaultShareNumerator();
        uint256 maxBaseFee = gasback.gasbackMaxBaseFee();

        uint256 callerBalanceBefore = address(caller).balance;
        uint256 accruedBefore = gasback.accrued();

        vm.startBroadcast(privateKey);
        uint256 payout = caller.burnGas(gasToBurn);
        vm.stopBroadcast();

        uint256 callerBalanceAfter = address(caller).balance;
        uint256 accruedAfter = gasback.accrued();

        if (callerBalanceAfter < callerBalanceBefore) {
            revert CallerBalanceDecreased(callerBalanceBefore, callerBalanceAfter);
        }
        if (accruedAfter < accruedBefore) {
            revert AccruedDecreased(accruedBefore, accruedAfter);
        }

        uint256 callerBalanceDelta = callerBalanceAfter - callerBalanceBefore;
        uint256 accruedDelta = accruedAfter - accruedBefore;

        if (callerBalanceDelta != payout) {
            revert CallerBalanceDeltaMismatch(payout, callerBalanceDelta);
        }

        if (gasToBurn == 0) {
            if (payout != 0 || accruedDelta != 0) {
                revert UnexpectedZeroGasResult(payout, accruedDelta);
            }

            console2.log("Case gasToBurn:", gasToBurn);
            console2.log("Payout:", payout);
            console2.log("Accrued delta:", accruedDelta);
            return;
        }

        uint256 trackedFromGas = accruedDelta + payout;
        if (ratioNumerator == 0 && payout != 0) {
            revert UnexpectedPayoutWithZeroRatio(payout);
        }
        if (payout > trackedFromGas) {
            revert PayoutExceedsTrackedShare(payout, trackedFromGas);
        }
        if (ratioNumerator == shareNumerator && payout != trackedFromGas) {
            revert EqualRatioShareMismatch(payout, trackedFromGas);
        }
        if (block.basefee > maxBaseFee && trackedFromGas != 0) {
            revert ExpectedPassThrough(block.basefee, maxBaseFee, payout);
        }

        console2.log("Case gasToBurn:", gasToBurn);
        console2.log("Payout:", payout);
        console2.log("Accrued delta:", accruedDelta);
        console2.log("Tracked from gas (accrued + payout):", trackedFromGas);
        console2.log("Ratio numerator used:", ratioNumerator);
        console2.log("Vault share numerator used:", shareNumerator);
        console2.log("Max base fee used:", maxBaseFee);
    }
}
