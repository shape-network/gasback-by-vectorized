// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PaymentSplitter} from "@openzeppelin-contracts/finance/PaymentSplitter.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/security/ReentrancyGuard.sol";

/**
 * @title GasbackSplitter
 * @dev This contract, forked from OpenZeppelin's PaymentSplitter, allows for splitting Ether payments among a group of accounts.
 * It has been modified by Shape to remove ERC20 interactions, focusing solely on Ether distribution.
 *
 * The split can be in equal parts or in any other arbitrary proportion, specified by assigning shares to each account.
 * Each account can claim an amount proportional to their percentage of total shares. The share distribution is set at
 * contract deployment and cannot be updated thereafter.
 *
 * GasbackSplitter follows a _push payment_ model. Incoming Ether triggers an attempt to release funds to all payees.
 *
 * The sender of Ether to this contract does not need to be aware of the split mechanism, as it is handled transparently.
 */
contract GasbackSplitter is PaymentSplitter, ReentrancyGuard {
    event PaymentFailed(address to, uint256 amount, bytes reason);

    address[] public externalPayees;

    /**
     * @dev Creates an instance of `GasbackSplitter` where each account in `payees` is assigned the number of shares at
     * the matching position in the `shares` array.
     *
     * All addresses in `payees` must be non-zero. Both arrays must have the same non-zero length, and there must be no
     * duplicates in `payees`.
     */
    constructor(address[] memory payees_, uint256[] memory shares_)
        payable
        PaymentSplitter(payees_, shares_)
    {
        for (uint256 i = 0; i < payees_.length; i++) {
            externalPayees[i] = payees_[i];
        }
    }

    /**
     * @dev The Ether received will be logged with {PaymentReceived} events. Note that these events are not fully
     * reliable: it's possible for a contract to receive Ether without triggering this function. This only affects the
     * reliability of the events, and not the actual splitting of Ether.
     *
     * To learn more about this see the Solidity documentation for
     * https://solidity.readthedocs.io/en/latest/contracts.html#fallback-function[fallback
     * functions].
     */
    receive() external payable override(PaymentSplitter) nonReentrant {
        _distribute(0, externalPayees.length);
        emit PaymentReceived(msg.sender, msg.value);
    }

    /**
     * @dev Attempt to pay a slice of payees without reverting the whole call.
     * Skips zero-due accounts and emits failures for accounts that revert on receive.
     */
    function _distribute(uint256 start, uint256 end) private {
        uint256 payeesLength = externalPayees.length;
        if (end > payeesLength) {
            end = payeesLength;
        }
        if (start >= end) {
            return;
        }

        for (uint256 i = start; i < end; i++) {
            address payable account = payable(externalPayees[i]);
            uint256 payment = releasable(account);
            if (payment == 0) {
                continue;
            }

            try this.release(account) {}
            catch (bytes memory reason) {
                emit PaymentFailed(account, payment, reason);
            }
        }
    }
}
