// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title GasbackRefunds
/// @notice Abstract helper for contracts that forward RIP-7767 gasback payouts to `msg.sender`.
/// @dev Inheriting contracts choose when to call `_refundGasback` and how much gas to burn.
abstract contract GasbackRefunds {
    /// @notice Emitted after a gasback payout is received and forwarded.
    /// @param sender The caller that received the forwarded refund.
    /// @param gasback The Gasback target that was called.
    /// @param gasToBurn The gas amount requested from the Gasback target.
    /// @param amount The native token amount forwarded to `sender`.
    event GasbackRefunded(
        address indexed sender, address indexed gasback, uint256 gasToBurn, uint256 amount
    );

    /// @notice The Gasback target cannot be the zero address.
    error GasbackIsTheZeroAddress();

    /// @notice The Gasback target call reverted.
    error GasbackCallFailed();

    /// @notice The Gasback target did not return exactly 32 bytes.
    error UnexpectedGasbackReturnData();

    /// @notice The received native token amount did not match the returned refund amount.
    /// @param returnedAmount The amount reported by the Gasback target.
    /// @param receivedAmount The native token amount actually received by this contract.
    error GasbackRefundMismatch(uint256 returnedAmount, uint256 receivedAmount);

    address private immutable GASBACK;

    /// @notice Initializes the contract with a Gasback target.
    /// @param gasback_ The RIP-7767-compatible Gasback target.
    /// @dev The target is not required to have code, preserving precompile compatibility.
    constructor(address gasback_) {
        if (gasback_ == address(0)) revert GasbackIsTheZeroAddress();
        GASBACK = gasback_;
    }

    /// @notice Accepts native token payouts from the Gasback target.
    receive() external payable virtual {}

    /// @notice Returns the configured Gasback target.
    function gasback() public view virtual returns (address) {
        return GASBACK;
    }

    /// @notice Calls the Gasback target and forwards the full received payout to `msg.sender`.
    /// @param gasToBurn The gas amount to request from the Gasback target.
    /// @return refundAmount The native token amount forwarded to `msg.sender`.
    /// @dev Reverts unless the Gasback call succeeds, returns exactly 32 bytes, and transfers the
    /// returned amount to this contract during the call.
    function _refundGasback(uint256 gasToBurn) internal virtual returns (uint256 refundAmount) {
        address gasback_ = GASBACK;
        uint256 balanceBefore = address(this).balance;

        (bool success, bytes memory data) = gasback_.call(abi.encode(gasToBurn));
        if (!success) revert GasbackCallFailed();
        if (data.length != 32) revert UnexpectedGasbackReturnData();

        refundAmount = abi.decode(data, (uint256));
        uint256 balanceAfter = address(this).balance;
        if (balanceAfter < balanceBefore) {
            revert GasbackRefundMismatch(refundAmount, 0);
        }
        uint256 receivedAmount;
        unchecked {
            receivedAmount = balanceAfter - balanceBefore;
        }
        if (receivedAmount != refundAmount) {
            revert GasbackRefundMismatch(refundAmount, receivedAmount);
        }

        if (refundAmount != 0) {
            SafeTransferLib.forceSafeTransferETH(
                msg.sender, refundAmount, SafeTransferLib.GAS_STIPEND_NO_STORAGE_WRITES
            );
        }

        emit GasbackRefunded(msg.sender, gasback_, gasToBurn, refundAmount);
    }
}
