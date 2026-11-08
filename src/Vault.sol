// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {TestToken} from "./TestToken.sol";

/// Token principal is isolated from the native balance used by AbstractPayer.
contract Vault is AbstractCallback {
    address public immutable owner;
    TestToken public immutable token;
    address public beneficiary;
    uint256 public epoch;
    uint256 public warnAfter;
    uint256 public releaseAfter;
    uint256 public grace;
    uint256 public resetAt;
    uint256 public activityVersion;
    uint256 public warnedAt;
    bool public active;
    bool public released;
    event Configuration(uint256 epoch, uint256 warnAfter, uint256 releaseAfter, uint256 grace, bool active);
    event Warning(uint256 indexed epoch, uint256 indexed version, uint256 timestamp);
    event Heartbeat(uint256 indexed epoch, uint256 indexed version);
    event Released(uint256 indexed epoch, address indexed beneficiary, uint256 amount);
    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(
        address proxy,
        address reactive,
        address owner_,
        TestToken token_,
        address beneficiary_,
        uint256 w,
        uint256 r,
        uint256 g
    ) payable AbstractCallback(IPayable(payable(proxy)), reactive) {
        require(proxy != address(0) && reactive != address(0) && owner_ != address(0), "address");
        owner = owner_;
        token = token_;
        _configure(beneficiary_, w, r, g, true);
    }

    function configure(address b, uint256 w, uint256 r, uint256 g) external onlyOwner {
        require(!released, "released");
        _configure(b, w, r, g, true);
    }

    function cancel() external onlyOwner {
        _configure(beneficiary, warnAfter, releaseAfter, grace, false);
    }

    /// Estimated warning and release times for the current epoch, assuming no further activity.
    /// Destination-side view: it follows delivered heartbeats only, and release needs the warning to be
    /// delivered first, so before a warning the release estimate counts grace from max(warnAt, now).
    /// Zero while the policy is inactive.
    function deadlines() public view returns (uint256 warnAt, uint256 releaseAt) {
        if (!active || released) return (0, 0);
        warnAt = resetAt + warnAfter;
        uint256 warnedOrNext = warnedAt != 0 ? warnedAt : (warnAt > block.timestamp ? warnAt : block.timestamp);
        releaseAt = resetAt + releaseAfter;
        if (warnedOrNext + grace > releaseAt) releaseAt = warnedOrNext + grace;
    }

    function status()
        external
        view
        returns (
            bool active_,
            bool released_,
            uint256 epoch_,
            uint256 lastHeartbeat,
            uint256 warnedAt_,
            uint256 warnAt,
            uint256 releaseAt,
            address beneficiary_,
            uint256 balance
        )
    {
        (warnAt, releaseAt) = deadlines();
        return (active, released, epoch, resetAt, warnedAt, warnAt, releaseAt, beneficiary, token.balanceOf(address(this)));
    }

    function publishConfiguration() external {
        emit Configuration(epoch, warnAfter, releaseAfter, grace, active);
    }

    function _configure(address b, uint256 w, uint256 r, uint256 g, bool enabled) internal {
        require(
            b != address(0) && b != address(this) && w > 0 && r > w && g > 0 && r <= 3650 days && g <= 365 days,
            "config"
        );
        beneficiary = b;
        warnAfter = w;
        releaseAfter = r;
        grace = g;
        active = enabled;
        epoch++;
        resetAt = block.timestamp;
        activityVersion = 0;
        warnedAt = 0;
        emit Configuration(epoch, w, r, g, enabled);
    }

    function heartbeat(address rc, uint256 e, uint256 version) external onlyServiceProvider onlyCallbackSender(rc) {
        if (e != epoch || !active || released || version <= activityVersion) return;
        activityVersion = version;
        warnedAt = 0;
        resetAt = block.timestamp;
        emit Heartbeat(e, version);
    }

    function warn(address rc, uint256 e, uint256 version) external onlyServiceProvider onlyCallbackSender(rc) {
        if (e != epoch || !active || released || version < activityVersion) return;
        if (version > activityVersion) {
            activityVersion = version;
            warnedAt = 0;
        }
        if (warnedAt == 0) {
            warnedAt = block.timestamp;
            emit Warning(e, version, block.timestamp);
        }
    }

    function release(address rc, uint256 e, uint256 version) external onlyServiceProvider onlyCallbackSender(rc) {
        if (e != epoch || !active || released) return;
        require(version == activityVersion && warnedAt != 0, "warning");
        require(block.timestamp >= warnedAt + grace && block.timestamp >= resetAt + releaseAfter, "early");
        released = true;
        active = false;
        uint256 amount = token.balanceOf(address(this));
        require(token.transfer(beneficiary, amount), "transfer");
        emit Released(e, beneficiary, amount);
    }

    /// Returns unused native callback funds once the policy is inactive; the token principal is not touched.
    function withdrawGasFunds(address payable to, uint256 amount) external onlyOwner {
        require((!active || released) && to != address(0), "active");
        _pay(to, amount);
    }

    function recoverCancelled() external onlyOwner {
        require(!active && !released, "active");
        require(token.transfer(owner, token.balanceOf(address(this))), "transfer");
    }
}
