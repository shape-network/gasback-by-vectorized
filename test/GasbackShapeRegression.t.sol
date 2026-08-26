// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {Gasback} from "../src/Gasback.sol";

contract ShapeRegressionRejectingReceiver {
    receive() external payable {
        revert();
    }
}

contract ShapeRegressionRejectingCaller {
    function trigger(address target, uint256 gasToBurn) external returns (uint256 ethToGive) {
        (bool success, bytes memory data) = target.call(abi.encode(gasToBurn));
        require(success);
        ethToGive = abi.decode(data, (uint256));
    }

    receive() external payable {
        revert();
    }
}

contract ShapeRegressionAcceptingCaller {
    function trigger(address target, uint256 gasToBurn) external returns (uint256 ethToGive) {
        (bool success, bytes memory data) = target.call(abi.encode(gasToBurn));
        require(success);
        ethToGive = abi.decode(data, (uint256));
    }

    receive() external payable {}
}

contract ShapeRegressionBaseFeeVault {
    address public immutable recipient;
    bool public shouldRevert;

    constructor(address recipient_) payable {
        recipient = recipient_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function withdraw() external {
        require(!shouldRevert);
        (bool success,) = recipient.call{value: address(this).balance}("");
        require(success);
    }

    receive() external payable {}
}

contract GasbackShapeRegressionTest is SoladyTest {
    address internal constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    address internal constant DEFAULT_BASE_FEE_VAULT = 0x4200000000000000000000000000000000000019;
    uint256 internal constant DENOMINATOR = 1 ether;

    Gasback public gasback;

    function setUp() public {
        vm.txGasPrice(1);
        gasback = new Gasback();
    }

    function _callFallback(address caller, uint256 gasToBurn)
        internal
        returns (bool success, uint256 ethToGive)
    {
        vm.prank(caller);
        bytes memory data;
        (success, data) = address(gasback).call(abi.encode(gasToBurn));
        if (success) ethToGive = abi.decode(data, (uint256));
    }

    function test_constructorDefaults() public view {
        assertEq(gasback.gasbackRatioNumerator(), 0.6 ether);
        assertEq(gasback.gasbackMaxBaseFee(), type(uint256).max);
        assertEq(gasback.baseFeeVault(), DEFAULT_BASE_FEE_VAULT);
        assertEq(gasback.GASBACK_RATIO_DENOMINATOR(), DENOMINATOR);
    }

    function test_receiveAcceptsEth() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(gasback).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(gasback).balance, 1 ether);
    }

    function test_noopAcceptsEthAndReturnsTrue() public {
        vm.deal(address(this), 1 ether);
        assertTrue(gasback.noop{value: 1 ether}());
        assertEq(address(gasback).balance, 1 ether);
    }

    function test_revert_onlySystemOrThis() public {
        address user = address(0xBEEF);
        vm.startPrank(user);
        vm.expectRevert();
        gasback.setGasbackRatioNumerator(1);
        vm.expectRevert();
        gasback.setGasbackMaxBaseFee(1);
        vm.expectRevert();
        gasback.setBaseFeeVault(address(1));
        vm.expectRevert();
        gasback.withdraw(address(1), 1);
        vm.stopPrank();
    }

    function test_systemCanCallAdminFunctions() public {
        vm.deal(address(gasback), 1 ether);
        vm.startPrank(SYSTEM_ADDRESS);
        assertTrue(gasback.setGasbackRatioNumerator(0.9 ether));
        assertTrue(gasback.setGasbackMaxBaseFee(123));
        assertTrue(gasback.setBaseFeeVault(address(0x1234)));
        assertTrue(gasback.withdraw(address(0xA11CE), 0.2 ether));
        vm.stopPrank();

        assertEq(gasback.gasbackRatioNumerator(), 0.9 ether);
        assertEq(gasback.gasbackMaxBaseFee(), 123);
        assertEq(gasback.baseFeeVault(), address(0x1234));
        assertEq(address(0xA11CE).balance, 0.2 ether);
    }

    function test_selfCanCallAdminFunctions() public {
        vm.deal(address(gasback), 1 ether);
        vm.prank(address(gasback));
        assertTrue(gasback.setGasbackRatioNumerator(1 ether));
        vm.prank(address(gasback));
        assertTrue(gasback.setGasbackMaxBaseFee(77));
        vm.prank(address(gasback));
        assertTrue(gasback.setBaseFeeVault(address(0x4321)));
        vm.prank(address(gasback));
        assertTrue(gasback.withdraw(address(0xB0B), 0.25 ether));

        assertEq(gasback.gasbackRatioNumerator(), 1 ether);
        assertEq(gasback.gasbackMaxBaseFee(), 77);
        assertEq(gasback.baseFeeVault(), address(0x4321));
        assertEq(address(0xB0B).balance, 0.25 ether);
    }

    function test_revert_setGasbackRatioNumeratorAboveDenominator() public {
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert();
        gasback.setGasbackRatioNumerator(DENOMINATOR + 1);
    }

    function test_revert_fallbackWithZeroGasPrice() public {
        vm.txGasPrice(0);
        vm.fee(1);
        vm.prank(address(1));
        vm.expectRevert("Gasback: gasprice is 0");
        address(gasback).call(abi.encode(uint256(1)));
    }

    function test_revert_fallbackInvalidCalldataLength() public {
        vm.prank(address(1));
        (bool success0,) = address(gasback).call(new bytes(1));
        assertFalse(success0);

        vm.prank(address(1));
        (bool success1,) = address(gasback).call(new bytes(31));
        assertFalse(success1);

        vm.prank(address(1));
        (bool success2,) = address(gasback).call(abi.encode(uint256(1), uint256(2)));
        assertFalse(success2);
    }

    function test_fallbackPaysCaller() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethToGive = (baseFee * gasToBurn * gasback.gasbackRatioNumerator()) / DENOMINATOR;
        vm.deal(address(gasback), ethToGive);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(0xB0B).balance, ethToGive);
        assertEq(address(gasback).balance, 0);
    }

    function test_fallbackWithZeroRatioReturnsZero() public {
        vm.prank(SYSTEM_ADDRESS);
        gasback.setGasbackRatioNumerator(0);
        vm.fee(13);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), 101);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
    }

    function test_fallbackZeroGasToBurnNoops() public {
        vm.deal(address(gasback), 1 ether);
        vm.fee(123);
        uint256 beforeBalance = address(gasback).balance;

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), 0);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(gasback).balance, beforeBalance);
    }

    function test_fallbackPassThroughWhenInsufficientBalance() public {
        vm.prank(SYSTEM_ADDRESS);
        gasback.setBaseFeeVault(address(0));
        vm.fee(10);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), 100);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
    }

    function test_fallbackPassThroughWhenBaseFeeAboveMax() public {
        vm.prank(SYSTEM_ADDRESS);
        gasback.setGasbackMaxBaseFee(9);
        vm.deal(address(gasback), 600);
        vm.fee(10);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), 100);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(gasback).balance, 600);
    }

    function test_revert_fallbackOnEthFromGasOverflow() public {
        vm.fee(2);
        vm.prank(address(1));
        (bool success,) = address(gasback).call(abi.encode(type(uint256).max));
        assertFalse(success);
    }

    function test_revert_fallbackWhenCannotBurnRequestedGas() public {
        vm.fee(0);
        vm.prank(address(1));
        (bool success,) = address(gasback).call(abi.encode(type(uint256).max));
        assertFalse(success);
    }

    function test_fallbackPayoutsAreAdditiveAcrossCalls() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethToGive = (baseFee * gasToBurn * gasback.gasbackRatioNumerator()) / DENOMINATOR;
        vm.deal(address(gasback), 2 * ethToGive);
        vm.fee(baseFee);

        (bool success0,) = _callFallback(address(0x1111), gasToBurn);
        (bool success1,) = _callFallback(address(0x2222), gasToBurn);

        assertTrue(success0);
        assertTrue(success1);
        assertEq(address(0x1111).balance, ethToGive);
        assertEq(address(0x2222).balance, ethToGive);
        assertEq(address(gasback).balance, 0);
    }

    function test_fallbackPullsFromBaseFeeVault() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethToGive = (baseFee * gasToBurn * gasback.gasbackRatioNumerator()) / DENOMINATOR;
        ShapeRegressionBaseFeeVault vault =
            new ShapeRegressionBaseFeeVault{value: ethToGive}(address(gasback));
        vm.prank(SYSTEM_ADDRESS);
        gasback.setBaseFeeVault(address(vault));
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(0xB0B).balance, ethToGive);
        assertEq(address(vault).balance, 0);
    }

    function test_fallbackPassesThroughWhenVaultWithdrawReverts() public {
        ShapeRegressionBaseFeeVault vault =
            new ShapeRegressionBaseFeeVault{value: 1 ether}(address(gasback));
        vault.setShouldRevert(true);
        vm.prank(SYSTEM_ADDRESS);
        gasback.setBaseFeeVault(address(vault));
        vm.fee(10);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), 100);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_fallbackForceSendsWhenCallerRejectsEth() public {
        ShapeRegressionRejectingCaller caller = new ShapeRegressionRejectingCaller();
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethToGive = (baseFee * gasToBurn * gasback.gasbackRatioNumerator()) / DENOMINATOR;
        vm.deal(address(gasback), ethToGive);
        vm.fee(baseFee);

        uint256 returnedEthToGive = caller.trigger(address(gasback), gasToBurn);

        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(caller).balance, ethToGive);
    }

    function test_fallbackPaysAcceptingContractCaller() public {
        ShapeRegressionAcceptingCaller caller = new ShapeRegressionAcceptingCaller();
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethToGive = (baseFee * gasToBurn * gasback.gasbackRatioNumerator()) / DENOMINATOR;
        vm.deal(address(gasback), ethToGive);
        vm.fee(baseFee);

        uint256 returnedEthToGive = caller.trigger(address(gasback), gasToBurn);

        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(caller).balance, ethToGive);
    }

    function test_revert_withdrawWhenRecipientRejectsEth() public {
        ShapeRegressionRejectingReceiver rejector = new ShapeRegressionRejectingReceiver();
        vm.deal(address(gasback), 1 ether);
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert();
        gasback.withdraw(address(rejector), 0.1 ether);
        assertEq(address(gasback).balance, 1 ether);
    }

    function test_revert_withdrawWhenAmountExceedsBalance() public {
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert();
        gasback.withdraw(address(1), 1);
    }

    function testFuzz_fallbackPayoutWithSufficientBalance(
        uint256 baseFee,
        uint256 gasToBurn,
        uint256 ratioNumerator
    ) public {
        baseFee = _bound(baseFee, 0, 1e12);
        gasToBurn = _bound(gasToBurn, 0, 20_000);
        ratioNumerator = _bound(ratioNumerator, 0, DENOMINATOR);
        vm.prank(SYSTEM_ADDRESS);
        gasback.setGasbackRatioNumerator(ratioNumerator);

        uint256 expectedEthToGive = (baseFee * gasToBurn * ratioNumerator) / DENOMINATOR;
        vm.deal(address(gasback), expectedEthToGive);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, expectedEthToGive);
        assertEq(address(0xB0B).balance, expectedEthToGive);
    }
}
