// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import {IHook} from "../../interfaces/IHook.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract BoundedTTLHook_1Week is IHook, Ownable {
    mapping (address=>bool) whitelistedApps;

    function onPositionUse(bytes calldata _data) external {
        (address app, uint256 ttl) = abi.decode(_data, (address, uint256));
        if (!whitelistedApps[app]) revert();
        if (ttl > 7 days) revert();
    }

    function onPositionUnUse(bytes calldata _data) external {}

    function updateWhitelistedAppsStatus(address app, bool status) external onlyOwner {
        whitelistedApps[app] = status;
    }
}
