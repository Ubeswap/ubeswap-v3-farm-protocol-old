// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

interface IOffChainIncentiveCalculations {
    function unstakedTotalSeconds(bytes32 incentiveId) external view returns (uint160);

    function getStakedToken(bytes32 incentiveId, uint256 index) external view returns (uint256);

    function calculateIncentiveTotalSecondsInsideX128(
        bytes32 incentiveId,
        IUniswapV3Pool pool,
        uint256 startIndex,
        uint256 endIndex
    ) external view returns (uint160);
}
