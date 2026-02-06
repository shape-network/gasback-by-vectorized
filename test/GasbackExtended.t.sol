// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {Gasback} from "../src/Gasback.sol";

contract RejectingReceiver {
    receive() external payable {
        revert();
    }
}

contract RejectingCaller {
    function trigger(address target, uint256 gasToBurn) external returns (uint256 ethToGive) {
        (bool success, bytes memory data) = target.call(abi.encode(gasToBurn));
        require(success);
        ethToGive = abi.decode(data, (uint256));
    }

    receive() external payable {
        revert();
    }
}

contract AcceptingCaller {
    function trigger(address target, uint256 gasToBurn) external returns (uint256 ethToGive) {
        (bool success, bytes memory data) = target.call(abi.encode(gasToBurn));
        require(success);
        ethToGive = abi.decode(data, (uint256));
    }

    receive() external payable {}
}

contract GasbackExtendedTest is SoladyTest {
    address internal constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    address internal constant DEFAULT_BASE_FEE_VAULT = 0x4200000000000000000000000000000000000019;
    uint256 internal constant DENOMINATOR = 1 ether;

    Gasback public gasback;

    function setUp() public {
        gasback = new Gasback();
    }

    function _callFallback(address caller, uint256 gasToBurn)
        internal
        returns (bool success, uint256 ethToGive)
    {
        vm.prank(caller);
        bytes memory data;
        (success, data) = address(gasback).call(abi.encode(gasToBurn));
        if (success) {
            ethToGive = abi.decode(data, (uint256));
        }
    }

    function _accrueViaPassThrough(uint256 baseFee, uint256 gasToBurn)
        internal
        returns (uint256 ethFromGas)
    {
        ethFromGas = baseFee * gasToBurn;
        vm.fee(baseFee);
        (bool success,) = _callFallback(address(0xA11CE), gasToBurn);
        assertTrue(success);
        assertEq(gasback.accrued(), ethFromGas);
    }

    function _configureBaseFeeVault(address vault, uint256 shareNumerator) internal {
        vm.startPrank(SYSTEM_ADDRESS);
        gasback.setBaseFeeVault(vault);
        gasback.setBaseFeeVaultShareNumerator(shareNumerator);
        vm.stopPrank();
    }

    function test_constructorDefaults() public {
        assertEq(gasback.gasbackRatioNumerator(), 0.6 ether);
        assertEq(gasback.gasbackMaxBaseFee(), type(uint256).max);
        assertEq(gasback.baseFeeVault(), DEFAULT_BASE_FEE_VAULT);
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.6 ether);
        assertEq(gasback.accrued(), 0);
        assertEq(gasback.GASBACK_RATIO_DENOMINATOR(), DENOMINATOR);
        assertFalse(gasback.isAuthorizedAccuralWithdrawer(address(this)));
    }

    function test_receiveAcceptsEth() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(gasback).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(gasback).balance, 1 ether);
    }

    function test_noopAcceptsEthAndReturnsTrue() public {
        vm.deal(address(this), 1 ether);
        bool success = gasback.noop{value: 1 ether}();
        assertTrue(success);
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
        gasback.setBaseFeeVaultShareNumerator(1);
        vm.expectRevert();
        gasback.setAccuralWithdrawer(address(1), true);
        vm.expectRevert();
        gasback.withdraw(address(1), 1);
        vm.stopPrank();
    }

    function test_systemCanCallAdminFunctions() public {
        vm.deal(address(gasback), 1 ether);

        vm.startPrank(SYSTEM_ADDRESS);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertTrue(gasback.setGasbackRatioNumerator(0.9 ether));
        assertTrue(gasback.setGasbackMaxBaseFee(123));
        assertTrue(gasback.setBaseFeeVault(address(0x1234)));
        assertTrue(gasback.setAccuralWithdrawer(address(0x99), true));
        assertTrue(gasback.withdraw(address(0xA11CE), 0.2 ether));
        vm.stopPrank();

        assertEq(gasback.gasbackRatioNumerator(), 0.9 ether);
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
        assertEq(gasback.gasbackMaxBaseFee(), 123);
        assertEq(gasback.baseFeeVault(), address(0x1234));
        assertTrue(gasback.isAuthorizedAccuralWithdrawer(address(0x99)));
        assertEq(address(0xA11CE).balance, 0.2 ether);
    }

    function test_selfCanCallAdminFunctions() public {
        vm.deal(address(gasback), 1 ether);

        vm.prank(address(gasback));
        assertTrue(gasback.setBaseFeeVaultShareNumerator(1 ether));
        vm.prank(address(gasback));
        assertTrue(gasback.setGasbackRatioNumerator(1 ether));
        vm.prank(address(gasback));
        assertTrue(gasback.setGasbackMaxBaseFee(77));
        vm.prank(address(gasback));
        assertTrue(gasback.setBaseFeeVault(address(0x4321)));
        vm.prank(address(gasback));
        assertTrue(gasback.setAccuralWithdrawer(address(this), true));
        vm.prank(address(gasback));
        assertTrue(gasback.withdraw(address(0xB0B), 0.25 ether));

        assertEq(gasback.gasbackRatioNumerator(), 1 ether);
        assertEq(gasback.baseFeeVaultShareNumerator(), 1 ether);
        assertEq(gasback.gasbackMaxBaseFee(), 77);
        assertEq(gasback.baseFeeVault(), address(0x4321));
        assertTrue(gasback.isAuthorizedAccuralWithdrawer(address(this)));
        assertEq(address(0xB0B).balance, 0.25 ether);
    }

    function test_revert_setGasbackRatioNumeratorAboveDenominator() public {
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert();
        gasback.setGasbackRatioNumerator(DENOMINATOR + 1);
    }

    function test_revert_setBaseFeeVaultShareNumeratorAboveDenominator() public {
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert();
        gasback.setBaseFeeVaultShareNumerator(DENOMINATOR + 1);
    }

    function test_revert_setGasbackRatioNumeratorAboveBaseFeeVaultShare() public {
        uint256 shareNumerator = gasback.baseFeeVaultShareNumerator();
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert();
        gasback.setGasbackRatioNumerator(shareNumerator + 1);
    }

    function test_revert_setBaseFeeVaultShareNumeratorBelowGasbackRatio() public {
        vm.prank(SYSTEM_ADDRESS);
        vm.expectRevert();
        gasback.setBaseFeeVaultShareNumerator(0.5 ether);
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

    function test_fallbackPaysCallerAndAccruesCut() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 ethToGive = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;

        vm.deal(address(gasback), ethToGive);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(0xB0B).balance, ethToGive);
        assertEq(gasback.accrued(), ethFromGas - ethToGive);
        assertEq(address(gasback).balance, 0);
    }

    function test_fallbackWithZeroRatioAccruesAll() public {
        vm.prank(SYSTEM_ADDRESS);
        gasback.setGasbackRatioNumerator(0);

        uint256 baseFee = 13;
        uint256 gasToBurn = 101;
        uint256 ethFromGas = baseFee * gasToBurn;

        vm.fee(baseFee);
        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
        assertEq(gasback.accrued(), ethFromGas);
    }

    function test_fallbackZeroGasToBurnNoops() public {
        vm.deal(address(gasback), 1 ether);
        vm.fee(123);

        uint256 beforeBalance = address(gasback).balance;
        uint256 beforeAccrued = gasback.accrued();

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), 0);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
        assertEq(address(gasback).balance, beforeBalance);
        assertEq(gasback.accrued(), beforeAccrued);
    }

    function test_fallbackPassThroughWhenInsufficientBalance() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 ethToGive = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;

        vm.deal(address(gasback), ethToGive - 1);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
        assertEq(gasback.accrued(), ethFromGas);
        assertEq(address(gasback).balance, ethToGive - 1);
    }

    function test_fallbackPassThroughWhenBaseFeeAboveMax() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 ethToGive = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;

        vm.prank(SYSTEM_ADDRESS);
        gasback.setGasbackMaxBaseFee(baseFee - 1);

        vm.deal(address(gasback), ethToGive);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
        assertEq(gasback.accrued(), ethFromGas);
        assertEq(address(gasback).balance, ethToGive);
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

    function test_fallbackAccruedIsAdditiveAcrossCalls() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 ethToGive = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;

        vm.deal(address(gasback), 2 * ethToGive);
        vm.fee(baseFee);

        (bool success0,) = _callFallback(address(0x1111), gasToBurn);
        (bool success1,) = _callFallback(address(0x2222), gasToBurn);

        assertTrue(success0);
        assertTrue(success1);
        assertEq(address(0x1111).balance, ethToGive);
        assertEq(address(0x2222).balance, ethToGive);
        assertEq(gasback.accrued(), 2 * (ethFromGas - ethToGive));
        assertEq(address(gasback).balance, 0);
    }

    function test_fallbackPullsFromBaseFeeVaultWhenShareCoversShortfall() public {
        address vault = address(0xA001);
        vm.etch(vault, hex"33ff00");
        _configureBaseFeeVault(vault, DENOMINATOR);

        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 ethToGive = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;

        vm.deal(vault, ethToGive);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(0xB0B).balance, ethToGive);
        assertEq(gasback.accrued(), ethFromGas - ethToGive);
        assertEq(vault.balance, 0);
    }

    function test_fallbackPullsFromVaultWhenExpectedShareEqualsShortfall() public {
        address vault = address(0xA005);
        vm.etch(vault, hex"33ff00");
        _configureBaseFeeVault(vault, DENOMINATOR);

        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 ethToGive = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;

        vm.deal(vault, ethToGive);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(0xB0B).balance, ethToGive);
        assertEq(vault.balance, 0);
    }

    function test_fallbackDoesNotPullFromVaultWhenExpectedShareBelowShortfall() public {
        address vault = address(0xA002);
        vm.etch(vault, hex"60016000550000");
        _configureBaseFeeVault(vault, DENOMINATOR);

        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;

        vm.deal(vault, 500);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
        assertEq(gasback.accrued(), ethFromGas);
        assertEq(uint256(vm.load(vault, bytes32(0))), 0);
        assertEq(vault.balance, 500);
    }

    function test_fallbackAttemptedVaultPullWithoutTransferFallsBackToPassThrough() public {
        address vault = address(0xA003);
        vm.etch(vault, hex"60016000550000");
        _configureBaseFeeVault(vault, DENOMINATOR);

        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;

        vm.deal(vault, 1000);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
        assertEq(gasback.accrued(), ethFromGas);
        assertEq(uint256(vm.load(vault, bytes32(0))), 1);
        assertEq(vault.balance, 1000);
    }

    function test_fallbackHighBaseFeeSkipsVaultPull() public {
        address vault = address(0xA004);
        vm.etch(vault, hex"60016000550000");

        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;

        vm.startPrank(SYSTEM_ADDRESS);
        gasback.setBaseFeeVault(vault);
        gasback.setBaseFeeVaultShareNumerator(DENOMINATOR);
        gasback.setGasbackMaxBaseFee(baseFee - 1);
        vm.stopPrank();

        vm.deal(vault, 1000);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(gasback.accrued(), ethFromGas);
        assertEq(uint256(vm.load(vault, bytes32(0))), 0);
    }

    function test_fallbackForceSendsWhenCallerRejectsEth() public {
        RejectingCaller caller = new RejectingCaller();

        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 ethToGive = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;

        vm.deal(address(gasback), ethToGive);
        vm.fee(baseFee);

        uint256 returnedEthToGive = caller.trigger(address(gasback), gasToBurn);

        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(caller).balance, ethToGive);
        assertEq(gasback.accrued(), ethFromGas - ethToGive);
    }

    function test_fallbackPaysAcceptingContractCaller() public {
        AcceptingCaller caller = new AcceptingCaller();

        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 ethToGive = (ethFromGas * gasback.gasbackRatioNumerator()) / DENOMINATOR;

        vm.deal(address(gasback), ethToGive);
        vm.fee(baseFee);

        uint256 returnedEthToGive = caller.trigger(address(gasback), gasToBurn);

        assertEq(returnedEthToGive, ethToGive);
        assertEq(address(caller).balance, ethToGive);
        assertEq(gasback.accrued(), ethFromGas - ethToGive);
        assertEq(address(gasback).balance, 0);
    }

    function test_fallbackSkipsEthSendWhenCallerRejectsAndEthToGiveIsZero() public {
        RejectingCaller caller = new RejectingCaller();
        vm.prank(SYSTEM_ADDRESS);
        gasback.setGasbackRatioNumerator(0);

        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 ethFromGas = baseFee * gasToBurn;

        vm.fee(baseFee);
        uint256 returnedEthToGive = caller.trigger(address(gasback), gasToBurn);

        assertEq(returnedEthToGive, 0);
        assertEq(address(caller).balance, 0);
        assertEq(gasback.accrued(), ethFromGas);
    }

    function test_revert_withdrawWhenRecipientRejectsEth() public {
        RejectingReceiver rejector = new RejectingReceiver();
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

    function test_withdrawAccruedAuthorizedSuccess() public {
        uint256 accruedAmount = _accrueViaPassThrough(10, 100);
        vm.deal(address(gasback), accruedAmount);

        vm.prank(SYSTEM_ADDRESS);
        gasback.setAccuralWithdrawer(address(this), true);

        address recipient = address(0xCAFE);
        uint256 before = recipient.balance;
        bool success = gasback.withdrawAccrued(recipient, 400);

        assertTrue(success);
        assertEq(recipient.balance - before, 400);
        assertEq(gasback.accrued(), accruedAmount - 400);
    }

    function test_revert_withdrawAccruedUnauthorized() public {
        _accrueViaPassThrough(10, 100);
        vm.expectRevert();
        gasback.withdrawAccrued(address(this), 1);
    }

    function test_withdrawAccruedRequireBranchTrue_authorized() public {
        uint256 accruedAmount = _accrueViaPassThrough(10, 100);
        vm.deal(address(gasback), accruedAmount);

        vm.prank(SYSTEM_ADDRESS);
        gasback.setAccuralWithdrawer(address(this), true);

        address recipient = address(0xD00D);
        uint256 beforeBalance = recipient.balance;
        bool success = gasback.withdrawAccrued(recipient, 1);

        assertTrue(success);
        assertEq(recipient.balance, beforeBalance + 1);
        assertEq(gasback.accrued(), accruedAmount - 1);
    }

    function test_withdrawAccruedRequireBranchFalse_unauthorizedReverts() public {
        uint256 accruedAmount = _accrueViaPassThrough(10, 100);
        vm.deal(address(gasback), accruedAmount);

        vm.expectRevert();
        gasback.withdrawAccrued(address(0xD00D), 1);

        assertEq(gasback.accrued(), accruedAmount);
    }

    function test_setAccuralWithdrawerRevokeBlocksWithdrawAccrued() public {
        _accrueViaPassThrough(10, 100);

        vm.startPrank(SYSTEM_ADDRESS);
        gasback.setAccuralWithdrawer(address(this), true);
        gasback.setAccuralWithdrawer(address(this), false);
        vm.stopPrank();

        assertFalse(gasback.isAuthorizedAccuralWithdrawer(address(this)));

        vm.expectRevert();
        gasback.withdrawAccrued(address(this), 1);
    }

    function test_revert_withdrawAccruedUnderflow() public {
        uint256 accruedAmount = _accrueViaPassThrough(10, 100);

        vm.prank(SYSTEM_ADDRESS);
        gasback.setAccuralWithdrawer(address(this), true);

        vm.expectRevert();
        gasback.withdrawAccrued(address(this), accruedAmount + 1);

        assertEq(gasback.accrued(), accruedAmount);
    }

    function test_revert_withdrawAccruedWhenRecipientRejectsEth() public {
        RejectingReceiver rejector = new RejectingReceiver();
        uint256 accruedAmount = _accrueViaPassThrough(10, 100);
        vm.deal(address(gasback), accruedAmount);

        vm.prank(SYSTEM_ADDRESS);
        gasback.setAccuralWithdrawer(address(this), true);

        vm.expectRevert();
        gasback.withdrawAccrued(address(rejector), 1);

        assertEq(gasback.accrued(), accruedAmount);
    }

    function test_revert_withdrawAccruedWhenBalanceInsufficient() public {
        uint256 accruedAmount = _accrueViaPassThrough(10, 100);

        vm.prank(SYSTEM_ADDRESS);
        gasback.setAccuralWithdrawer(address(this), true);

        vm.expectRevert();
        gasback.withdrawAccrued(address(0xCAFE), 1);

        assertEq(gasback.accrued(), accruedAmount);
    }

    function testFuzz_fallbackPayoutAndAccrualWithSufficientBalance(
        uint256 baseFee,
        uint256 gasToBurn,
        uint256 ratioNumerator
    ) public {
        baseFee = _bound(baseFee, 0, 1e12);
        gasToBurn = _bound(gasToBurn, 0, 20000);
        ratioNumerator = _bound(ratioNumerator, 0, DENOMINATOR);

        vm.startPrank(SYSTEM_ADDRESS);
        gasback.setBaseFeeVaultShareNumerator(DENOMINATOR);
        gasback.setGasbackRatioNumerator(ratioNumerator);
        vm.stopPrank();

        uint256 ethFromGas = baseFee * gasToBurn;
        uint256 expectedEthToGive = (ethFromGas * ratioNumerator) / DENOMINATOR;

        vm.deal(address(gasback), expectedEthToGive);
        vm.fee(baseFee);

        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, expectedEthToGive);
        assertEq(address(0xB0B).balance, expectedEthToGive);
        assertEq(gasback.accrued(), ethFromGas - expectedEthToGive);
    }

    function testFuzz_fallbackPassThroughOnInsufficientBalance(uint256 baseFee, uint256 gasToBurn)
        public
    {
        baseFee = _bound(baseFee, 1, 1e12);
        gasToBurn = _bound(gasToBurn, 1, 20000);

        uint256 ethFromGas = baseFee * gasToBurn;

        vm.fee(baseFee);
        (bool success, uint256 returnedEthToGive) = _callFallback(address(0xB0B), gasToBurn);

        assertTrue(success);
        assertEq(returnedEthToGive, 0);
        assertEq(address(0xB0B).balance, 0);
        assertEq(gasback.accrued(), ethFromGas);
    }

    function testRevertSetBaseFeeVaultShareNumeratorAboveDenominator() public {
        address system = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
        vm.prank(system);
        vm.expectRevert();
        gasback.setBaseFeeVaultShareNumerator(1 ether + 1);
    }
}
