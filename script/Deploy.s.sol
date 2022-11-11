// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.15;

import "forge-std/Script.sol";
import "dss-interfaces/Interfaces.sol";

import { SavingsDai } from "../src/SavingsDai.sol";

contract Deploy is Script {

    function run() external {
        ChainlogAbstract chainlog = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
        
        vm.startBroadcast();
        new SavingsDai(
            chainlog.getAddress("MCD_JOIN_DAI"),
            chainlog.getAddress("MCD_POT")
        );
        vm.stopBroadcast();
    }

}
