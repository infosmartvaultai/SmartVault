// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SmartVaultToken is ERC20 {
    constructor(address treasury) ERC20("SmartVault Token", "SVT") {
        _mint(treasury, 30_000_000 * 10 ** decimals());
    }
}