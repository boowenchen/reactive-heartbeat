// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

contract HeartbeatReactive is AbstractReactive {
    uint256 public constant PING = uint256(keccak256("Ping(address,uint256)"));
    uint256 public constant TRANSFER = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 public constant CONFIG = uint256(keccak256("Configuration(uint256,uint256,uint256,uint256,bool)"));
    uint256 public constant RELEASED = uint256(keccak256("Released(uint256,address,uint256)"));
    uint8 public constant KIND_PING = 0;
    uint8 public constant KIND_TRANSFER = 1;
    /// Release is requested this long after the warning request, on top of the policy's grace, so the
    /// destination (which measures grace from the delivered warning) does not reject it as early.
    uint256 public constant DELIVERY_MARGIN = 30;
    address public immutable owner;
    address public immutable cronEmitter;
    uint256 public immutable cronTopic;
    uint256 public immutable destinationChain;
    uint64 public immutable callbackGas;
    address public vault;
    mapping(uint256 => address) public pulses;
    /// Token contracts whose ERC20 Transfer(from = owner, value > 0) counts as activity. Allowlisted
    /// because any contract can emit a Transfer-shaped log naming the owner.
    mapping(uint256 => mapping(address => bool)) public trackedToken;
    uint256[] internal sourceChains;
    address[] internal sourceContracts;
    uint256[] internal sourceTopics;
    mapping(uint256 => uint256) public lastActivity;
    mapping(bytes32 => bool) public seen;
    uint256 public latestActivity;
    uint256 public epoch;
    uint256 public version;
    uint256 public warnAfter;
    uint256 public releaseAfter;
    uint256 public grace;
    bool public active;
    bool public cronEnabled = true;
    bool public released;
    /// (epoch, version) of the last warning request and when it was made.
    bytes32 public warnRequested;
    uint256 public warnRequestedAt;
    bool public warningOutstanding;
    uint256 public lastHeartbeatRequest;
    event Activity(uint256 indexed chainId, address indexed source, uint8 kind, uint256 version);
    event Requested(uint256 indexed epoch, uint256 indexed version, uint8 action);
    event VaultLinked(address indexed vault);
    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(
        address owner_,
        uint256[] memory chains,
        address[] memory sources,
        uint256[] memory tokenChains,
        address[] memory tokens,
        uint256 destination,
        address cron,
        uint256 topic,
        uint64 gas_
    ) payable {
        require(
            owner_ != address(0) && cron != address(0) && destination != 0 && chains.length >= 2 && chains.length <= 3 && sources.length == chains.length
                && tokens.length <= 6 && tokenChains.length == tokens.length && gas_ >= 100000,
            "config"
        );
        owner = owner_;
        destinationChain = destination;
        cronEmitter = cron;
        cronTopic = topic;
        callbackGas = gas_;
        for (uint256 i; i < chains.length; i++) {
            require(chains[i] != 0 && sources[i] != address(0) && pulses[chains[i]] == address(0), "source");
            pulses[chains[i]] = sources[i];
            _addSource(chains[i], sources[i], PING);
        }
        for (uint256 i; i < tokens.length; i++) {
            require(tokenChains[i] != 0 && tokens[i] != address(0) && !trackedToken[tokenChains[i]][tokens[i]], "token");
            trackedToken[tokenChains[i]][tokens[i]] = true;
            _addSource(tokenChains[i], tokens[i], TRANSFER);
        }
        _cron(true);
    }

    function _addSource(uint256 chain, address source, uint256 topic) internal {
        sourceChains.push(chain);
        sourceContracts.push(source);
        sourceTopics.push(topic);
        SYSTEM.subscribe(chain, source, topic, uint256(uint160(owner)), REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setVault(address v) external onlyOwner {
        require(vault == address(0) && v != address(0), "vault");
        vault = v;
        emit VaultLinked(v);
        SYSTEM.subscribe(destinationChain, v, CONFIG, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(destinationChain, v, RELEASED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setCronEnabled(bool enabled) external onlyOwner {
        _setCron(enabled);
    }

    /// Returns unused lREACT once the policy is inactive (cancelled or released).
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        require(!active && to != address(0), "active");
        _pay(to, amount);
    }

    function _setCron(bool enabled) internal {
        if (enabled == cronEnabled) return;
        cronEnabled = enabled;
        _cron(enabled);
    }

    function _cron(bool enabled) internal {
        if (enabled) {
            SYSTEM.subscribe(block.chainid, cronEmitter, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else {
            SYSTEM.unsubscribe(block.chainid, cronEmitter, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// Release is terminal: stop paying for cron ticks and for activity that can no longer matter.
    function _finish() internal {
        active = false;
        released = true;
        _setCron(false);
        uint256 who = uint256(uint160(owner));
        for (uint256 i; i < sourceChains.length; i++) {
            SYSTEM.unsubscribe(sourceChains[i], sourceContracts[i], sourceTopics[i], who, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    function react(LogRecord calldata log) external onlySystem {
        if (released) return;
        if (log.chainId == destinationChain && log.contractAddress == vault && vault != address(0)) {
            if (log.topic0 == RELEASED && log.topic1 == epoch) {
                _finish();
            } else if (log.topic0 == CONFIG) {
                _configuration(log.data);
            }
            return;
        }
        if (_isActivity(log)) {
            bytes32 key = keccak256(abi.encode(log.chainId, log.txHash, log.logIndex));
            if (seen[key]) return;
            seen[key] = true;
            // LogRecord contains no source timestamp. Use conservative receipt time;
            // delayed/reordered activity postpones release, never accelerates it.
            lastActivity[log.chainId] = block.timestamp;
            latestActivity = block.timestamp;
            version++;
            emit Activity(log.chainId, log.contractAddress, log.topic0 == PING ? KIND_PING : KIND_TRANSFER, version);
            // The destination only needs a heartbeat to clear a warning promptly; otherwise at most one
            // per quarter warning window keeps its clock close without paying a callback per transfer.
            if (active && (warningOutstanding || block.timestamp >= lastHeartbeatRequest + warnAfter / 4)) {
                warningOutstanding = false;
                lastHeartbeatRequest = block.timestamp;
                _request(abi.encodeWithSignature("heartbeat(address,uint256,uint256)", address(0), epoch, version), 0);
            }
            return;
        }
        if (
            !cronEnabled || !active || vault == address(0) || log.chainId != block.chainid
                || log.contractAddress != cronEmitter || log.topic0 != cronTopic
        ) return;
        if (block.timestamp < latestActivity + warnAfter) return;
        bytes32 warnKey = keccak256(abi.encode(epoch, version));
        if (warnRequested != warnKey) {
            // One warning request per activity version.
            warnRequested = warnKey;
            warnRequestedAt = block.timestamp;
            warningOutstanding = true;
            _request(abi.encodeWithSignature("warn(address,uint256,uint256)", address(0), epoch, version), 1);
            return;
        }
        if (block.timestamp >= latestActivity + releaseAfter && block.timestamp >= warnRequestedAt + grace + DELIVERY_MARGIN) {
            // The warning is resent with each release attempt so a lost warning cannot block release.
            _request(abi.encodeWithSignature("warn(address,uint256,uint256)", address(0), epoch, version), 1);
            _request(abi.encodeWithSignature("release(address,uint256,uint256)", address(0), epoch, version), 2);
        }
    }

    function _isActivity(LogRecord calldata log) internal view returns (bool) {
        if (log.topic1 != uint256(uint160(owner)) || log.contractAddress == address(0)) return false;
        if (log.topic0 == PING) return log.contractAddress == pulses[log.chainId];
        // ERC20 only (ERC721 carries the id in a topic and no data); a zero-value transferFrom needs
        // no allowance on most tokens, so it would let anyone fake activity.
        return log.topic0 == TRANSFER && trackedToken[log.chainId][log.contractAddress] && log.data.length == 32
            && abi.decode(log.data, (uint256)) > 0;
    }

    function _configuration(bytes calldata data) internal {
        (uint256 e, uint256 w, uint256 r, uint256 g, bool a) = abi.decode(data, (uint256, uint256, uint256, uint256, bool));
        if (e < epoch) return;
        if (e == epoch) {
            // Same-epoch republish can only switch the policy off (e.g. resync after a lost Released log).
            if (!a && active) {
                active = false;
                _setCron(false);
            }
            return;
        }
        require(w > 0 && r > w, "config");
        epoch = e;
        warnAfter = w;
        releaseAfter = r;
        grace = g;
        active = a;
        latestActivity = block.timestamp;
        version = 0;
        warnRequested = bytes32(0);
        warnRequestedAt = 0;
        warningOutstanding = false;
        lastHeartbeatRequest = 0;
        // A cancelled policy stops paying for cron ticks until it is configured again.
        _setCron(a);
    }

    function _request(bytes memory payload, uint8 action) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0(destinationChain, vault, callbackGas, payload)
        );
        emit Requested(epoch, version, action);
    }
}
