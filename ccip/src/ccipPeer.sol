// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

interface IMintableContract is IERC20 {
    function mint(address account, uint256 amount) external;

    function burn(uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;
}

/// @title - A simple messenger contract for sending/receving string data across chains.
contract CCIPPeer is
CCIPReceiver,
Initializable,
PausableUpgradeable,
AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    // Custom errors to provide more descriptive revert messages.
    // Used when the destination chain has not been allowlisted by the contract owner.
    error DestinationChainNotAllowlisted(
        uint64 destinationChainSelector,
        address sender
    );
    // Used when the destination chain uniBTC has not been allowlisted by the contract owner.
    error TargetTokensNotAllowlisted(
        uint64 destinationChainSelector,
        address token
    );
    // Used when the source chain has not been allowlisted by the contract owner.
    error SourceChainNotAllowlisted(uint64 sourceChainSelector, address sender);
    // Used when the receiver address is 0.
    error InvalidReceiverAddress();
    // Used when the message replay.
    error MessageProcessed();
    // Used when the signature replay.
    error SignatureProcessed();

    struct Request {
        address target;
        bytes callData;
    }

    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        bytes text, // The text being sent.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the CCIP message.
    );

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        bytes text // The text that was received.
    );

    // Event emitted when set minimal transfer amount.
    event MinTransferAmtSet(uint256 amount);

    // Event emitted when set minimal transfer amount.
    event SysSignerChange(address sysSigner);

    uint256 public constant SMALL_TRANSFER_MAX = 10e8;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    // Mapping to keep track of allowlisted destination chains and receiver.
    mapping(uint64 => address) public allowlistedDestinationChains;

    // Mapping to keep track of destination chains uniBTC address.
    mapping(uint64 => address) public targetTokens;

    // Mapping to keep track of allowlisted source chains and sender.
    mapping(uint64 => address) public allowlistedSourceChains;

    // Mapping to keep track of processed messages.
    mapping(bytes32 => bool) public processedMessages;

    // Mapping to keep track of processed messages.
    mapping(bytes => bool) public processedSignature;

    address public uniBTC;
    address public sysSigner;
    uint256 public minTransferAmt;

    /// @dev Modifier that checks the receiver address is not 0.
    /// @param _receiver The receiver address.
    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        _;
    }

    /// @dev Modifier that checks if the chain with the given sourceChainSelector is allowlisted and if the sender is allowlisted.
    /// @param _sourceChainSelector The selector of the destination chain.
    /// @param _sender The address of the sender.
    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (_sender != allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowlisted(_sourceChainSelector, _sender);
        _;
    }

    constructor(address _router) CCIPReceiver(_router) {
        _disableInitializers();
    }

    function initialize(
        address _defaultAdmin,
        address _uniBTC,
        address _sysSigner
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(PAUSER_ROLE, _defaultAdmin);
        uniBTC = _uniBTC;
        sysSigner = _sysSigner;
        // uniBTC has 8 digital decimal, 20*1e5 = 0.02000000
        minTransferAmt = 20 * 1e5;
    }

    /// @notice Fallback function to allow the contract to receive Ether.
    /// @dev This function has no function body, making it a default function for receiving Ether.
    /// It is automatically called when Ether is sent to the contract without any data.
    receive() external payable {
        revert("not accepted");
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev Updates the allowlist status of a destination chain for transactions.
    function allowlistDestinationChain(
        uint64 _destinationChainSelector,
        address _receiver
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowlistedDestinationChains[_destinationChainSelector] = _receiver;
    }

    /// @dev Updates the allowlist status of a destination chain Token for transactions.
    function allowlistTargetTokens(
        uint64 _destinationChainSelector,
        address _token
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        targetTokens[_destinationChainSelector] = _token;
    }

    /// @dev Updates the allowlist status of a source chain for transactions.
    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        address _sender
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowlistedSourceChains[_sourceChainSelector] = _sender;
    }

    function setMinTransferAmt(
        uint256 _minimalAmt
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_minimalAmt > 0);
        minTransferAmt = _minimalAmt;
        emit MinTransferAmtSet(_minimalAmt);
    }

    function setSysSinger(
        address _sysSigner
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sysSigner = _sysSigner;
        emit SysSignerChange(_sysSigner);
    }

    function estimateSendTokenFees(
        uint64 _destinationChainSelector,
        address _recipient,
        uint256 _amount
    ) external view returns (uint256) {
        address _receiver = allowlistedDestinationChains[
                    _destinationChainSelector
            ];
        require(_receiver != address(0), "USR007");
        address _target = CCIPPeer(payable(_receiver)).uniBTC();
        bytes memory _callData = abi.encodeWithSelector(
            IMintableContract.mint.selector,
            _recipient,
            _amount
        );
        bytes memory _message = abi.encode(
            Request({target: _target, callData: _callData})
        );
        // Only accept native token.
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _message,
            address(0)
        );
        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());
        // Get the fee required to send the CCIP message
        return router.getFee(_destinationChainSelector, evm2AnyMessage);
    }

    function sendToken(
        uint64 _destinationChainSelector,
        address _recipient,
        uint256 _amount
    )
    external
    payable
    whenNotPaused
    validateReceiver(_recipient)
    returns (bytes32 messageId)
    {
        require(
            _amount >= minTransferAmt && _amount < SMALL_TRANSFER_MAX,
            "USR006"
        );
        return _sendToken(_destinationChainSelector, _recipient, _amount);
    }

    function sendToken(
        uint64 _destinationChainSelector,
        address _recipient,
        uint256 _amount,
        bytes memory _signature
    )
    external
    payable
    whenNotPaused
    validateReceiver(_recipient)
    returns (bytes32 messageId)
    {
        require(_amount >= minTransferAmt, "USR006");
        require(
            verifySendTokenSign(
                msg.sender,
                _destinationChainSelector,
                _recipient,
                _amount,
                _signature
            ),
            "SIGNERROR"
        );
        if (processedSignature[_signature]) revert SignatureProcessed();
        processedSignature[_signature] = true;
        return _sendToken(_destinationChainSelector, _recipient, _amount);
    }

    function verifySendTokenSign(
        address _sender,
        uint64 _destinationChainSelector,
        address _recipient,
        uint256 _amount,
        bytes memory _signature
    ) public view returns (bool) {
        bytes32 msgDigest = sha256(
            abi.encode(
                _sender,
                address(this),
                block.chainid,
                _destinationChainSelector,
                _recipient,
                _amount
            )
        );
        address signer = ECDSA.recover(msgDigest, _signature);
        return signer == sysSigner;
    }

    function estimateTargetCallFees(
        uint64 _destinationChainSelector,
        address _target,
        bytes memory _callData
    ) external view returns (uint256) {
        address _receiver = allowlistedDestinationChains[
                    _destinationChainSelector
            ];
        require(_receiver != address(0), "USR007");
        bytes memory _message = abi.encode(
            Request({target: _target, callData: _callData})
        );
        // Only accept native token.
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _message,
            address(0)
        );
        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());
        // Get the fee required to send the CCIP message
        return router.getFee(_destinationChainSelector, evm2AnyMessage);
    }

    function targetCall(
        uint64 _destinationChainSelector,
        address _target,
        bytes memory _callData
    )
    external
    payable
    whenNotPaused
    onlyRole(DEFAULT_ADMIN_ROLE)
    returns (bytes32 messageId)
    {
        address _receiver = allowlistedDestinationChains[
                    _destinationChainSelector
            ];
        if (_receiver == address(0))
            revert DestinationChainNotAllowlisted(
                _destinationChainSelector,
                _receiver
            );
        bytes memory _message = abi.encode(
            Request({target: _target, callData: _callData})
        );
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _message,
            address(0)
        );
        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());
        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);
        require(msg.value >= fees, "USR008");
        // Send the CCIP message through the router and store the returned CCIP message ID
        messageId = router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );
        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _message,
            address(0),
            fees
        );
        return messageId;
    }

    function supportsInterface(
        bytes4 interfaceId
    )
    public
    pure
    override(CCIPReceiver, AccessControlUpgradeable)
    returns (bool)
    {
        return CCIPReceiver.supportsInterface(interfaceId);
    }

    /// handle a received message
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    )
    internal
    override
    whenNotPaused
    onlyAllowlisted(
    any2EvmMessage.sourceChainSelector,
    abi.decode(any2EvmMessage.sender, (address))
    ) // Make sure source chain and sender are allowlisted
    {
        if (processedMessages[any2EvmMessage.messageId])
            revert MessageProcessed();
        processedMessages[any2EvmMessage.messageId] = true;
        Request memory req = abi.decode((any2EvmMessage.data), (Request));
        req.target.functionCallWithValue(req.callData, 0);
        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
            any2EvmMessage.data
        );
    }

    function _sendToken(
        uint64 _destinationChainSelector,
        address _recipient,
        uint256 _amount
    ) internal returns (bytes32 messageId) {
        address _receiver = allowlistedDestinationChains[
                    _destinationChainSelector
            ];
        if (_receiver == address(0))
            revert DestinationChainNotAllowlisted(
                _destinationChainSelector,
                _receiver
            );

        address _target = targetTokens[
                    _destinationChainSelector

            ];
        if (_target == address(0))
            revert TargetTokensNotAllowlisted(
                _destinationChainSelector,
                _target
            );
        bytes memory _callData = abi.encodeWithSelector(
            IMintableContract.mint.selector,
            _recipient,
            _amount
        );
        bytes memory _message = abi.encode(
            Request({target: _target, callData: _callData})
        );
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _message,
            address(0)
        );
        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());
        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);
        require(msg.value >= fees, "USR008");
        // Burn uniBTC
        IMintableContract(uniBTC).burnFrom(msg.sender, _amount);
        // Send the CCIP message through the router and store the returned CCIP message ID
        messageId = router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );
        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _message,
            address(0),
            fees
        );
        return messageId;
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for sending a text.
    /// @param _receiver The address of the receiver.
    /// @param _text The string data to be sent.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _receiver,
        bytes memory _text,
        address _feeTokenAddress
    ) private pure returns (Client.EVM2AnyMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver), // ABI-encoded receiver address
            data: _text, // ABI-encoded string
            tokenAmounts: new Client.EVMTokenAmount[](0), // Empty array as no tokens are transferred
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit
                Client.EVMExtraArgsV1({gasLimit: 200_000})
            ),
            // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
            feeToken: _feeTokenAddress
        });
    }
}
