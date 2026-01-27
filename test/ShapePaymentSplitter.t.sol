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

    function test_Splitter() public {
        assertEq(splitter.payeeCount(), 3);
        assertEq(splitter.totalShares(), 100);
        assertEq(splitter.shares(payee1), shares1);
        assertEq(splitter.shares(payee2), shares2);
        assertEq(splitter.shares(payee3), shares3);
        assertEq(splitter.payee(0), payee1);
        assertEq(splitter.payee(1), payee2);
        assertEq(splitter.payee(2), payee3);
    }
}
