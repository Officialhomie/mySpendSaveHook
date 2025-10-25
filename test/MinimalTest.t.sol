// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";

contract MinimalTest is Test {
    function testStorageSetMaxSavingsPercentage() public {
        address poolManager = address(0x123);
        SpendSaveStorage storage_ = new SpendSaveStorage(poolManager);

        // Test that our new function exists and works
        storage_.setMaxSavingsPercentage(5000); // 50%
        assertEq(storage_.maxSavingsPercentage(), 5000);
    }
}
