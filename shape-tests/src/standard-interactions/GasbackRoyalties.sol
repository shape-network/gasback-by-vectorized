// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.28;

import {ERC2981} from "solady/tokens/ERC2981.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice ERC-2981-compatible interface for royalties funded by Gasback payouts.
interface IGasbackRoyalties {
    /// @notice Returns the RIP-7767-compatible Gasback target.
    function gasback() external view returns (address);

    /// @notice Returns the creator royalty receiver and amount for a Gasback payout.
    function gasbackRoyaltyInfo(uint256 tokenId, uint256 gasbackAmount)
        external
        view
        returns (address receiver, uint256 royaltyAmount);
}

/// @title GasbackRoyalties
/// @notice Abstract helper for ERC721 and ERC1155 contracts paying ERC-2981 royalties from Gasback.
abstract contract GasbackRoyalties is ERC2981, IGasbackRoyalties {
    /// @notice Emitted after a Gasback payout is split for a single token ID.
    event GasbackRoyaltyPaid(
        address indexed sender,
        address indexed receiver,
        uint256 indexed tokenId,
        address gasback,
        uint256 gasToBurn,
        uint256 gasbackAmount,
        uint256 royaltyAmount,
        uint256 refundAmount
    );

    /// @notice Emitted after a Gasback payout is split across multiple token IDs.
    event GasbackRoyaltiesPaid(
        address indexed sender,
        address indexed gasback,
        uint256 gasToBurn,
        uint256 gasbackAmount,
        uint256 royaltyAmount,
        uint256 refundAmount
    );

    /// @notice The Gasback target cannot be the zero address.
    error GasbackIsTheZeroAddress();

    /// @notice The Gasback target call reverted.
    error GasbackCallFailed();

    /// @notice The Gasback target did not return exactly 32 bytes.
    error UnexpectedGasbackReturnData();

    /// @notice The received native token amount did not match the returned Gasback amount.
    error GasbackPayoutMismatch(uint256 returnedAmount, uint256 receivedAmount);

    /// @notice The royalty amount exceeded its allocated Gasback payout.
    error GasbackRoyaltyExceedsPayout(uint256 royaltyAmount, uint256 gasbackAmount);

    /// @notice A positive royalty amount cannot be paid to the zero address.
    error GasbackRoyaltyReceiverIsZeroAddress();

    /// @notice The ERC1155 batch token ID and amount arrays differ in length.
    error GasbackRoyaltyArrayLengthMismatch();

    /// @notice The ERC1155 batch did not include any nonzero token amounts.
    error GasbackRoyaltyNoTokenAmounts();

    address private immutable GASBACK;

    /// @notice Initializes the helper with a Gasback target.
    constructor(address gasback_) {
        if (gasback_ == address(0)) revert GasbackIsTheZeroAddress();
        GASBACK = gasback_;
    }

    /// @notice Accepts native token payouts from the Gasback target.
    receive() external payable virtual {}

    /// @inheritdoc IGasbackRoyalties
    function gasback() public view virtual returns (address) {
        return GASBACK;
    }

    /// @inheritdoc IGasbackRoyalties
    function gasbackRoyaltyInfo(uint256 tokenId, uint256 gasbackAmount)
        public
        view
        virtual
        returns (address receiver, uint256 royaltyAmount)
    {
        return royaltyInfo(tokenId, gasbackAmount);
    }

    /// @inheritdoc ERC2981
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IGasbackRoyalties).interfaceId
                || super.supportsInterface(interfaceId);
    }

    /// @notice Calls Gasback and pays ERC-2981 royalties for one token ID.
    function _payGasbackRoyalty(uint256 tokenId, uint256 gasToBurn)
        internal
        virtual
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        if (gasToBurn == 0) return (0, 0, 0);

        gasbackAmount = _collectGasback(gasToBurn);
        if (gasbackAmount == 0) {
            emit GasbackRoyaltyPaid(msg.sender, address(0), tokenId, GASBACK, gasToBurn, 0, 0, 0);
            return (0, 0, 0);
        }

        address receiver;
        (receiver, royaltyAmount) = gasbackRoyaltyInfo(tokenId, gasbackAmount);
        _validateGasbackRoyalty(receiver, royaltyAmount, gasbackAmount);

        refundAmount = gasbackAmount - royaltyAmount;
        _settleGasbackRoyalty(receiver, royaltyAmount, refundAmount);

        emit GasbackRoyaltyPaid(
            msg.sender,
            receiver,
            tokenId,
            GASBACK,
            gasToBurn,
            gasbackAmount,
            royaltyAmount,
            refundAmount
        );
    }

    /// @notice Calls Gasback and pays ERC-2981 royalties across an ERC1155 batch.
    function _payGasbackRoyalties(
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        uint256 gasToBurn
    )
        internal
        virtual
        returns (uint256 gasbackAmount, uint256 royaltyAmount, uint256 refundAmount)
    {
        if (gasToBurn == 0) {
            return (0, 0, 0);
        }

        uint256 length = tokenIds.length;
        if (length != amounts.length) revert GasbackRoyaltyArrayLengthMismatch();

        uint256 totalAmount;
        for (uint256 i; i < length; ++i) {
            totalAmount += amounts[i];
        }
        if (totalAmount == 0) revert GasbackRoyaltyNoTokenAmounts();

        gasbackAmount = _collectGasback(gasToBurn);
        if (gasbackAmount == 0) {
            emit GasbackRoyaltiesPaid(msg.sender, GASBACK, gasToBurn, 0, 0, 0);
            return (0, 0, 0);
        }

        uint256 remainingGasback = gasbackAmount;
        uint256 remainingAmount = totalAmount;

        for (uint256 i; i < length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;

            uint256 allocatedGasback = remainingAmount == amount
                ? remainingGasback
                : FixedPointMathLib.fullMulDiv(remainingGasback, amount, remainingAmount);

            unchecked {
                remainingGasback -= allocatedGasback;
                remainingAmount -= amount;
            }

            address receiver;
            uint256 tokenRoyaltyAmount;
            (receiver, tokenRoyaltyAmount) = gasbackRoyaltyInfo(tokenIds[i], allocatedGasback);
            _validateGasbackRoyalty(receiver, tokenRoyaltyAmount, allocatedGasback);

            if (tokenRoyaltyAmount != 0) {
                royaltyAmount += tokenRoyaltyAmount;
                SafeTransferLib.forceSafeTransferETH(receiver, tokenRoyaltyAmount);
            }
        }

        refundAmount = gasbackAmount - royaltyAmount;
        _refundGasbackRemainder(refundAmount);

        emit GasbackRoyaltiesPaid(
            msg.sender, GASBACK, gasToBurn, gasbackAmount, royaltyAmount, refundAmount
        );
    }

    /// @notice Calls the configured Gasback target and validates the received payout.
    function _collectGasback(uint256 gasToBurn) internal virtual returns (uint256 gasbackAmount) {
        if (gasToBurn == 0) return 0;

        uint256 balanceBefore = address(this).balance;
        (bool success, bytes memory data) = GASBACK.call(abi.encode(gasToBurn));
        if (!success) revert GasbackCallFailed();
        if (data.length != 32) revert UnexpectedGasbackReturnData();

        gasbackAmount = abi.decode(data, (uint256));
        uint256 balanceAfter = address(this).balance;
        if (balanceAfter < balanceBefore) {
            revert GasbackPayoutMismatch(gasbackAmount, 0);
        }

        uint256 receivedAmount;
        unchecked {
            receivedAmount = balanceAfter - balanceBefore;
        }
        if (receivedAmount != gasbackAmount) {
            revert GasbackPayoutMismatch(gasbackAmount, receivedAmount);
        }
    }

    function _settleGasbackRoyalty(address receiver, uint256 royaltyAmount, uint256 refundAmount)
        internal
        virtual
    {
        if (royaltyAmount != 0) {
            SafeTransferLib.forceSafeTransferETH(receiver, royaltyAmount);
        }
        _refundGasbackRemainder(refundAmount);
    }

    function _refundGasbackRemainder(uint256 refundAmount) internal virtual {
        if (refundAmount != 0) {
            SafeTransferLib.forceSafeTransferETH(
                msg.sender, refundAmount, SafeTransferLib.GAS_STIPEND_NO_STORAGE_WRITES
            );
        }
    }

    function _validateGasbackRoyalty(
        address receiver,
        uint256 royaltyAmount,
        uint256 gasbackAmount
    ) internal pure virtual {
        if (royaltyAmount > gasbackAmount) {
            revert GasbackRoyaltyExceedsPayout(royaltyAmount, gasbackAmount);
        }
        if (royaltyAmount != 0 && receiver == address(0)) {
            revert GasbackRoyaltyReceiverIsZeroAddress();
        }
    }
}
