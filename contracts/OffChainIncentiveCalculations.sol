// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import './libraries/KnownLengthSet.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

/* 
    var length = incentives(incentiveId).numberOfStakes
    var total = calculateIncentiveTotalSecondsInsideX128(incentiveId, 0, length)
    total += unstakedTotalSeconds(incentiveId);
*/

abstract contract OffChainIncentiveCalculations {
    using KnownLengthSet for KnownLengthSet.UintSet;

    // incentiveId => staked tokens set
    mapping(bytes32 => KnownLengthSet.UintSet) private _stakedTokens;

    // incentiveId => totalSecondsInside
    mapping(bytes32 => uint160) public unstakedTotalSeconds;

    function getStakedToken(bytes32 incentiveId, uint256 index) public view returns(uint256) {
        return _stakedTokens[incentiveId].at(index);
    }

    function calculateIncentiveTotalSecondsInsideX128(bytes32 incentiveId, IUniswapV3Pool pool, uint256 startIndex, uint256 endIndex)
        external
        view
        returns (uint160)
    {
        uint160 totalValue = 0;

        for (uint256 i = startIndex; i < endIndex; i++) {
            uint256 tokenId = _stakedTokens[incentiveId].at(i);
            require(tokenId > 0, 'stake does not exist');
            (uint160 initialSecondsPerLiquidityInsideX128, uint128 liquidity, int24 tickLower, int24 tickUpper) = _getStakeInfoForOffChainCalc(incentiveId, tokenId);

            (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(tickLower, tickUpper);

            totalValue += (secondsPerLiquidityInsideX128 * liquidity) - initialSecondsPerLiquidityInsideX128;
        }

        return totalValue;
    }

    function _addStakedToken(bytes32 incentiveId, uint256 tokenId, uint256 currNumberOfStake) internal {
        _stakedTokens[incentiveId].add(tokenId, currNumberOfStake);
    }

    function _removeStakedToken(bytes32 incentiveId, uint256 tokenId, uint256 currNumberOfStake , uint160 accumulatedSeconds) internal {
        _stakedTokens[incentiveId].remove(tokenId, currNumberOfStake);
        unstakedTotalSeconds[incentiveId] += accumulatedSeconds;
    }

    function _getStakeInfoForOffChainCalc(bytes32 incentiveId, uint256 tokenId) internal view virtual returns(uint160 initialSecondsPerLiquidityInsideX128, uint128 liquidity, int24 tickLower, int24 tickUpper);

}

