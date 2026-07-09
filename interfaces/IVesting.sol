// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVesting {
    function createVestingSchedule(address beneficiary, uint256 amount) external;
    function svt() external view returns (address);
}
