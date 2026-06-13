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

/// @dev Splitter whose `totalShares()` reverts (drives the `!ok` arm of the line 204 early return).
contract MockSplitterTotalSharesReverts {
    function totalShares() external pure {
        revert();
    }

    function shares(address) external pure returns (uint256) {
        return 80;
    }
}

/// @dev Splitter whose `totalShares()` returns fewer than 32 bytes (drives the `data.length != 32`
/// arm of the line 204 early return).
contract MockSplitterTotalSharesWrongLength {
    function totalShares() external pure {
        assembly {
            return(0x00, 0x04)
        }
    }

    function shares(address) external pure returns (uint256) {
        return 80;
    }
}

/// @dev Splitter with a readable, 32-byte `totalShares()` but whose `shares(address)` reverts
/// (drives the `!ok` arm of the line 209 early return).
contract MockSplitterSharesReverts {
    uint256 public totalShares = 100;

    function shares(address) external pure {
        revert();
    }
}

/// @dev Splitter with a readable `totalShares()` but whose `shares(address)` returns fewer than
/// 32 bytes (drives the `data.length != 32` arm of the line 209 early return).
contract MockSplitterSharesWrongLength {
    uint256 public totalShares = 100;

    function shares(address) external pure {
        assembly {
            return(0x00, 0x04)
        }
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

    // Line 204: `totalShares()` staticcall fails => `!ok` => return (false, 0) => check skipped.
    function test_skipsWhenTotalSharesReverts() public {
        _pointVaultAt(address(new MockSplitterTotalSharesReverts()));

        // 0.9 ether mismatches what shares(80) would imply, yet is accepted because the check is
        // inapplicable (the splitter's totalShares() is unreadable).
        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
    }

    // Line 204: `totalShares()` returns non-32-byte data => `data.length != 32` => check skipped.
    function test_skipsWhenTotalSharesWrongLength() public {
        _pointVaultAt(address(new MockSplitterTotalSharesWrongLength()));

        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
    }

    // Line 206: `totalShares == 0` => return (false, 0) before the division => check skipped.
    // (Were the check applicable, the expected-share computation would divide by zero.)
    function test_skipsWhenTotalSharesZero() public {
        _pointVaultAt(address(new MockSplitterForConsistency(0, 80)));

        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
    }

    // Line 209: `shares(address)` staticcall fails => `!ok` => return (false, 0) => check skipped.
    function test_skipsWhenSharesReverts() public {
        _pointVaultAt(address(new MockSplitterSharesReverts()));

        // totalShares() reads as 100, but shares(this) is unreadable, so no expected share can be
        // derived and 0.9 ether is accepted.
        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
    }

    // Line 209: `shares(address)` returns non-32-byte data => `data.length != 32` => check skipped.
    function test_skipsWhenSharesWrongLength() public {
        _pointVaultAt(address(new MockSplitterSharesWrongLength()));

        vm.prank(SYSTEM);
        assertTrue(gasback.setBaseFeeVaultShareNumerator(0.9 ether));
        assertEq(gasback.baseFeeVaultShareNumerator(), 0.9 ether);
    }
}
