// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SoladyTest} from "./utils/SoladyTest.sol";
import {Gasback} from "../src/Gasback.sol";
import {GasbackRefunds} from "../src/standard-interactions/GasbackRefunds.sol";

contract GasbackRefundsHarness is GasbackRefunds {
    constructor(address gasback_) GasbackRefunds(gasback_) {}

    function refund(uint256 gasToBurn) external payable returns (uint256) {
        return _refundGasback(gasToBurn);
    }
}

contract RejectingRefundReceiver {
    function trigger(GasbackRefundsHarness harness, uint256 gasToBurn) external returns (uint256) {
        return harness.refund(gasToBurn);
    }

    receive() external payable {
        revert();
    }
}

contract MockGasbackTarget {
    bool public shouldRevert;
    uint256 public sendAmount;
    uint256 public returnAmount;
    uint256 public returnDataLength;

    constructor(
        bool shouldRevert_,
        uint256 sendAmount_,
        uint256 returnAmount_,
        uint256 returnDataLength_
    ) payable {
        shouldRevert = shouldRevert_;
        sendAmount = sendAmount_;
        returnAmount = returnAmount_;
        returnDataLength = returnDataLength_;
    }

    fallback() external payable {
        if (shouldRevert) revert();
        if (sendAmount != 0) {
            (bool success,) = msg.sender.call{value: sendAmount}("");
            require(success);
        }
        uint256 value = returnAmount;
        uint256 length = returnDataLength;
        assembly {
            mstore(0x00, value)
            return(0x00, length)
        }
    }

    receive() external payable {}
}

contract GasbackRefundsTest is SoladyTest {
    event GasbackRefunded(
        address indexed sender, address indexed gasback, uint256 gasToBurn, uint256 amount
    );

    uint256 internal constant DENOMINATOR = 1 ether;

    Gasback public gasbackTarget;
    GasbackRefundsHarness public harness;

    function setUp() public {
        gasbackTarget = new Gasback();
        harness = new GasbackRefundsHarness(address(gasbackTarget));
    }

    function test_constructorRejectsZeroGasbackAddress() public {
        vm.expectRevert(GasbackRefunds.GasbackIsTheZeroAddress.selector);
        new GasbackRefundsHarness(address(0));
    }

    function test_constructorAcceptsAddressWithoutCode() public {
        address target = address(0xBEEF);
        GasbackRefundsHarness localHarness = new GasbackRefundsHarness(target);
        assertEq(localHarness.gasback(), target);
    }

    function test_refundSendsFullGasbackPayoutToSenderAndLeavesHarnessEmpty() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 expectedRefund =
            (baseFee * gasToBurn * gasbackTarget.gasbackRatioNumerator()) / DENOMINATOR;
        address user = address(0xA11CE);

        vm.deal(address(gasbackTarget), expectedRefund);
        vm.fee(baseFee);

        vm.expectEmit(true, true, true, true, address(harness));
        emit GasbackRefunded(user, address(gasbackTarget), gasToBurn, expectedRefund);

        vm.prank(user);
        uint256 refundAmount = harness.refund(gasToBurn);

        assertEq(refundAmount, expectedRefund);
        assertEq(user.balance, expectedRefund);
        assertEq(address(harness).balance, 0);
    }

    function test_refundZeroPayoutReturnsZeroAndSendsNothing() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        address user = address(0xB0B);

        vm.fee(baseFee);

        vm.expectEmit(true, true, true, true, address(harness));
        emit GasbackRefunded(user, address(gasbackTarget), gasToBurn, 0);

        vm.prank(user);
        uint256 refundAmount = harness.refund(gasToBurn);

        assertEq(refundAmount, 0);
        assertEq(user.balance, 0);
        assertEq(address(harness).balance, 0);
    }

    function test_refundForceSendsToRejectingReceiver() public {
        uint256 baseFee = 10;
        uint256 gasToBurn = 100;
        uint256 expectedRefund =
            (baseFee * gasToBurn * gasbackTarget.gasbackRatioNumerator()) / DENOMINATOR;
        RejectingRefundReceiver receiver = new RejectingRefundReceiver();

        vm.deal(address(gasbackTarget), expectedRefund);
        vm.fee(baseFee);

        uint256 refundAmount = receiver.trigger(harness, gasToBurn);

        assertEq(refundAmount, expectedRefund);
        assertEq(address(receiver).balance, expectedRefund);
        assertEq(address(harness).balance, 0);
    }

    function test_revert_refundWhenGasbackCallReverts() public {
        MockGasbackTarget target = new MockGasbackTarget(true, 0, 0, 0);
        GasbackRefundsHarness localHarness = new GasbackRefundsHarness(address(target));

        vm.expectRevert(GasbackRefunds.GasbackCallFailed.selector);
        localHarness.refund(1);
    }

    function test_revert_refundWhenGasbackReturnsEmptyData() public {
        MockGasbackTarget target = new MockGasbackTarget(false, 0, 0, 0);
        GasbackRefundsHarness localHarness = new GasbackRefundsHarness(address(target));

        vm.expectRevert(GasbackRefunds.UnexpectedGasbackReturnData.selector);
        localHarness.refund(1);
    }

    function test_revert_refundWhenGasbackReturnsMalformedData() public {
        MockGasbackTarget target = new MockGasbackTarget(false, 0, 0, 31);
        GasbackRefundsHarness localHarness = new GasbackRefundsHarness(address(target));

        vm.expectRevert(GasbackRefunds.UnexpectedGasbackReturnData.selector);
        localHarness.refund(1);
    }

    function test_revert_refundWhenGasbackReturnsPayoutWithoutSendingEth() public {
        MockGasbackTarget target = new MockGasbackTarget(false, 0, 1 ether, 32);
        GasbackRefundsHarness localHarness = new GasbackRefundsHarness(address(target));
        address user = address(0xCAFE);

        vm.deal(address(localHarness), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(GasbackRefunds.GasbackRefundMismatch.selector, 1 ether, 0)
        );
        vm.prank(user);
        localHarness.refund(1);

        assertEq(address(localHarness).balance, 1 ether);
        assertEq(user.balance, 0);
    }

    function test_revert_refundWhenReturnedAmountDoesNotMatchReceivedDelta() public {
        MockGasbackTarget target = new MockGasbackTarget(false, 1 ether, 2 ether, 32);
        GasbackRefundsHarness localHarness = new GasbackRefundsHarness(address(target));
        address user = address(0xD00D);

        vm.deal(address(target), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(GasbackRefunds.GasbackRefundMismatch.selector, 2 ether, 1 ether)
        );
        vm.prank(user);
        localHarness.refund(1);

        assertEq(address(localHarness).balance, 0);
        assertEq(address(target).balance, 1 ether);
        assertEq(user.balance, 0);
    }
}
