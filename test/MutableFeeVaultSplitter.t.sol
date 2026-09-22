// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {MutableFeeVaultSplitter} from "../src/MutableFeeVaultSplitter.sol";
import {FeeVaultSplitter} from "../src/FeeVaultSplitter.sol";
import {Gasback} from "../src/Gasback.sol";

contract MutableSplitterPayee {
    bool public rejecting = true;
    address public target;
    bytes public callback;
    bool public callbackSucceeded;

    function acceptPayments() external {
        rejecting = false;
    }

    function setCallback(address target_, bytes calldata callback_) external {
        target = target_;
        callback = callback_;
    }

    receive() external payable {
        require(!rejecting, "Payment rejected");
        if (target != address(0)) {
            (callbackSucceeded,) = target.call(callback);
        }
    }
}

contract MutableFeeVaultSplitterTest is Test {
    event SharesUpdated(uint256[] shares);
    event PaymentReceived(address from, uint256 amount);
    event PaymentReleased(address to, uint256 amount);
    event PaymentFailed(address to, uint256 amount);

    address private constant OWNER = address(0xA11CE);
    address private constant ALICE = address(0xB0B);
    address private constant BOB = address(0xCAFE);
    MutableFeeVaultSplitter private splitter;
    address[] private payees;
    uint256[] private weights;

    function setUp() public {
        payees.push(ALICE);
        payees.push(BOB);
        weights.push(60);
        weights.push(40);
        splitter = new MutableFeeVaultSplitter(OWNER, payees, weights);
    }

    function test_constructorSetsExplicitOwnerAndFixedPayees() public view {
        assertEq(splitter.owner(), OWNER);
        assertEq(splitter.externalPayees(0), ALICE);
        assertEq(splitter.payee(1), BOB);
        assertEq(splitter.shares(ALICE), 60);
        assertEq(splitter.shares(BOB), 40);
        assertEq(splitter.totalShares(), 100);
    }

    function test_receiveAutomaticallyDistributes() public {
        vm.deal(address(this), 10 ether);
        vm.expectEmit(address(splitter));
        emit PaymentReceived(address(this), 10 ether);
        vm.expectEmit(address(splitter));
        emit PaymentReleased(ALICE, 6 ether);
        vm.expectEmit(address(splitter));
        emit PaymentReleased(BOB, 4 ether);
        (bool success,) = address(splitter).call{value: 10 ether}("");
        assertTrue(success);
        assertEq(ALICE.balance, 6 ether);
        assertEq(BOB.balance, 4 ether);
        assertEq(splitter.totalReleased(), 10 ether);
    }

    function test_updateDoesNotRecalculatePreviouslyReleasedETH() public {
        vm.deal(address(splitter), 10 ether);
        splitter.distribute(0, 2);
        weights[0] = 20;
        weights[1] = 80;
        vm.expectEmit(address(splitter));
        emit SharesUpdated(weights);
        vm.prank(OWNER);
        splitter.setShares(weights);
        assertEq(splitter.releasable(ALICE), 0);
        assertEq(splitter.releasable(BOB), 0);

        vm.deal(address(this), 10 ether);
        (bool success,) = address(splitter).call{value: 10 ether}("");
        assertTrue(success);
        assertEq(ALICE.balance, 8 ether);
        assertEq(BOB.balance, 12 ether);
        assertEq(splitter.released(ALICE), 8 ether);
        assertEq(splitter.totalReleased(), 20 ether);
        assertEq(splitter.payee(0), ALICE);
        assertEq(splitter.payee(1), BOB);
    }

    function test_updatePreservesUnreleasedAndForcedETH() public {
        vm.deal(address(splitter), 10 ether);
        splitter.release(payable(ALICE));
        weights[0] = 1;
        weights[1] = 0;
        vm.prank(OWNER);
        splitter.setShares(weights);
        assertEq(splitter.releasable(BOB), 4 ether);
        assertEq(splitter.releasable(ALICE), 0);

        vm.deal(address(splitter), 14 ether);
        splitter.distribute(0, 2);
        assertEq(ALICE.balance, 16 ether);
        assertEq(BOB.balance, 4 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_rejectingPayeeKeepsClaimAfterZeroShareUpdate() public {
        MutableSplitterPayee recipient = new MutableSplitterPayee();
        payees[0] = address(recipient);
        splitter = new MutableFeeVaultSplitter(OWNER, payees, weights);
        vm.deal(address(this), 10 ether);
        vm.expectEmit(address(splitter));
        emit PaymentFailed(address(recipient), 6 ether);
        (bool success,) = address(splitter).call{value: 10 ether}("");
        assertTrue(success);
        assertEq(BOB.balance, 4 ether);
        assertEq(splitter.releasable(address(recipient)), 6 ether);
        assertEq(splitter.totalReleased(), 4 ether);

        weights[0] = 0;
        weights[1] = 1;
        vm.prank(OWNER);
        splitter.setShares(weights);
        vm.deal(address(splitter), 16 ether);
        splitter.distribute(1, 2);
        assertEq(BOB.balance, 14 ether);
        assertEq(splitter.releasable(address(recipient)), 6 ether);

        vm.expectRevert(MutableFeeVaultSplitter.PaymentTransferFailed.selector);
        splitter.release(payable(address(recipient)));
        assertEq(splitter.releasable(address(recipient)), 6 ether);
        recipient.acceptPayments();
        splitter.release(payable(address(recipient)));
        assertEq(address(recipient).balance, 6 ether);
        assertEq(splitter.totalReleased(), 20 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_roundingDustCarriesIntoNewShares() public {
        vm.deal(address(splitter), 3);
        splitter.distribute(0, 2);
        assertEq(ALICE.balance, 1);
        assertEq(BOB.balance, 1);
        assertEq(address(splitter).balance, 1);
        weights[0] = 0;
        weights[1] = 100;
        vm.prank(OWNER);
        splitter.setShares(weights);
        splitter.distribute(0, 2);
        assertEq(ALICE.balance, 1);
        assertEq(BOB.balance, 2);
        assertEq(address(splitter).balance, 0);
    }

    function test_constructorETHRemainsClaimableUnderInitialShares() public {
        vm.deal(address(this), 10 ether);
        splitter = new MutableFeeVaultSplitter{value: 10 ether}(OWNER, payees, weights);
        weights[0] = 1;
        weights[1] = 1;
        vm.prank(OWNER);
        splitter.setShares(weights);
        splitter.distribute(0, 2);
        assertEq(ALICE.balance, 6 ether);
        assertEq(BOB.balance, 4 ether);
    }

    function test_onlyOwnerCanChangeSharesAndOwnershipRequiresAcceptance() public {
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setShares(weights);
        vm.prank(OWNER);
        splitter.transferOwnership(ALICE);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        splitter.acceptOwnership();
        vm.startPrank(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setShares(weights);
        splitter.acceptOwnership();
        weights[0] = 3;
        weights[1] = 7;
        splitter.setShares(weights);
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setShares(weights);
        assertEq(splitter.owner(), ALICE);
        assertEq(splitter.shares(ALICE), 3);
    }

    function test_renouncingOwnershipFreezesSharesAndKeepsPaymentsWorking() public {
        vm.prank(OWNER);
        splitter.renounceOwnership();
        vm.prank(OWNER);
        vm.expectRevert("Ownable: caller is not the owner");
        splitter.setShares(weights);
        vm.deal(address(splitter), 10 ether);
        splitter.distribute(0, 2);
        assertEq(ALICE.balance, 6 ether);
        assertEq(BOB.balance, 4 ether);
    }

    function test_revertsOnInvalidConfiguration() public {
        vm.expectRevert(MutableFeeVaultSplitter.InvalidOwner.selector);
        new MutableFeeVaultSplitter(address(0), payees, weights);
        vm.expectRevert(MutableFeeVaultSplitter.InvalidShares.selector);
        new MutableFeeVaultSplitter(OWNER, payees, new uint256[](1));
        vm.expectRevert(MutableFeeVaultSplitter.InvalidPayee.selector);
        new MutableFeeVaultSplitter(OWNER, new address[](0), new uint256[](0));
        payees[0] = address(0);
        vm.expectRevert(MutableFeeVaultSplitter.InvalidPayee.selector);
        new MutableFeeVaultSplitter(OWNER, payees, weights);
        payees[0] = BOB;
        vm.expectRevert(MutableFeeVaultSplitter.InvalidPayee.selector);
        new MutableFeeVaultSplitter(OWNER, payees, weights);
        vm.startPrank(OWNER);
        vm.expectRevert(MutableFeeVaultSplitter.InvalidShares.selector);
        splitter.setShares(new uint256[](1));
        vm.expectRevert(MutableFeeVaultSplitter.InvalidShares.selector);
        splitter.setShares(new uint256[](2));
        vm.stopPrank();
        payees[0] = ALICE;
        vm.expectRevert(MutableFeeVaultSplitter.InvalidShares.selector);
        new MutableFeeVaultSplitter(OWNER, payees, new uint256[](2));
        assertEq(splitter.totalShares(), 100);
    }

    function test_zeroSharePayeeCanBeActivated() public {
        weights[0] = 0;
        splitter = new MutableFeeVaultSplitter(OWNER, payees, weights);
        vm.deal(address(splitter), 10 ether);
        weights[0] = 40;
        vm.prank(OWNER);
        splitter.setShares(weights);
        assertEq(splitter.releasable(ALICE), 0);
        assertEq(splitter.releasable(BOB), 10 ether);
        vm.deal(address(splitter), 20 ether);
        splitter.distribute(0, 2);
        assertEq(ALICE.balance, 5 ether);
        assertEq(BOB.balance, 15 ether);
    }

    function test_largeSharesUseFullPrecisionAndOverflowingTotalsRevert() public {
        weights[0] = type(uint256).max / 2;
        weights[1] = type(uint256).max / 2;
        splitter = new MutableFeeVaultSplitter(OWNER, payees, weights);
        vm.deal(address(splitter), 10 ether);
        weights[0] = type(uint256).max;
        weights[1] = 1;
        vm.startPrank(OWNER);
        vm.expectRevert(stdError.arithmeticError);
        splitter.setShares(weights);
        assertEq(splitter.releasable(ALICE), 5 ether);
        weights[1] = 0;
        splitter.setShares(weights);
        vm.stopPrank();
        vm.deal(address(splitter), 20 ether);
        splitter.distribute(0, 2);
        assertEq(ALICE.balance, 15 ether);
        assertEq(BOB.balance, 5 ether);
    }

    function test_duplicateZeroSharePayeeReverts() public {
        payees[0] = BOB;
        weights[0] = 0;
        vm.expectRevert(MutableFeeVaultSplitter.InvalidPayee.selector);
        new MutableFeeVaultSplitter(OWNER, payees, weights);
    }

    function test_distributeSlicesAndEmptyClaims() public {
        vm.expectRevert(MutableFeeVaultSplitter.InvalidPayee.selector);
        splitter.release(payable(address(this)));
        vm.expectRevert(MutableFeeVaultSplitter.NoPaymentDue.selector);
        splitter.release(payable(ALICE));
        vm.deal(address(splitter), 10 ether);
        splitter.distribute(2, 1);
        splitter.distribute(3, type(uint256).max);
        assertEq(splitter.totalReleased(), 0);
        splitter.distribute(1, type(uint256).max);
        assertEq(BOB.balance, 4 ether);
        assertEq(ALICE.balance, 0);
        splitter.release(payable(ALICE));
        splitter.distribute(0, 2);
        assertEq(ALICE.balance, 6 ether);
    }

    function test_ownerPayeeCannotUpdateSharesDuringPayout() public {
        MutableSplitterPayee recipient = new MutableSplitterPayee();
        recipient.acceptPayments();
        payees[0] = address(recipient);
        splitter = new MutableFeeVaultSplitter(address(recipient), payees, weights);
        weights[0] = 0;
        weights[1] = 100;
        recipient.setCallback(address(splitter), abi.encodeCall(splitter.setShares, (weights)));
        vm.deal(address(this), 10 ether);
        (bool success,) = address(splitter).call{value: 10 ether}("");
        assertTrue(success);
        assertFalse(recipient.callbackSucceeded());
        assertEq(splitter.shares(address(recipient)), 60);
        assertEq(address(recipient).balance, 6 ether);
        assertEq(BOB.balance, 4 ether);
    }

    function test_releaseAndDistributeBlockReentrantClaims() public {
        MutableSplitterPayee recipient = new MutableSplitterPayee();
        recipient.acceptPayments();
        payees[0] = address(recipient);
        splitter = new MutableFeeVaultSplitter(OWNER, payees, weights);
        recipient.setCallback(address(splitter), abi.encodeCall(splitter.release, (payable(BOB))));
        vm.deal(address(splitter), 10 ether);
        splitter.release(payable(address(recipient)));
        assertFalse(recipient.callbackSucceeded());
        assertEq(BOB.balance, 0);
        recipient.setCallback(address(splitter), abi.encodeCall(splitter.distribute, (0, 2)));
        vm.deal(address(splitter), 14 ether);
        splitter.distribute(0, 2);
        assertFalse(recipient.callbackSucceeded());
        assertEq(address(recipient).balance, 12 ether);
        assertEq(BOB.balance, 8 ether);
    }

    function test_forwardsFeesToGasbackAfterShareChange() public {
        Gasback gasback = new Gasback();
        payees[0] = address(gasback);
        splitter = new MutableFeeVaultSplitter(OWNER, payees, weights);
        vm.deal(address(this), 20 ether);
        (bool firstSuccess,) = address(splitter).call{value: 10 ether}("");
        assertTrue(firstSuccess);
        weights[0] = 90;
        weights[1] = 10;
        vm.prank(OWNER);
        splitter.setShares(weights);
        (bool secondSuccess,) = address(splitter).call{value: 10 ether}("");
        assertTrue(secondSuccess);
        assertEq(address(gasback).balance, 15 ether);
        assertEq(BOB.balance, 5 ether);
    }

    function testFuzz_unchangedSharesMatchOpenZeppelin(uint96[8] memory amounts) public {
        address[] memory referencePayees = new address[](2);
        referencePayees[0] = address(0x1111);
        referencePayees[1] = address(0x2222);
        FeeVaultSplitter referenceSplitter = new FeeVaultSplitter(referencePayees, weights);
        for (uint256 i; i < amounts.length; ++i) {
            vm.deal(address(this), uint256(amounts[i]) * 2);
            (bool success,) = address(splitter).call{value: amounts[i]}("");
            (bool referenceSuccess,) = address(referenceSplitter).call{value: amounts[i]}("");
            assertTrue(success && referenceSuccess);
            assertEq(ALICE.balance, referencePayees[0].balance);
            assertEq(BOB.balance, referencePayees[1].balance);
            assertEq(address(splitter).balance, address(referenceSplitter).balance);
        }
    }

    function testFuzz_multiplePayeesKeepExistingClaimsAfterUpdate(
        uint8 count,
        uint96 initialAmount,
        uint96 futureAmount
    ) public {
        count = uint8(bound(count, 1, 12));
        address[] memory recipients = new address[](count);
        uint256[] memory allocations = new uint256[](count);
        uint256[] memory earned = new uint256[](count);
        uint256 totalWeight;
        for (uint256 i; i < count; ++i) {
            recipients[i] = address(uint160(0x10000 + i));
            allocations[i] = i + 1;
            totalWeight += i + 1;
        }
        splitter = new MutableFeeVaultSplitter(OWNER, recipients, allocations);
        vm.deal(address(splitter), initialAmount);
        splitter.distribute(0, count / 2);
        uint256 allocated;
        for (uint256 i; i < count; ++i) {
            earned[i] = uint256(initialAmount) * allocations[i] / totalWeight;
            allocated += earned[i];
            allocations[i] = count - i;
        }
        vm.prank(OWNER);
        splitter.setShares(allocations);
        vm.deal(address(splitter), address(splitter).balance + futureAmount);
        splitter.distribute(0, count);
        uint256 nextAmount = uint256(initialAmount) - allocated + futureAmount;
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            uint256 expected = earned[i] + nextAmount * allocations[i] / totalWeight;
            assertEq(recipients[i].balance, expected);
            assertEq(splitter.releasable(recipients[i]), 0);
            paid += expected;
        }
        assertEq(paid + address(splitter).balance, uint256(initialAmount) + futureAmount);
        assertLt(address(splitter).balance, count);
    }

    function testFuzz_updatesPreserveClaimsAndConserveETH(
        uint96[8] memory amounts,
        uint32[8] memory aliceWeights,
        uint32[8] memory bobWeights
    ) public {
        MutableSplitterPayee recipient = new MutableSplitterPayee();
        payees[0] = address(recipient);
        splitter = new MutableFeeVaultSplitter(OWNER, payees, weights);
        uint256 expectedAlice;
        uint256 expectedBob;
        uint256 carry;
        uint256 received;
        for (uint256 i; i < amounts.length; ++i) {
            vm.deal(address(this), amounts[i]);
            (bool success,) = address(splitter).call{value: amounts[i]}("");
            assertTrue(success);
            received += amounts[i];
            uint256 epochAmount = carry + amounts[i];
            uint256 aliceAmount = epochAmount * weights[0] / (weights[0] + weights[1]);
            uint256 bobAmount = epochAmount * weights[1] / (weights[0] + weights[1]);
            expectedAlice += aliceAmount;
            expectedBob += bobAmount;
            carry = epochAmount - aliceAmount - bobAmount;
            assertEq(splitter.releasable(address(recipient)), expectedAlice);
            assertEq(BOB.balance, expectedBob);
            assertEq(address(splitter).balance + splitter.totalReleased(), received);
            weights[0] = aliceWeights[i];
            weights[1] = uint256(bobWeights[i]) + 1;
            vm.prank(OWNER);
            splitter.setShares(weights);
        }
        recipient.acceptPayments();
        splitter.distribute(0, 2);
        assertEq(
            address(recipient).balance,
            expectedAlice + carry * weights[0] / (weights[0] + weights[1])
        );
        assertEq(BOB.balance, expectedBob + carry * weights[1] / (weights[0] + weights[1]));
        assertEq(address(recipient).balance + BOB.balance + address(splitter).balance, received);
        assertLe(address(splitter).balance, 1);
    }
}
