// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPriceOracleAdapter {
    function getCmrUsdPrice() external view returns (uint256);
    function getEthUsdPrice() external view returns (uint256);
}
