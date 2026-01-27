// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {ShapePaymentSplitter} from "../src/ShapePaymentSplitter.sol";

contract ShapePaymentSplitterTest is SoladyTest {
    ShapePaymentSplitter public splitter;

    /// @dev fuzz helpers

    // Struct to reduce stack depth in fuzz tests
    struct FuzzTestState {
        address[] fuzzPayees;
        uint256[] fuzzShares;
        uint256[] initialBalances;
        uint256 totalSharesSum;
        uint256 cumulativeTotalPaid;
        ShapePaymentSplitter fuzzSplitter;
    }

    function _createFuzzTestState(uint8 numPayees, uint256 addrOffset)
        internal
        returns (FuzzTestState memory state)
    {
        state.fuzzPayees = new address[](numPayees);
        state.fuzzShares = new uint256[](numPayees);
        state.initialBalances = new uint256[](numPayees);

        for (uint256 i = 0; i < numPayees; i++) {
            state.fuzzPayees[i] = vm.addr(i + addrOffset);
            state.fuzzShares[i] = (i % 100) + 1;
            state.totalSharesSum += state.fuzzShares[i];
        }

        state.fuzzSplitter = new ShapePaymentSplitter(state.fuzzPayees, state.fuzzShares);

        for (uint256 i = 0; i < numPayees; i++) {
            state.initialBalances[i] = state.fuzzPayees[i].balance;
        }
    }

    function _sendPaymentAndUpdateState(FuzzTestState memory state, uint256 paymentAmount)
        internal
    {
        state.cumulativeTotalPaid += paymentAmount;
        vm.deal(address(this), paymentAmount);
        (bool success,) = address(state.fuzzSplitter).call{value: paymentAmount}("");
        assertTrue(success);
    }

    function _verifyPayeeBalances(FuzzTestState memory state, uint8 numPayees) internal view {
        for (uint256 i = 0; i < numPayees; i++) {
            uint256 actualReceived = state.fuzzPayees[i].balance - state.initialBalances[i];
            uint256 expectedReceived =
                (state.cumulativeTotalPaid * state.fuzzShares[i]) / state.totalSharesSum;
            assertEq(actualReceived, expectedReceived);
        }
    }

    address[] public payees = new address[](3);
    uint256[] public shares = new uint256[](3);

    uint256 private _deployerKey = 1;

    uint256 private _payee1Key = 2;
    uint256 private _payee2Key = 3;
    uint256 private _payee3Key = 4;

    address private deployer = vm.addr(_deployerKey);

    address private payee1 = vm.addr(_payee1Key);
    address private payee2 = vm.addr(_payee2Key);
    address private payee3 = vm.addr(_payee3Key);

    uint256 public shares1 = 48;
    uint256 public shares2 = 42;
    uint256 public shares3 = 10;

    function setUp() public {
        payees[0] = payee1;
        payees[1] = payee2;
        payees[2] = payee3;

        shares[0] = shares1;
        shares[1] = shares2;
        shares[2] = shares3;

        splitter = new ShapePaymentSplitter(payees, shares);
    }

    function test_read_public_variables() public {
        assertEq(splitter.payees().length, 3);
        assertEq(splitter.totalShares(), 100);
        assertEq(splitter.shares(payee1), shares1);
        assertEq(splitter.shares(payee2), shares2);
        assertEq(splitter.shares(payee3), shares3);
        assertEq(splitter.payee(0), payee1);
        assertEq(splitter.payee(1), payee2);
        assertEq(splitter.payee(2), payee3);
    }

    function test_balances_after_payment() public {
        uint256 paymentAmount = 10 ether;

        // Record balances before
        uint256 balanceBefore1 = payee1.balance;
        uint256 balanceBefore2 = payee2.balance;
        uint256 balanceBefore3 = payee3.balance;

        // Send ETH to the splitter (triggers receive() which releases to all payees)
        vm.deal(address(this), paymentAmount);
        (bool success,) = address(splitter).call{value: paymentAmount}("");
        assertTrue(success, "Payment to splitter failed");

        // Record balances after
        uint256 balanceAfter1 = payee1.balance;
        uint256 balanceAfter2 = payee2.balance;
        uint256 balanceAfter3 = payee3.balance;

        // Calculate expected amounts based on shares
        uint256 totalShares = splitter.totalShares();
        uint256 expectedPayment1 = (paymentAmount * shares1) / totalShares;
        uint256 expectedPayment2 = (paymentAmount * shares2) / totalShares;
        uint256 expectedPayment3 = (paymentAmount * shares3) / totalShares;

        // Verify balance changes match expected payments
        assertEq(
            balanceAfter1 - balanceBefore1, expectedPayment1, "Payee1 received incorrect amount"
        );
        assertEq(
            balanceAfter2 - balanceBefore2, expectedPayment2, "Payee2 received incorrect amount"
        );
        assertEq(
            balanceAfter3 - balanceBefore3, expectedPayment3, "Payee3 received incorrect amount"
        );

        // Verify the exact amounts (48%, 42%, 10% of 10 ether)
        assertEq(balanceAfter1 - balanceBefore1, 4.8 ether, "Payee1 should receive 4.8 ether");
        assertEq(balanceAfter2 - balanceBefore2, 4.2 ether, "Payee2 should receive 4.2 ether");
        assertEq(balanceAfter3 - balanceBefore3, 1 ether, "Payee3 should receive 1 ether");
    }

    function testFuzz_balances_after_payment(uint8 numPayees, uint256 paymentAmount) public {
        numPayees = uint8(bound(numPayees, 1, 50));
        paymentAmount = bound(paymentAmount, 1 ether, 1000 ether);

        FuzzTestState memory state = _createFuzzTestState(numPayees, 100);

        _sendPaymentAndUpdateState(state, paymentAmount);
        _verifyPayeeBalances(state, numPayees);

        assertLe(address(state.fuzzSplitter).balance, uint256(numPayees));
    }

    function testFuzz_balances_after_multiple_payments(
        uint8 numPayees,
        uint256[9] memory paymentAmounts
    ) public {
        numPayees = uint8(bound(numPayees, 1, 50));

        FuzzTestState memory state = _createFuzzTestState(numPayees, 200);

        for (uint256 p = 0; p < 9; p++) {
            uint256 paymentAmount = bound(paymentAmounts[p], 0.1 ether, 10 ether);
            _sendPaymentAndUpdateState(state, paymentAmount);
            _verifyPayeeBalances(state, numPayees);
        }

        assertLe(address(state.fuzzSplitter).balance, uint256(numPayees) * 9);
    }

    /// @dev deployment revert tests

    function test_revert_deploy_empty_payees() public {
        address[] memory emptyPayees = new address[](0);
        uint256[] memory emptyShares = new uint256[](0);

        vm.expectRevert(ShapePaymentSplitter.NoPayees.selector);
        new ShapePaymentSplitter(emptyPayees, emptyShares);
    }

    function test_revert_deploy_length_mismatch_more_payees() public {
        address[] memory morePayees = new address[](3);
        morePayees[0] = payee1;
        morePayees[1] = payee2;
        morePayees[2] = payee3;

        uint256[] memory fewerShares = new uint256[](2);
        fewerShares[0] = 50;
        fewerShares[1] = 50;

        vm.expectRevert(ShapePaymentSplitter.PayeesAndSharesLengthMismatch.selector);
        new ShapePaymentSplitter(morePayees, fewerShares);
    }

    function test_revert_deploy_length_mismatch_more_shares() public {
        address[] memory fewerPayees = new address[](2);
        fewerPayees[0] = payee1;
        fewerPayees[1] = payee2;

        uint256[] memory moreShares = new uint256[](3);
        moreShares[0] = 40;
        moreShares[1] = 40;
        moreShares[2] = 20;

        vm.expectRevert(ShapePaymentSplitter.PayeesAndSharesLengthMismatch.selector);
        new ShapePaymentSplitter(fewerPayees, moreShares);
    }

    function test_revert_deploy_zero_address_payee() public {
        address[] memory badPayees = new address[](2);
        badPayees[0] = payee1;
        badPayees[1] = address(0);

        uint256[] memory validShares = new uint256[](2);
        validShares[0] = 50;
        validShares[1] = 50;

        vm.expectRevert(ShapePaymentSplitter.AccountIsTheZeroAddress.selector);
        new ShapePaymentSplitter(badPayees, validShares);
    }

    function test_revert_deploy_zero_shares() public {
        address[] memory validPayees = new address[](2);
        validPayees[0] = payee1;
        validPayees[1] = payee2;

        uint256[] memory badShares = new uint256[](2);
        badShares[0] = 100;
        badShares[1] = 0;

        vm.expectRevert(ShapePaymentSplitter.SharesAreZero.selector);
        new ShapePaymentSplitter(validPayees, badShares);
    }

    function test_revert_deploy_duplicate_payee() public {
        address[] memory duplicatePayees = new address[](3);
        duplicatePayees[0] = payee1;
        duplicatePayees[1] = payee2;
        duplicatePayees[2] = payee1; // duplicate

        uint256[] memory validShares = new uint256[](3);
        validShares[0] = 40;
        validShares[1] = 40;
        validShares[2] = 20;

        vm.expectRevert(ShapePaymentSplitter.AccountAlreadyHasShares.selector);
        new ShapePaymentSplitter(duplicatePayees, validShares);
    }

    function test_revert_release_account_has_no_shares() public {
        address nonPayee = vm.addr(999);

        vm.expectRevert(ShapePaymentSplitter.AccountHasNoShares.selector);
        splitter.release(payable(nonPayee));
    }

    function test_revert_release_account_not_due_payment() public {
        // No ETH sent to splitter, so payee1 has 0 releasable
        vm.expectRevert(ShapePaymentSplitter.AccountIsNotDuePayment.selector);
        splitter.release(payable(payee1));
    }
}
