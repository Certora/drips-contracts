// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.15;

import {DripsHistory, DripsHub, DripsReceiver, IERC20, SplitsReceiver} from "./DripsHub.sol";
import {Upgradeable} from "./Upgradeable.sol";
import {ERC2771Context} from "openzeppelin-contracts/metatx/ERC2771Context.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A DripsHub driver implementing address-based user identification.
/// Each address can use `AddressDriver` to control a user ID equal to that address.
/// No registration is required, an `AddressDriver`-based user ID for each address is know upfront.
contract AddressDriver is Upgradeable, ERC2771Context {
    using SafeERC20 for IERC20;

    /// @notice The DripsHub address used by this driver.
    DripsHub public immutable dripsHub;
    /// @notice The driver ID which this driver uses when calling DripsHub.
    uint32 public immutable driverId;

    /// @param _dripsHub The drips hub to use.
    /// @param forwarder The ERC-2771 forwarder to trust. May be the zero address.
    /// @param _driverId The driver ID to use when calling DripsHub.
    constructor(DripsHub _dripsHub, address forwarder, uint32 _driverId)
        ERC2771Context(forwarder)
    {
        dripsHub = _dripsHub;
        driverId = _driverId;
    }

    /// @notice Calculates the user ID for an address
    /// @param userAddr The user address
    /// @return userId The user ID
    function calcUserId(address userAddr) public view returns (uint256 userId) {
        return (uint256(driverId) << 224) | uint160(userAddr);
    }

    /// @notice Calculates the user ID for the message sender
    /// @return userId The user ID
    function callerUserId() internal view returns (uint256 userId) {
        return calcUserId(_msgSender());
    }

    /// @notice Receive drips from the currently running cycle from a single sender.
    /// It doesn't receive drips from the previous, finished cycles, to do that use `receiveDrips`.
    /// Squeezed funds won't be received in the next calls to `squeezeDrips` or `receiveDrips`.
    /// Only funds dripped from `nextSqueezedDrips` to `block.timestamp` can be squeezed.
    /// @param erc20 The used ERC-20 token.
    /// @param senderId The ID of the user sending drips to squeeze funds from.
    /// @param historyHash The sender's history hash which was valid right before
    /// they set up the sequence of configurations described by `dripsHistory`.
    /// @param dripsHistory The sequence of the sender's drips configurations.
    /// It can start at an arbitrary past configuration, but must describe all the configurations
    /// which have been used since then including the current one, in the chronological order.
    /// Only drips described by `dripsHistory` will be squeezed.
    /// If `dripsHistory` entries have no receivers, they won't be squeezed.
    /// The next call to `squeezeDrips` will be able to squeeze only funds which
    /// have been dripped after the last timestamp squeezed in this call.
    /// This may cause some funds to be unreceivable until the current cycle ends
    /// and they can be received using `receiveDrips`.
    /// @return amt The squeezed amount.
    /// @return nextSqueezed The next timestamp that can be squeezed.
    function squeezeDrips(
        IERC20 erc20,
        uint256 senderId,
        bytes32 historyHash,
        DripsHistory[] calldata dripsHistory
    ) public returns (uint128 amt, uint32 nextSqueezed) {
        return dripsHub.squeezeDrips(callerUserId(), erc20, senderId, historyHash, dripsHistory);
    }

    /// @notice Collects the user's received already split funds
    /// and transfers them out of the drips hub contract.
    /// @param erc20 The token to use
    /// @param transferTo The address to send collected funds to
    /// @return amt The collected amount
    function collect(IERC20 erc20, address transferTo) public returns (uint128 amt) {
        amt = dripsHub.collect(callerUserId(), erc20);
        erc20.safeTransfer(transferTo, amt);
    }

    /// @notice Gives funds from the message sender to the receiver.
    /// The receiver can collect them immediately.
    /// Transfers the funds to be given from the message sender's wallet to the drips hub contract.
    /// @param receiver The receiver
    /// @param erc20 The token to use
    /// @param amt The given amount
    function give(uint256 receiver, IERC20 erc20, uint128 amt) public {
        _transferFromCaller(erc20, amt);
        dripsHub.give(callerUserId(), receiver, erc20, amt);
    }

    /// @notice Sets the message sender's drips configuration.
    /// Transfers funds between the message sender's wallet and the drips hub contract
    /// to fulfill the change of the drips balance.
    /// @param erc20 The token to use
    /// @param currReceivers The list of the drips receivers set in the last drips update
    /// of the sender.
    /// If this is the first update, pass an empty array.
    /// @param balanceDelta The drips balance change to be applied.
    /// Positive to add funds to the drips balance, negative to remove them.
    /// @param newReceivers The list of the drips receivers of the sender to be set.
    /// Must be sorted by the receivers' addresses, deduplicated and without 0 amtPerSecs.
    /// @param transferTo The address to send funds to in case of decreasing balance
    /// @return newBalance The new drips balance of the sender.
    /// @return realBalanceDelta The actually applied drips balance change.
    function setDrips(
        IERC20 erc20,
        DripsReceiver[] calldata currReceivers,
        int128 balanceDelta,
        DripsReceiver[] calldata newReceivers,
        address transferTo
    ) public returns (uint128 newBalance, int128 realBalanceDelta) {
        if (balanceDelta > 0) {
            _transferFromCaller(erc20, uint128(balanceDelta));
        }
        (newBalance, realBalanceDelta) =
            dripsHub.setDrips(callerUserId(), erc20, currReceivers, balanceDelta, newReceivers);
        if (realBalanceDelta < 0) {
            erc20.safeTransfer(transferTo, uint128(-realBalanceDelta));
        }
    }

    /// @notice Sets the message sender's splits configuration.
    /// @param receivers The list of the user's splits receivers to be set.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    /// Each splits receiver will be getting `weight / TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the user.
    function setSplits(SplitsReceiver[] calldata receivers) public {
        dripsHub.setSplits(callerUserId(), receivers);
    }

    /// @notice Emits the message sender's metadata.
    /// The key and the value are not standardized by the protocol, it's up to the user
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @param key The metadata key
    /// @param value The metadata value
    function emitUserMetadata(uint256 key, bytes calldata value) public {
        dripsHub.emitUserMetadata(callerUserId(), key, value);
    }

    function _transferFromCaller(IERC20 erc20, uint128 amt) internal {
        erc20.safeTransferFrom(_msgSender(), address(this), amt);
        address reserve = address(dripsHub.reserve());
        // Approval is done only on the first usage of the ERC-20 token in the reserve by the driver
        if (erc20.allowance(address(this), reserve) == 0) {
            erc20.approve(reserve, type(uint256).max);
        }
    }
}
