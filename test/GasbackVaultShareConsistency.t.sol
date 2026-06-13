// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {Gasback} from "../src/Gasback.sol";

/// @dev Minimal PaymentSplitter-shaped mock exposing only the getters the consistency check reads.
contract MockSplitterForConsistency {
    uint256 public totalShares;
    uint256 internal _shares;

    constructor(uint256 totalShares_, uint256 shares_) {
        totalShares = totalShares_;
        _shares = shares_;
    }

    function shares(address) external view returns (uint256) {
        return _shares;
    }
}

/// @dev Minimal OP-style fee vault mock exposing `recipient()`.
contract MockVaultForConsistency {
    address public recipient;

    constructor(address recipient_) {
        recipient = recipient_;
    }
}

contract GasbackVaultShareConsistencyTest is SoladyTest {
    address internal constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    Gasback internal gasback;

    function setUp() public {
        gasback = new Gasback();
        vm.deal(address(gasback), 2 ** 160);
    }

    function _pointVaultAt(address recipient) internal {
        address vault = address(new MockVaultForConsistency(recipient));
        vm.prank(SYSTEM);
        gasback.setBaseFeeVault(vault);
    }

    function test_matchesSplitterShare_succeeds() public {
        // 80 / 100 => 0.8 ether expected.
        _pointVaultAt(address(new MockSplitterForConsistency(100, 80)));

        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.8 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.8 ether);
    }

    function test_mismatchSplitterShare_reverts() public {
        // 80 / 100 => expected 0.8 ether; 0.7 ether passes the bound checks but is inconsistent.
        _pointVaultAt(address(new MockSplitterForConsistency(100, 80)));

        vm.prank(SYSTEM);
        vm.expectRevert();
        gasback.setBaseFeeVaultShareNumerator(0.7 ether);
    }

    function test_floorRoundingMatchesFallbackSemantics() public {
        // 2 / 3 => floor(2e18/3) = 666666666666666666 (>= the 0.6 ether ratio bound). The exact
        // floored value must be accepted (mirroring how the fallback computes expectedShare), and
        // off-by-one must revert.
        uint256 expected = (uint256(2) * 1 ether) / 3;
        _pointVaultAt(address(new MockSplitterForConsistency(3, 2)));

        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(expected));

        _pointVaultAt(address(new MockSplitterForConsistency(3, 2)));
        vm.prank(SYSTEM);
        vm.expectRevert();
        gasback.setBaseFeeVaultShareNumerator(expected + 1);
    }

    function test_skipsWhenVaultHasNoCode() public {
        // Default vault (0x42..19) has no code in the test EVM => check is skipped.
        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
    }

    function test_skipsWhenRecipientIsSelf_7702() public {
        // EIP-7702 topology: the vault recipient is this contract, not a splitter.
        _pointVaultAt(address(gasback));

        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
    }

    function test_skipsWhenRecipientNotASplitter() public {
        // Recipient is a codeless address => shares()/totalShares() are unreadable.
        _pointVaultAt(address(0xBEEF));

        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
    }
}
