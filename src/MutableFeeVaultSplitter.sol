// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Splits ETH among fixed payees with owner-controlled shares.
/// @dev Adapts FeeVaultSplitter's push payments and OpenZeppelin PaymentSplitter's cumulative
/// accounting. Share changes checkpoint earned ETH; only future receipts and rounding dust use
/// the new shares. This custom accounting is not covered by OpenZeppelin's audits.
/// Automatic payouts use a bounded gas stipend. Failed transfers remain claimable through
/// release, which forwards available gas, or bounded distribute calls. Keep the payee set small.
contract MutableFeeVaultSplitter is Ownable2Step, ReentrancyGuard {
    error InvalidOwner();
    error InvalidPayee();
    error InvalidShares();
    error NoPaymentDue();
    error PaymentTransferFailed();

    event PayeeAdded(address account, uint256 shares);
    event PaymentReceived(address from, uint256 amount);
    event PaymentReleased(address to, uint256 amount);
    event PaymentFailed(address to, uint256 amount);
    event SharesUpdated(uint256[] shares);

    uint256 public constant AUTO_RELEASE_GAS_LIMIT = 100_000;

    address[] public externalPayees;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public released;
    uint256 public totalShares;
    uint256 public totalReleased;

    mapping(address => bool) private _isPayee;
    mapping(address => uint256) private _accrued;
    uint256 private _checkpointReceived;

    constructor(address owner_, address[] memory payees_, uint256[] memory shares_) payable {
        if (owner_ == address(0)) revert InvalidOwner();
        if (payees_.length == 0) revert InvalidPayee();
        totalShares = _validateShares(shares_, payees_.length);
        _transferOwnership(owner_);

        for (uint256 i; i < payees_.length; ++i) {
            address account = payees_[i];
            if (account == address(0) || account == address(this) || _isPayee[account]) {
                revert InvalidPayee();
            }
            _isPayee[account] = true;
            externalPayees.push(account);
            shares[account] = shares_[i];
            emit PayeeAdded(account, shares_[i]);
        }
    }

    receive() external payable nonReentrant {
        emit PaymentReceived(_msgSender(), msg.value);
        _distribute(0, externalPayees.length);
    }

    function payee(uint256 index) public view returns (address) {
        return externalPayees[index];
    }

    function releasable(address account) public view returns (uint256) {
        uint256 received = address(this).balance + totalReleased - _checkpointReceived;
        return _accrued[account] + Math.mulDiv(received, shares[account], totalShares)
            - released[account];
    }

    /// @notice Updates relative weights in the original payee order. Zero weights are allowed,
    /// but their sum must be positive. Existing claims are preserved without calling payees.
    function setShares(uint256[] calldata shares_) external onlyOwner nonReentrant {
        uint256 newTotalShares = _validateShares(shares_, externalPayees.length);
        uint256 received = address(this).balance + totalReleased - _checkpointReceived;
        uint256 allocated;
        for (uint256 i; i < externalPayees.length; ++i) {
            address account = externalPayees[i];
            uint256 earned = Math.mulDiv(received, shares[account], totalShares);
            _accrued[account] += earned;
            allocated += earned;
            shares[account] = shares_[i];
        }
        // Unallocated rounding dust rolls into the next interval instead of becoming stranded.
        _checkpointReceived += allocated;
        totalShares = newTotalShares;
        emit SharesUpdated(shares_);
    }

    function release(address payable account) public nonReentrant {
        if (!_isPayee[account]) revert InvalidPayee();
        uint256 payment = releasable(account);
        if (payment == 0) revert NoPaymentDue();
        if (!_release(account, payment, gasleft())) revert PaymentTransferFailed();
    }

    function distribute(uint256 start, uint256 end) public nonReentrant {
        _distribute(start, end);
    }

    function _distribute(uint256 start, uint256 end) private {
        if (end > externalPayees.length) end = externalPayees.length;
        for (uint256 i = start; i < end; ++i) {
            address payable account = payable(externalPayees[i]);
            uint256 payment = releasable(account);
            if (payment != 0) _release(account, payment, AUTO_RELEASE_GAS_LIMIT);
        }
    }

    function _release(address payable account, uint256 payment, uint256 gasLimit)
        private
        returns (bool)
    {
        released[account] += payment;
        totalReleased += payment;
        bool success = SafeTransferLib.trySafeTransferETH(account, payment, gasLimit);
        if (success) {
            emit PaymentReleased(account, payment);
        } else {
            released[account] -= payment;
            totalReleased -= payment;
            emit PaymentFailed(account, payment);
        }
        return success;
    }

    function _validateShares(uint256[] memory shares_, uint256 payeesLength)
        private
        pure
        returns (uint256 sum)
    {
        if (shares_.length != payeesLength) revert InvalidShares();
        for (uint256 i; i < shares_.length; ++i) {
            sum += shares_[i];
        }
        if (sum == 0) revert InvalidShares();
    }
}
