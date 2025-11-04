// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

contract RemoveDelegation is Script {
    address public MY_MAIN_ADDRESS;
    uint256 public MY_MAIN_PK;

    function setUp() public {
        MY_MAIN_PK = vm.envUint("MY_MAIN_PK");
        MY_MAIN_ADDRESS = vm.addr(MY_MAIN_PK);
    }

    // Check-only function (use with --sig "checkDelegation()")
    function checkDelegation() public view {
        console.log("=== Checking Delegation Status ===");
        console.log("Account:", MY_MAIN_ADDRESS);

        bytes memory code = getCode(MY_MAIN_ADDRESS);
        bool hasDelegation = checkHasDelegation(code);

        console.log("Has delegation:", hasDelegation);

        if (hasDelegation) {
            address delegatedTo = extractDelegationAddress(code);
            console.log("Delegated to:", delegatedTo);
        } else {
            console.log("[OK] No delegation found. Account is a regular EOA.");
        }
    }

    function run() public {
        console.log("=== Checking Delegation Status ===");
        console.log("Account:", MY_MAIN_ADDRESS);

        // Check if account has delegated code
        bytes memory code = getCode(MY_MAIN_ADDRESS);
        bool hasDelegation = checkHasDelegation(code);

        console.log("Has delegation:", hasDelegation);

        if (hasDelegation) {
            address delegatedTo = extractDelegationAddress(code);
            console.log("Delegated to:", delegatedTo);

            console.log("\n=== Removing Delegation ===");
            // Remove delegation by delegating to address(0)
            // According to EIP-7702, delegating to address(0) clears the code
            vm.broadcast(MY_MAIN_PK);
            vm.signAndAttachDelegation(address(0), MY_MAIN_PK);
            // We need to execute a call to make the transaction valid
            // An empty call to ourselves will do
            (bool success,) = MY_MAIN_ADDRESS.call("");
            require(success, "Failed to execute delegation removal transaction");

            console.log("Delegation removal transaction broadcasted");

            console.log("\n=== Verification ===");
            console.log("Note: Code clearing happens at transaction execution time.");
            console.log("Run this script again after the transaction is mined to verify removal.");
            console.log("Or use: cast code", MY_MAIN_ADDRESS, "-r $RPC");
        } else {
            console.log("[OK] No delegation found. Account is a regular EOA.");
        }
    }

    function getCode(address addr) internal view returns (bytes memory) {
        return addr.code;
    }

    function checkHasDelegation(bytes memory code) internal pure returns (bool) {
        // EIP-7702 delegation indicator: 0xef0100 || address (23 bytes total)
        if (code.length != 23) return false;
        // Check for 0xef0100 prefix
        return code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
    }

    function extractDelegationAddress(bytes memory code) internal pure returns (address) {
        require(checkHasDelegation(code), "Not a delegation");
        // Address is in the last 20 bytes
        bytes20 addr;
        assembly {
            addr := mload(add(add(code, 0x20), 3))
        }
        return address(addr);
    }
}

