// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MutableFeeVaultSplitter} from "../src/MutableFeeVaultSplitter.sol";

contract SplitterInvariantPayee {
    bool public rejecting;

    function setRejecting(bool value) external {
        rejecting = value;
    }

    receive() external payable {
        require(!rejecting, "Reject");
    }
}

contract SplitterForceETH {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract MutableSplitterHandler is Test {
    struct Interval {
        uint256 income;
        uint256[3] weights;
    }

    MutableFeeVaultSplitter public splitter;
    SplitterInvariantPayee[3] public recipients;
    uint256 public received;
    uint256 public successfulActions;
    Interval[] private _history;

    constructor() {
        address[] memory payees = new address[](3);
        uint256[] memory shares = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            recipients[i] = new SplitterInvariantPayee();
            payees[i] = address(recipients[i]);
            shares[i] = i + 1;
        }
        splitter = new MutableFeeVaultSplitter(address(this), payees, shares);
        _history.push(Interval(0, [uint256(1), 2, 3]));
    }

    function deposit(uint96 rawAmount) external {
        uint256 amount = uint256(rawAmount) % 1e24;
        received += amount;
        _history[_history.length - 1].income += amount;
        vm.deal(address(this), amount);
        (bool success,) = address(splitter).call{value: amount}("");
        assertTrue(success);
        ++successfulActions;
    }

    function forceDeposit(uint96 rawAmount) external {
        uint256 amount = uint256(rawAmount) % 1e24;
        received += amount;
        _history[_history.length - 1].income += amount;
        vm.deal(address(this), amount);
        new SplitterForceETH{value: amount}(payable(address(splitter)));
        ++successfulActions;
    }

    function update(uint64 a, uint64 b, uint64 c) external {
        uint256[] memory weights = new uint256[](3);
        weights[0] = a;
        weights[1] = b;
        weights[2] = c;
        if (uint256(a) + b + c == 0) weights[0] = 1;
        uint256[3] memory beforeClaims;
        for (uint256 i; i < 3; ++i) {
            beforeClaims[i] = splitter.releasable(address(recipients[i]));
        }
        vm.prank(splitter.owner());
        splitter.setShares(weights);
        Interval storage previous = _history[_history.length - 1];
        uint256 total = previous.weights[0] + previous.weights[1] + previous.weights[2];
        uint256 allocated;
        for (uint256 i; i < 3; ++i) {
            allocated += previous.income * previous.weights[i] / total;
            assertGe(splitter.releasable(address(recipients[i])), beforeClaims[i]);
        }
        _history.push(Interval(previous.income - allocated, [weights[0], weights[1], weights[2]]));
        ++successfulActions;
    }

    function release(uint8 index) external {
        SplitterInvariantPayee recipient = recipients[index % 3];
        bool expected = !recipient.rejecting() && splitter.releasable(address(recipient)) > 0;
        (bool success,) =
            address(splitter).call(abi.encodeCall(splitter.release, (payable(address(recipient)))));
        assertEq(success, expected);
        ++successfulActions;
    }

    function distribute(uint8 start, uint8 end) external {
        splitter.distribute(start % 5, end % 5);
        ++successfulActions;
    }

    function setRejecting(uint8 index, bool value) external {
        recipients[index % 3].setRejecting(value);
        ++successfulActions;
    }

    function transferOwnership(bool useExternalOwner) external {
        address nextOwner = address(this);
        if (useExternalOwner) nextOwner = address(0xA11CE);
        vm.prank(splitter.owner());
        splitter.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), nextOwner);
        ++successfulActions;
    }

    function unauthorizedUpdate(uint64 a) external {
        uint256[] memory weights = new uint256[](3);
        weights[0] = uint256(a) + 1;
        vm.prank(address(0xBAD));
        (bool success,) = address(splitter).call(abi.encodeCall(splitter.setShares, (weights)));
        assertFalse(success);
        ++successfulActions;
    }

    function expectedEarned(uint256 recipient) external view returns (uint256 earned) {
        for (uint256 i; i < _history.length; ++i) {
            Interval storage interval = _history[i];
            uint256 total = interval.weights[0] + interval.weights[1] + interval.weights[2];
            earned += interval.income * interval.weights[recipient] / total;
        }
    }
}

contract MutableFeeVaultSplitterInvariantTest is Test {
    MutableSplitterHandler private handler;
    MutableFeeVaultSplitter private splitter;

    function setUp() public {
        handler = new MutableSplitterHandler();
        splitter = handler.splitter();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.forceDeposit.selector;
        selectors[2] = handler.update.selector;
        selectors[3] = handler.release.selector;
        selectors[4] = handler.distribute.selector;
        selectors[5] = handler.setRejecting.selector;
        selectors[6] = handler.transferOwnership.selector;
        selectors[7] = handler.unauthorizedUpdate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_conservationAndClaimsMatchHistoricalIntervals() public view {
        uint256 paid;
        uint256 due;
        for (uint256 i; i < 3; ++i) {
            address recipient = address(handler.recipients(i));
            uint256 released = splitter.released(recipient);
            uint256 claim = splitter.releasable(recipient);
            assertEq(released, recipient.balance);
            assertEq(released + claim, handler.expectedEarned(i));
            assertEq(splitter.payee(i), recipient);
            paid += released;
            due += claim;
        }
        assertEq(paid, splitter.totalReleased());
        assertEq(paid + address(splitter).balance, handler.received());
        assertLe(due, address(splitter).balance);
        assertLt(address(splitter).balance - due, 3);
        assertGt(splitter.totalShares(), 0);
    }
}
