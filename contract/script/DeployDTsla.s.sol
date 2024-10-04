//SPDX-license-Identifier: MIT

pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {dTSLA} from "../src/dTSLA.sol";

contract DeployDTsla is Script {
    string constant alpacaMintSource = "./functions/sources/alpacaBalance.js";
    string constant alpacaRedeemSource = "";
    uint64 constant subId = 3615;

    function run() external {
        string memory mintSource = vm.readFile(alpacaMintSource);
        
        vm.startBroadcast();
        dTSLA dTsla = new dTSLA(mintSource, alpacaRedeemSource, subId);
        vm.stopBroadcast();
        console.log("Deployed dTsla at address: ", address(dTsla));
    }
}
