// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./utils/SoladyTest.sol";
import {GasbackLiveProbe} from "../src/test/GasbackLiveProbe.sol";

interface IGasbackLiveFork {
    function GASBACK_RATIO_DENOMINATOR() external view returns (uint256);
    function gasbackRatioNumerator() external view returns (uint256);
    function baseFeeVaultShareNumerator() external view returns (uint256);
    function gasbackMaxBaseFee() external view returns (uint256);
    function baseFeeVault() external view returns (address);
    function accrued() external view returns (uint256);
    function setBaseFeeVault(address value) external returns (bool);
    function setGasbackMaxBaseFee(uint256 value) external returns (bool);
}

interface IFeeVaultSplitterLiveFork {
    function totalShares() external view returns (uint256);
    function shares(address account) external view returns (uint256);
    function releasable(address account) external view returns (uint256);
}

interface IGasbackTestCallerLiveFork {
    function GASBACK() external view returns (address);
}

contract RejectingLiveCaller {
    function trigger(address target, uint256 gasToBurn) external returns (uint256 payout) {
        (bool success, bytes memory data) = target.call(abi.encode(gasToBurn));
        require(success);
        payout = abi.decode(data, (uint256));
    }

    receive() external payable {
        revert();
    }
}

contract GasbackLiveForkTest is SoladyTest {
    address internal constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    address internal constant GASBACK = 0x21E34c5bea9253CDCd57671A1970BB31df4aBe83;
    address internal constant SPLITTER = 0x658e643B379b52cD21605bfAf9c81e84713D8427;
    address internal constant TEST_CALLER = 0xA53D127f193858f5ef2Cf50dd1B3A94198ef811d;
    uint256 internal constant SHAPE_SEPOLIA_CHAIN_ID = 11011;
    uint256 internal constant DENOMINATOR = 1 ether;

    IGasbackLiveFork internal gasback;
    IFeeVaultSplitterLiveFork internal splitter;

    function setUp() public {
        if (!vm.envExists("SHAPE_SEPOLIA_RPC_URL")) {
            vm.skip(true, "SHAPE_SEPOLIA_RPC_URL not set");
            return;
        }

        vm.createSelectFork(vm.envString("SHAPE_SEPOLIA_RPC_URL"));
        gasback = IGasbackLiveFork(GASBACK);
        splitter = IFeeVaultSplitterLiveFork(SPLITTER);
    }

    function test_liveDeploymentConfiguration() public view {
        assertEq(block.chainid, SHAPE_SEPOLIA_CHAIN_ID);
        assertGt(GASBACK.code.length, 0);
        assertGt(SPLITTER.code.length, 0);
        assertGt(TEST_CALLER.code.length, 0);
        assertEq(keccak256(GASBACK.code), keccak256(vm.getDeployedCode("Gasback.sol:Gasback")));
        assertEq(IGasbackTestCallerLiveFork(TEST_CALLER).GASBACK(), GASBACK);

        uint256 ratio = gasback.gasbackRatioNumerator();
        uint256 share = gasback.baseFeeVaultShareNumerator();
        assertLe(ratio, share);
        assertLe(share, DENOMINATOR);
        assertEq(gasback.GASBACK_RATIO_DENOMINATOR(), DENOMINATOR);
        assertGt(gasback.baseFeeVault().code.length, 0);
    }

    function test_liveSplitterShareMatchesGasbackShareNumerator() public view {
        uint256 totalShares = splitter.totalShares();
        uint256 gasbackShares = splitter.shares(GASBACK);
        assertGt(totalShares, 0);
        assertGt(gasbackShares, 0);
        assertEq((gasbackShares * DENOMINATOR) / totalShares, gasback.baseFeeVaultShareNumerator());
    }

    function test_liveBaseFeeVaultConfigurationWhenAbiSupported() public view {
        address vault = gasback.baseFeeVault();
        (bool hasRecipient, address recipient) = _tryReadAddress(vault, "recipient()");
        if (hasRecipient) {
            assertEq(recipient, SPLITTER);
        }

        (bool hasWithdrawalNetwork, uint256 withdrawalNetwork) =
            _tryReadUint(vault, "withdrawalNetwork()");
        if (hasWithdrawalNetwork) {
            assertEq(withdrawalNetwork, 1);
        }
    }

    function test_forkProbePayoutOracleWithFundedBuffer() public {
        uint256 baseFee = _boundedBaseFee();
        uint256 gasToBurn = 30_000;
        vm.fee(baseFee);

        (uint256 expectedPayout, uint256 expectedAccruedDelta) =
            _expectedPayoutAndAccruedDelta(baseFee, gasToBurn);

        uint256 accruedBefore = gasback.accrued();
        vm.deal(GASBACK, expectedPayout + 1 ether);

        GasbackLiveProbe probe = new GasbackLiveProbe(GASBACK);
        uint256 probeBalanceBefore = address(probe).balance;
        uint256 payout = probe.probe(gasToBurn);

        assertEq(payout, expectedPayout);
        assertEq(address(probe).balance - probeBalanceBefore, expectedPayout);
        assertEq(gasback.accrued() - accruedBefore, expectedAccruedDelta);
    }

    function test_forkPassThroughWhenBufferIsInsufficientAndVaultDisabled() public {
        uint256 baseFee = _boundedBaseFee();
        uint256 gasToBurn = 30_000;
        vm.fee(baseFee);
        vm.prank(SYSTEM_ADDRESS);
        gasback.setBaseFeeVault(address(0));

        (uint256 expectedPayout,) = _expectedPayoutAndAccruedDelta(baseFee, gasToBurn);
        if (expectedPayout == 0) {
            expectedPayout = 1;
        }

        vm.deal(GASBACK, expectedPayout - 1);
        uint256 accruedBefore = gasback.accrued();

        GasbackLiveProbe probe = new GasbackLiveProbe(GASBACK);
        uint256 payout = probe.probe(gasToBurn);

        assertEq(payout, 0);
        assertEq(address(probe).balance, 0);
        assertEq(gasback.accrued(), accruedBefore);
        assertEq(GASBACK.balance, expectedPayout - 1);
    }

    function test_forkPassThroughWhenBaseFeeExceedsMax() public {
        uint256 baseFee = 100;
        uint256 gasToBurn = 30_000;
        vm.fee(baseFee);
        vm.prank(SYSTEM_ADDRESS);
        gasback.setGasbackMaxBaseFee(baseFee - 1);

        (uint256 expectedPayout,) = _expectedPayoutAndAccruedDelta(baseFee, gasToBurn);
        vm.deal(GASBACK, expectedPayout + 1 ether);
        uint256 accruedBefore = gasback.accrued();

        GasbackLiveProbe probe = new GasbackLiveProbe(GASBACK);
        uint256 payout = probe.probe(gasToBurn);

        assertEq(payout, 0);
        assertEq(address(probe).balance, 0);
        assertEq(gasback.accrued(), accruedBefore);
    }

    function test_forkRepeatedSameBlockCallsAreAdditive() public {
        uint256 baseFee = _boundedBaseFee();
        uint256 gasToBurn = 12_000;
        uint256 calls = 3;
        vm.fee(baseFee);

        (uint256 expectedPayout, uint256 expectedAccruedDelta) =
            _expectedPayoutAndAccruedDelta(baseFee, gasToBurn);

        vm.deal(GASBACK, calls * expectedPayout + 1 ether);
        uint256 accruedBefore = gasback.accrued();
        GasbackLiveProbe probe = new GasbackLiveProbe(GASBACK);

        for (uint256 i = 0; i < calls; i++) {
            assertEq(probe.probe(gasToBurn), expectedPayout);
        }

        assertEq(address(probe).balance, calls * expectedPayout);
        assertEq(gasback.accrued() - accruedBefore, calls * expectedAccruedDelta);
    }

    function test_forkBoundedStressSweep() public {
        uint256[5] memory gasValues = [uint256(0), 1, 30_000, 120_000, 250_000];
        uint256[3] memory baseFees = [uint256(0), 1, _boundedBaseFee()];
        GasbackLiveProbe probe = new GasbackLiveProbe(GASBACK);

        for (uint256 i = 0; i < baseFees.length; i++) {
            vm.fee(baseFees[i]);
            for (uint256 j = 0; j < gasValues.length; j++) {
                (uint256 expectedPayout, uint256 expectedAccruedDelta) =
                    _expectedPayoutAndAccruedDelta(baseFees[i], gasValues[j]);
                uint256 accruedBefore = gasback.accrued();
                uint256 probeBalanceBefore = address(probe).balance;
                vm.deal(GASBACK, expectedPayout + 1 ether);

                uint256 payout = probe.probe(gasValues[j]);

                assertEq(payout, expectedPayout);
                assertEq(address(probe).balance - probeBalanceBefore, expectedPayout);
                assertEq(gasback.accrued() - accruedBefore, expectedAccruedDelta);
            }
        }
    }

    function test_forkRejectingReceiverStillReceivesPayout() public {
        uint256 baseFee = _boundedBaseFee();
        uint256 gasToBurn = 30_000;
        vm.fee(baseFee);
        (uint256 expectedPayout,) = _expectedPayoutAndAccruedDelta(baseFee, gasToBurn);
        vm.deal(GASBACK, expectedPayout + 1 ether);

        RejectingLiveCaller caller = new RejectingLiveCaller();
        uint256 payout = caller.trigger(GASBACK, gasToBurn);

        assertEq(payout, expectedPayout);
        assertEq(address(caller).balance, expectedPayout);
    }

    function test_forkInvalidCalldataReverts() public {
        (bool success,) = GASBACK.call(hex"01");
        assertFalse(success);
    }

    function test_forkSplitterReleasableReadDoesNotRevert() public view {
        splitter.releasable(GASBACK);
    }

    function _boundedBaseFee() internal view returns (uint256 baseFee) {
        baseFee = gasback.gasbackMaxBaseFee();
        if (baseFee == 0) {
            return 0;
        }
        if (baseFee > 1 gwei) {
            return 1 gwei;
        }
    }

    function _expectedPayoutAndAccruedDelta(uint256 baseFee, uint256 gasToBurn)
        internal
        view
        returns (uint256 expectedPayout, uint256 expectedAccruedDelta)
    {
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 expectedShare = (ethFromGas * gasback.baseFeeVaultShareNumerator()) / DENOMINATOR;
        expectedPayout = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;
        expectedAccruedDelta = expectedShare - expectedPayout;
    }

    function _tryReadAddress(address target, string memory signature)
        internal
        view
        returns (bool ok, address value)
    {
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSignature(signature));
        if (ok && data.length == 32) {
            value = abi.decode(data, (address));
        } else {
            ok = false;
        }
    }

    function _tryReadUint(address target, string memory signature)
        internal
        view
        returns (bool ok, uint256 value)
    {
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSignature(signature));
        if (ok && data.length == 32) {
            value = abi.decode(data, (uint256));
        } else {
            ok = false;
        }
    }
}
