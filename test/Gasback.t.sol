// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {Gasback} from "../src/Gasback.sol";

contract GasbackTest is SoladyTest {
    Gasback public gasback;

    function setUp() public {
        gasback = new Gasback();
        vm.deal(address(gasback), 2 ** 160);
    }

    function testConvertGasback(uint256 baseFee, uint256 gasToBurn) public {
        baseFee = _bound(baseFee, 0, 2 ** 20 - 1);
        gasToBurn = _bound(gasToBurn, 0, 2 ** 20 - 1);
        address pranker = address(111);
        assertEq(pranker.balance, 0);
        vm.fee(baseFee);
        vm.prank(pranker);
        (bool success,) = address(gasback).call(abi.encode(gasToBurn));
        assertTrue(success);
        assertEq(
            pranker.balance,
            (gasToBurn * baseFee * gasback.gasbackRatioNumerator())
                / gasback.GASBACK_RATIO_DENOMINATOR()
        );
    }

    function testConvertGasback() public {
        testConvertGasback(100, 333);
    }

    function testConvertGasbackMaxBaseFee() public {
        uint256 newMaxBaseFee = 42;
        address system = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
        vm.prank(system);
        gasback.setGasbackMaxBaseFee(newMaxBaseFee);
        vm.fee(newMaxBaseFee + 1);

        uint256 gasToBurn = 333;

        address pranker = address(111);
        assertEq(pranker.balance, 0);
        vm.prank(pranker);
        (bool success,) = address(gasback).call(abi.encode(gasToBurn));
        assertTrue(success);
        assertEq(pranker.balance, 0);
    }

    function testConvertGasbackBaseFeeVault() public {
        address system = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
        vm.prank(system);
        gasback.setBaseFeeVault(address(42));

        uint256 gasToBurn = 333;

        address pranker = address(111);
        assertEq(pranker.balance, 0);
        vm.prank(pranker);
        (bool success,) = address(gasback).call(abi.encode(gasToBurn));
        assertTrue(success);
        assertEq(pranker.balance, 0);
    }

    function testWithdrawAccruedRevertsWhenCallerUnauthorized() public {
        address system = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
        // Lower the ratio below the vault share numerator so the fallback accrues a cut.
        vm.prank(system);
        gasback.setGasbackRatioNumerator(0.5 ether);
        vm.fee(100);
        vm.prank(address(111));
        (bool success,) = address(gasback).call(abi.encode(uint256(1000)));
        assertTrue(success);
        uint256 accruedAmount = gasback.accrued();
        assertGt(accruedAmount, 0);

        // With `accrued` and the contract balance both covering `amount`, only the
        // authorization check can fail.
        address unauthorized = address(0xBAD);
        assertFalse(gasback.isAuthorizedAccuralWithdrawer(unauthorized));
        vm.prank(unauthorized);
        vm.expectRevert();
        gasback.withdrawAccrued(address(0xCAFE), accruedAmount);

        assertEq(gasback.accrued(), accruedAmount);
    }

    function testSetGasbackRatioNumeratorRevertsWhenValueAboveDenominator() public {
        address system = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
        uint256 value = gasback.GASBACK_RATIO_DENOMINATOR() + 1;
        vm.prank(system);
        vm.expectRevert();
        gasback.setGasbackRatioNumerator(value);
    }

    function testSetGasbackRatioNumeratorRevertsWhenValueAboveBaseFeeVaultShare() public {
        address system = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
        // Within the denominator, so only the vault share check fails.
        uint256 value = gasback.baseFeeVaultShareNumerator() + 1;
        assertTrue(value <= gasback.GASBACK_RATIO_DENOMINATOR());
        vm.prank(system);
        vm.expectRevert();
        gasback.setGasbackRatioNumerator(value);
    }

    function testSetBaseFeeVaultShareNumeratorRevertsWhenValueAboveDenominator() public {
        address system = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
        // Above the gasback ratio numerator, so only the denominator check fails.
        uint256 value = gasback.GASBACK_RATIO_DENOMINATOR() + 1;
        assertTrue(value >= gasback.gasbackRatioNumerator());
        vm.prank(system);
        vm.expectRevert();
        gasback.setBaseFeeVaultShareNumerator(value);
    }

    function testSetBaseFeeVaultShareNumeratorRevertsWhenValueBelowGasbackRatio() public {
        address system = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
        // Within the denominator, so only the gasback ratio check fails.
        uint256 value = gasback.gasbackRatioNumerator() - 1;
        assertTrue(value <= gasback.GASBACK_RATIO_DENOMINATOR());
        vm.prank(system);
        vm.expectRevert();
        gasback.setBaseFeeVaultShareNumerator(value);
    }
}
