// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import './interfaces/IOffChainIncentiveCalculations.sol';
import './libraries/KnownLengthSet.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

/* 
    This contract provides helper functions for calculating liquiditySeconds for all tokens in the farm, off-chain.
    These calculations are very costly and should _not_ be called on chain. 
    
    Calculation Algorithm
    -----------------------
    - select a recent block and use the timestamp and the number of that block for further calculations
    - Get the length of the stakes on the incentive
    - if length is big split into chunks by a limit (e.g. 100)
    - calculate total for every chunk
    - get total for previously unstaked tokens
    - update incentive by the calculated total

    Pseudocode
    -----------------------
    // these calls should be done on the same block number 
    var timestamp = ... // timestamp of the selected block
    var key = ... // information of the incentive
    var incentiveId = ... // id of the incentive, calculated from key
    var length = UbeswapV3Farming.incentives(incentiveId).numberOfStakes
    var result = 0
    for (var range in split_chunks(length)) {
        result += UbeswapV3Farming.calculateIncentiveTotalSecondsInsideX128(incentiveId, pool, range.start, range.end)
    }
    result += UbeswapV3Farming.unstakedTotalSeconds(incentiveId)

    UbeswapV3Farming.updateIncentiveDistributionInfo(key, result, timestamp)
*/

abstract contract OffChainIncentiveCalculations is IOffChainIncentiveCalculations {
    using KnownLengthSet for KnownLengthSet.UintSet;

    // incentiveId => staked tokens set
    mapping(bytes32 => KnownLengthSet.UintSet) private _stakedTokens;

    // incentiveId => totalSecondsInside
    mapping(bytes32 => uint160) public override unstakedTotalSeconds;

    function getStakedToken(bytes32 incentiveId, uint256 index) public view override returns (uint256) {
        return _stakedTokens[incentiveId].at(index);
    }

    function calculateIncentiveTotalSecondsInsideX128(
        bytes32 incentiveId,
        IUniswapV3Pool pool,
        uint256 startIndex,
        uint256 endIndex
    ) external view override returns (uint160) {
        uint160 totalValue = 0;

        for (uint256 i = startIndex; i < endIndex; i++) {
            uint256 tokenId = _stakedTokens[incentiveId].at(i);
            require(tokenId > 0, 'stake does not exist');
            (uint160 initialSecondsPerLiquidityInsideX128, uint128 liquidity, int24 tickLower, int24 tickUpper) =
                _getStakeInfoForOffChainCalc(incentiveId, tokenId);

            (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(tickLower, tickUpper);

            totalValue += (secondsPerLiquidityInsideX128 * liquidity) - initialSecondsPerLiquidityInsideX128;
        }

        return totalValue;
    }

    function _addStakedToken(
        bytes32 incentiveId,
        uint256 tokenId,
        uint256 currNumberOfStake
    ) internal {
        _stakedTokens[incentiveId].add(tokenId, currNumberOfStake);
    }

    function _removeStakedToken(
        bytes32 incentiveId,
        uint256 tokenId,
        uint256 currNumberOfStake,
        uint160 accumulatedSeconds
    ) internal {
        _stakedTokens[incentiveId].remove(tokenId, currNumberOfStake);
        unstakedTotalSeconds[incentiveId] += accumulatedSeconds;
    }

    function _getStakeInfoForOffChainCalc(bytes32 incentiveId, uint256 tokenId)
        internal
        view
        virtual
        returns (
            uint160 initialSecondsPerLiquidityInsideX128,
            uint128 liquidity,
            int24 tickLower,
            int24 tickUpper
        );
}
