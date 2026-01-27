// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {ShapePaymentSplitter} from "../src/ShapePaymentSplitter.sol";

contract ShapePaymentSplitterTest is SoladyTest {
    ShapePaymentSplitter public splitter;

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
        assertEq(balanceAfter1 - balanceBefore1, expectedPayment1, "Payee1 received incorrect amount");
        assertEq(balanceAfter2 - balanceBefore2, expectedPayment2, "Payee2 received incorrect amount");
        assertEq(balanceAfter3 - balanceBefore3, expectedPayment3, "Payee3 received incorrect amount");

        // Verify the exact amounts (48%, 42%, 10% of 10 ether)
        assertEq(balanceAfter1 - balanceBefore1, 4.8 ether, "Payee1 should receive 4.8 ether");
        assertEq(balanceAfter2 - balanceBefore2, 4.2 ether, "Payee2 should receive 4.2 ether");
        assertEq(balanceAfter3 - balanceBefore3, 1 ether, "Payee3 should receive 1 ether");
    }

    function testFuzz_balances_after_payment(uint8 numPayees, uint256 paymentAmount) public {
        // Bound inputs to reasonable ranges
        numPayees = uint8(bound(numPayees, 1, 50));
        paymentAmount = bound(paymentAmount, 1 ether, 1000 ether);

        // Create dynamic arrays for payees and shares
        address[] memory fuzzPayees = new address[](numPayees);
        uint256[] memory fuzzShares = new uint256[](numPayees);
        uint256[] memory balancesBefore = new uint256[](numPayees);

        uint256 totalSharesSum = 0;

        // Generate payees and shares
        for (uint256 i = 0; i < numPayees; i++) {
            // Generate unique addresses using index + 100 to avoid collisions with existing test addresses
            fuzzPayees[i] = vm.addr(i + 100);
            // Assign shares between 1 and 100 based on index (deterministic for reproducibility)
            fuzzShares[i] = (i % 100) + 1;
            totalSharesSum += fuzzShares[i];
        }

        // Deploy new splitter with fuzzed payees and shares
        ShapePaymentSplitter fuzzSplitter = new ShapePaymentSplitter(fuzzPayees, fuzzShares);

        // Record balances before
        for (uint256 i = 0; i < numPayees; i++) {
            balancesBefore[i] = fuzzPayees[i].balance;
        }

        // Send ETH to the splitter
        vm.deal(address(this), paymentAmount);
        (bool success,) = address(fuzzSplitter).call{value: paymentAmount}("");
        assertTrue(success, "Payment to splitter failed");

        // Verify balance changes for each payee
        for (uint256 i = 0; i < numPayees; i++) {
            uint256 balanceAfter = fuzzPayees[i].balance;
            uint256 expectedPayment = (paymentAmount * fuzzShares[i]) / totalSharesSum;
            assertEq(
                balanceAfter - balancesBefore[i],
                expectedPayment,
                string.concat("Payee ", vm.toString(i), " received incorrect amount")
            );
        }

        // Verify splitter contract has no remaining balance (or only dust from rounding)
        assertLe(address(fuzzSplitter).balance, numPayees, "Splitter should have minimal remaining balance");
    }
}
