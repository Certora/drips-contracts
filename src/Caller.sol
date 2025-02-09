// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.15;

import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {ECDSA, EIP712} from "openzeppelin-contracts/utils/cryptography/draft-EIP712.sol";
import {ERC2771Context} from "openzeppelin-contracts/metatx/ERC2771Context.sol";

/// @notice Description of a call.
/// @param to The called address.
/// @param data The calldata to be used for the call.
/// @param value The value of the call.
struct Call {
    address to;
    bytes data;
    uint256 value;
}

/// @notice A generic call executor increasing flexibility of other smart contracts' APIs.
/// It offers 3 main features, which can be mixed and matched for even more flexibility:
/// - Authorizing addresses to act on behalf of other addresses
/// - Support for EIP-712 messages
/// - Batching calls
///
/// `Caller` adds these features to the APIs of all smart contracts reading the message
/// sender passed as per ERC-2771 and accepting this contract as a trusted forwarder.
/// To all other contracts `Caller` adds a feature of batching calls
/// for all functions tolerating `msg.sender` being an instance of `Caller`.
///
/// Usage examples:
/// - Batching sequences of calls to a contract.
/// The contract API may consist of many functions which need to be called in sequence,
/// but it may not offer a composite functions performing exactly that sequence.
/// It's expensive, slow and unreliable to create a separate transaction for each step.
/// To solve that problem create a batch of calls and submit it to `callBatched`.
/// - Batching sequences of calls to multiple contracts.
/// It's a common pattern to submit an ERC-2612 permit to approve a smart contract
/// to spend the user's ERC-20 tokens before running that contract's logic.
/// Unfortunately unless the contract's API accepts signed messages for the token it requires
/// creating two separate transactions making it as inconvenient as a regular approval.
/// The solution is again to use `callBatched` because it can call multiple contracts.
/// Just create a batch first calling the ERC-20 contract and then the contract needing the tokens.
/// - Setting up a proxy address.
/// Sometimes a secure but inconvenient to use address like a cold wallet
/// or a multisig needs to have a proxy or an operator.
/// That operator is temporarily trusted, but later it must be revoked or rotated.
/// To achieve this first `authorize` the proxy using the safe address and then use that proxy
/// to act on behalf of the secure address using `callAs`.
/// Later, when the proxy address needs to be revoked, either the secure address or the proxy itself
/// can `unauthorize` the proxy address and maybe `authorize` another address.
/// - Setting up operations callable by others.
/// Some operations may benefit from being callable either by trusted addresses or by anybody.
/// To achieve this deploy a smart contract executing these operations
/// via `callAs` and, if you need that too, implementing a custom authorization.
/// Finally, `authorize` this smart contract to act on behalf of your address.
/// - Batching dynamic sequences of calls.
/// Some operations need to react dynamically to the state of the blockchain.
/// For example an unknown amount of funds is retrieved from a smart contract,
/// which then needs to be dynamically split and used for different purposes.
/// To do this, first deploy a smart contract performing that logic.
/// Next, call `callBatched` which first calls `authorize` on the `Caller` itself authorizing
/// the new contract to perform `callAs`, then calls that contract and finally `unauthorize`s it.
/// This way the contract can perform any logic it needs on behalf of your address, but only once.
/// - Gasless transactions.
/// It's an increasingly common pattern to use smart contracts without necessarily spending Ether.
/// This is achieved with gasless transactions where the wallet signs an ERC-712 message
/// and somebody else submits the actual transaction executing what the message requests.
/// It may be executed by another wallet or by an operator
/// expecting to be repaid for the spent Ether in other assets.
/// You can achieve this with `callSigned`, which allows anybody
/// to execute a call on behalf of the signer of a message.
/// `Caller` doesn't deal with gas, so if you're using a gasless network,
/// it may require you to specify the gas needed for the entire call execution.
/// - Executing batched calls with authorization or signature.
/// You can use both `callAs` and `callSigned` to call `Caller` itself,
/// which in turn can execute batched calls on behalf of the authorizing or signing address.
/// It also applies to `authorize` and `unauthorize`, they too can be called using
/// `callAs`, `callSigned` or `callBatched`.
contract Caller is EIP712("Caller", "1"), ERC2771Context(address(this)) {
    string internal constant CALL_SIGNED_TYPE_NAME = "CallSigned("
        "address sender,address to,bytes data,uint256 value,uint256 nonce,uint256 deadline)";
    bytes32 internal immutable callSignedTypeHash = keccak256(bytes(CALL_SIGNED_TYPE_NAME));

    /// @notice True if the address authorizes another address to make calls on its behalf.
    /// The first address is the authorizing one and the second address is the authorized one.
    mapping(address => mapping(address => bool)) public isAuthorized;
    /// @notice The nonce which needs to be used in the next EIP-712 message signed by the address.
    mapping(address => uint256) public nonce;

    /// @notice Emitted when granting the authorization
    /// of an address to make calls on behalf of the `sender`.
    /// @param sender The authorizing address.
    /// @param authorized The authorized address.
    event Authorized(address indexed sender, address indexed authorized);

    /// @notice Emitted when revoking the authorization
    /// of an address to make calls on behalf of the `sender`.
    /// @param sender The authorizing address.
    /// @param unauthorized The authorized address.
    event Unauthorized(address indexed sender, address indexed unauthorized);

    /// @notice Grants the authorization of an address to make calls on behalf of the sender.
    /// @param authorized The authorized address.
    function authorize(address authorized) public {
        address sender = _msgSender();
        isAuthorized[sender][authorized] = true;
        emit Authorized(sender, authorized);
    }

    /// @notice Revokes the authorization of an address to make calls on behalf of the sender.
    /// @param unauthorized The unauthorized address.
    function unauthorize(address unauthorized) public {
        address sender = _msgSender();
        isAuthorized[sender][unauthorized] = false;
        emit Unauthorized(sender, unauthorized);
    }

    /// @notice Makes a call on behalf of the `sender`.
    /// Callable only by an address currently `authorize`d by the `sender`.
    /// Reverts if the call reverts or the called address is not a smart contract.
    /// @param sender The sender to be set as the message sender of the call as per ERC-2771.
    /// @param to The called address.
    /// @param data The calldata to be used for the call.
    /// @return returnData The data returned by the call.
    function callAs(address sender, address to, bytes memory data)
        public
        payable
        returns (bytes memory returnData)
    {
        require(isAuthorized[sender][_msgSender()], "Not authorized");
        return _call(sender, to, data, msg.value);
    }

    /// @notice Makes a call on behalf of the `sender`.
    /// Requires a `sender`'s signature of an ERC-721 message approving the call.
    /// Reverts if the call reverts or the called address is not a smart contract.
    /// @param sender The sender to be set as the message sender of the call as per ERC-2771.
    /// @param to The called address.
    /// @param data The calldata to be used for the call.
    /// @param deadline The timestamp until which the message signature is valid.
    /// @param r The `r` part of the compact message signature as per EIP-2098.
    /// @param sv The `sv` part of the compact message signature as per EIP-2098.
    /// @return returnData The data returned by the call.
    function callSigned(
        address sender,
        address to,
        bytes memory data,
        uint256 deadline,
        bytes32 r,
        bytes32 sv
    ) public payable returns (bytes memory returnData) {
        require(block.timestamp <= deadline, "Execution deadline expired");
        uint256 currNonce = nonce[sender]++;
        bytes32 executeHash = keccak256(
            abi.encode(
                callSignedTypeHash, sender, to, keccak256(data), msg.value, currNonce, deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(executeHash), r, sv);
        require(signer == sender, "Invalid signature");
        return _call(sender, to, data, msg.value);
    }

    /// @notice Executes a batch of calls.
    /// The caller will be set as the message sender of all the calls as per ERC-2771.
    /// Reverts if any of the calls reverts or any of the called addresses is not a smart contract.
    /// @param calls The calls to perform.
    /// @return returnData The data returned by each of the calls.
    function callBatched(Call[] memory calls) public payable returns (bytes[] memory returnData) {
        returnData = new bytes[](calls.length);
        address sender = _msgSender();
        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];
            returnData[i] = _call(sender, call.to, call.data, call.value);
        }
    }

    function _call(address sender, address to, bytes memory data, uint256 value)
        internal
        returns (bytes memory returnData)
    {
        // Encode the message sender as per ERC-2771
        return Address.functionCallWithValue(to, abi.encodePacked(data, sender), value);
    }
}
