// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

contract HeartbeatReactive is AbstractReactive {
    uint256 public constant PING = uint256(keccak256("Ping(address,uint256)"));
    uint256 public constant CONFIG = uint256(keccak256("Configuration(uint256,uint256,uint256,uint256,bool)"));
    uint256 public constant RELEASED = uint256(keccak256("Released(uint256,address,uint256)"));
    address public immutable owner;
    address public immutable cronEmitter;
    uint256 public immutable cronTopic;
    uint256 public immutable destinationChain;
    uint64 public immutable callbackGas;
    address public vault;
    mapping(uint256 => address) public pulses;
    mapping(uint256 => uint256) public lastActivity;
    mapping(bytes32 => bool) public seen;
    uint256 public latestActivity;
    uint256 public epoch;
    uint256 public version;
    uint256 public warnAfter;
    uint256 public releaseAfter;
    bool public active;
    bool public cronEnabled = true;
    event Observed(uint256 indexed chainId, uint256 timestamp, uint256 version);
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
        uint256 destination,
        address cron,
        uint256 topic,
        uint64 gas_
    ) payable {
        require(
            owner_ != address(0) && cron != address(0) && destination != 0 && chains.length >= 2 && chains.length <= 3 && sources.length == chains.length
                && gas_ >= 100000,
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
            SYSTEM.subscribe(chains[i], sources[i], PING, uint256(uint160(owner_)), REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        _cron(true);
    }

    function setVault(address v) external onlyOwner {
        require(vault == address(0) && v != address(0), "vault");
        vault = v;
        emit VaultLinked(v);
        SYSTEM.subscribe(destinationChain, v, CONFIG, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(destinationChain, v, RELEASED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setCronEnabled(bool enabled) external onlyOwner {
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

    function react(LogRecord calldata log) external onlySystem {
        if (
            log.chainId == destinationChain && log.contractAddress == vault && log.topic0 == RELEASED
                && log.topic1 == epoch
        ) {
            active = false;
            if (cronEnabled) {
                cronEnabled = false;
                _cron(false);
            }
            return;
        }
        if (log.chainId == destinationChain && log.contractAddress == vault && log.topic0 == CONFIG) {
            (uint256 e, uint256 w, uint256 r,, bool a) =
                abi.decode(log.data, (uint256, uint256, uint256, uint256, bool));
            if (e <= epoch) return;
            require(w > 0 && r > w, "config");
            epoch = e;
            warnAfter = w;
            releaseAfter = r;
            active = a;
            latestActivity = block.timestamp;
            version = 0;
            return;
        }
        if (
            log.contractAddress != address(0) && log.contractAddress == pulses[log.chainId] && log.topic0 == PING
                && log.topic1 == uint256(uint160(owner))
        ) {
            bytes32 key = keccak256(abi.encode(log.chainId, log.txHash, log.logIndex));
            if (seen[key]) return;
            seen[key] = true;
            // LogRecord contains no source timestamp. Use conservative receipt time;
            // delayed/reordered activity postpones release, never accelerates it.
            lastActivity[log.chainId] = block.timestamp;
            latestActivity = block.timestamp;
            version++;
            emit Observed(log.chainId, block.timestamp, version);
            if (active) {
                _request(abi.encodeWithSignature("heartbeat(address,uint256,uint256)", address(0), epoch, version), 0);
            }
            return;
        }
        if (
            !cronEnabled || !active || vault == address(0) || log.chainId != block.chainid
                || log.contractAddress != cronEmitter || log.topic0 != cronTopic
        ) return;
        if (block.timestamp >= latestActivity + warnAfter) {
            _request(abi.encodeWithSignature("warn(address,uint256,uint256)", address(0), epoch, version), 1);
        }
        if (block.timestamp >= latestActivity + releaseAfter) {
            _request(abi.encodeWithSignature("release(address,uint256,uint256)", address(0), epoch, version), 2);
        }
    }

    function _request(bytes memory payload, uint8 action) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0(destinationChain, vault, callbackGas, payload)
        );
        emit Requested(epoch, version, action);
    }
}
