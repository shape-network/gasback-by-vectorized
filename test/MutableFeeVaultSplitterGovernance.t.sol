// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {MutableFeeVaultSplitter} from "../src/MutableFeeVaultSplitter.sol";
import {FeeVaultSplitter} from "../src/FeeVaultSplitter.sol";
import {Gasback} from "../src/Gasback.sol";
import {SplitterAuditVault} from "./MutableFeeVaultSplitterAdversarial.t.sol";

contract MutableFeeVaultSplitterGovernanceTest is Test {
    address private constant GOVERNOR = address(0x600D);
    address private constant RECIPIENT_A = address(0xA11CE);
    address private constant RECIPIENT_B = address(0xB0B);
    address private constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    TimelockController private governanceExecutor;
    MutableFeeVaultSplitter private splitter;
    address[] private payees;
    uint256[] private weights;

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = GOVERNOR;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        governanceExecutor = new TimelockController(1 days, proposers, executors, address(0));
        payees.push(RECIPIENT_A);
        payees.push(RECIPIENT_B);
        weights.push(60);
        weights.push(40);
        splitter = new MutableFeeVaultSplitter(address(governanceExecutor), payees, weights);
    }

    function test_governanceExecutionChangesOnlyFutureSplitForTwoFixedRecipients() public {
        weights[0] = 20;
        weights[1] = 80;
        bytes memory payload = abi.encodeCall(splitter.setShares, (weights));
        bytes32 salt = keccak256("approved split proposal");
        vm.prank(GOVERNOR);
        governanceExecutor.schedule(address(splitter), 0, payload, bytes32(0), salt, 1 days);

        vm.deal(address(this), 20 ether);
        (bool beforeExecution,) = address(splitter).call{value: 10 ether}("");
        assertTrue(beforeExecution);
        assertEq(RECIPIENT_A.balance, 6 ether);
        assertEq(RECIPIENT_B.balance, 4 ether);
        vm.expectRevert("TimelockController: operation is not ready");
        governanceExecutor.execute(address(splitter), 0, payload, bytes32(0), salt);
        vm.warp(block.timestamp + 1 days);
        governanceExecutor.execute(address(splitter), 0, payload, bytes32(0), salt);

        (bool afterExecution,) = address(splitter).call{value: 10 ether}("");
        assertTrue(afterExecution);
        assertEq(RECIPIENT_A.balance, 8 ether);
        assertEq(RECIPIENT_B.balance, 12 ether);
        assertEq(splitter.owner(), address(governanceExecutor));
        assertEq(splitter.payee(0), RECIPIENT_A);
        assertEq(splitter.payee(1), RECIPIENT_B);
        vm.expectRevert();
        splitter.payee(2);
        vm.expectRevert("TimelockController: operation is not ready");
        governanceExecutor.execute(address(splitter), 0, payload, bytes32(0), salt);
    }

    function test_votersRecipientsAndProposerCannotBypassGovernanceExecutor() public {
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setShares(weights);
        vm.prank(RECIPIENT_A);
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setShares(weights);
        vm.prank(RECIPIENT_B);
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setShares(weights);
        vm.prank(GOVERNOR);
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setShares(weights);
        bytes memory payload = abi.encodeCall(splitter.setShares, (weights));
        vm.expectRevert();
        governanceExecutor.schedule(address(splitter), 0, payload, bytes32(0), bytes32(0), 1 days);
    }

    function test_governanceCannotChangeNumberOfRecipientsThroughShares() public {
        uint256[] memory invalidWeights = new uint256[](3);
        invalidWeights[0] = 50;
        invalidWeights[1] = 40;
        invalidWeights[2] = 10;
        bytes memory payload = abi.encodeCall(splitter.setShares, (invalidWeights));
        vm.prank(GOVERNOR);
        governanceExecutor.schedule(address(splitter), 0, payload, bytes32(0), bytes32(0), 1 days);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("TimelockController: underlying transaction reverted");
        governanceExecutor.execute(address(splitter), 0, payload, bytes32(0), bytes32(0));
        assertEq(splitter.shares(RECIPIENT_A), 60);
        assertEq(splitter.shares(RECIPIENT_B), 40);
    }

    function testFuzz_governanceSplitMatchesImmutableGasbackFundingBehavior(
        uint8 percentage,
        uint96 rawVaultBalance,
        uint96 rawBuffer,
        uint16 rawGasToBurn
    ) public {
        uint256 gasbackPercentage = bound(percentage, 1, 99);
        uint256 gasToBurn = bound(rawGasToBurn, 1, 10_000);
        uint256 requestedPayout = gasToBurn * 1 gwei * 60 / 100;
        uint256 vaultBalance = bound(rawVaultBalance, 0, requestedPayout * 2);
        uint256 buffer = bound(rawBuffer, 0, requestedPayout);
        Gasback mutableGasback = new Gasback();
        Gasback immutableGasback = new Gasback();
        payees[0] = address(mutableGasback);
        splitter = new MutableFeeVaultSplitter(address(governanceExecutor), payees, weights);
        weights[0] = gasbackPercentage;
        weights[1] = 100 - gasbackPercentage;
        payees[0] = address(immutableGasback);
        payees[1] = RECIPIENT_A;
        FeeVaultSplitter immutableSplitter = new FeeVaultSplitter(payees, weights);
        bytes memory payload = abi.encodeCall(splitter.setShares, (weights));
        vm.prank(GOVERNOR);
        governanceExecutor.schedule(address(splitter), 0, payload, bytes32(0), bytes32(0), 1 days);
        vm.warp(block.timestamp + 1 days);
        governanceExecutor.execute(address(splitter), 0, payload, bytes32(0), bytes32(0));

        SplitterAuditVault mutableVault = new SplitterAuditVault(address(splitter));
        SplitterAuditVault immutableVault = new SplitterAuditVault(address(immutableSplitter));
        vm.startPrank(SYSTEM);
        mutableGasback.setBaseFeeVault(address(mutableVault));
        immutableGasback.setBaseFeeVault(address(immutableVault));
        vm.stopPrank();
        vm.deal(address(mutableVault), vaultBalance);
        vm.deal(address(immutableVault), vaultBalance);
        vm.deal(address(mutableGasback), buffer);
        vm.deal(address(immutableGasback), buffer);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        vm.prank(address(0xC1));
        (bool mutableSuccess, bytes memory mutableResult) =
            address(mutableGasback).call(abi.encode(gasToBurn));
        vm.prank(address(0xC2));
        (bool immutableSuccess, bytes memory immutableResult) =
            address(immutableGasback).call(abi.encode(gasToBurn));

        assertTrue(mutableSuccess && immutableSuccess);
        assertEq(mutableResult, immutableResult);
        assertEq(address(0xC1).balance, address(0xC2).balance);
        assertEq(address(mutableVault).balance, address(immutableVault).balance);
        assertEq(address(mutableGasback).balance, address(immutableGasback).balance);
        assertEq(RECIPIENT_B.balance, RECIPIENT_A.balance);
        assertEq(address(splitter).balance, address(immutableSplitter).balance);
        assertEq(splitter.totalReleased(), immutableSplitter.totalReleased());
        assertEq(mutableGasback.gasbackRatioNumerator(), 0.6 ether);
        assertEq(immutableGasback.gasbackRatioNumerator(), 0.6 ether);
    }
}
