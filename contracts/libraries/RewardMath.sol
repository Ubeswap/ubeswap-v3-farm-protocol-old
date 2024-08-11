// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '@uniswap/v3-core/contracts/libraries/FullMath.sol';

/// @title Math for computing rewards
/// @notice Allows computing rewards given some parameters of stakes and incentives
library RewardMath {
    /// @notice Compute the amount of rewards owed given parameters of the incentive and stake
    /// @param incentiveCumulativeReward The total amount of cumulative rewards added to the incentive
    /// @param incentiveCumulativeRewardWhenStaked Value of incentive.cumulativeReward when the token is staked
    /// @param incentiveTotalSecondsInsideX128 Current value of total liquidity-seconds of the incentive. (calculated off-chain)
    /// @param stakeInitialSecondsPerLiquidityInsideX128 per liq seconds of tick range that is recorded when the token is staked
    /// @param incentiveTotalSecondsInsideX128WhenStaked Value of total liquidity-seconds of the incentive when the token is staked
    /// @param positionSecondsPerLiquidityInsideX128 current per liq seconds of tick range (fetched from the pool)
    /// @param liquidity The amount of liquidity of the token
    /// @return reward The amount of rewards owed
    /// @return accumulatedSeconds The liquidity-seconds that is accumulated for the token from time of stake
    function computeRewardAmount(
        uint128 incentiveCumulativeReward,
        uint128 incentiveCumulativeRewardWhenStaked,
        uint160 incentiveTotalSecondsInsideX128,
        uint160 incentiveTotalSecondsInsideX128WhenStaked,
        uint160 stakeInitialSecondsPerLiquidityInsideX128,
        uint160 positionSecondsPerLiquidityInsideX128,
        uint128 liquidity,
        uint128 stakeClaimedReward
    ) internal pure returns (uint128 reward, uint160 accumulatedSeconds) {
        uint256 totalRewardFromStakeTime = incentiveCumulativeReward - incentiveCumulativeRewardWhenStaked;
        uint160 totalSecondsInsideFromStakeTime = incentiveTotalSecondsInsideX128 - incentiveTotalSecondsInsideX128WhenStaked;

        // this operation is safe, as the difference cannot be greater than 1/stake.liquidity
        accumulatedSeconds = (positionSecondsPerLiquidityInsideX128 - stakeInitialSecondsPerLiquidityInsideX128) * liquidity;

        uint128 rewardSoFar = uint128(FullMath.mulDiv(totalRewardFromStakeTime, accumulatedSeconds, totalSecondsInsideFromStakeTime));

        reward = rewardSoFar > stakeClaimedReward ? (stakeClaimedReward - rewardSoFar) : 0;
    }
}

/*
    reward = distributed rewards of incentive from stake time to last update date of incentive
    seconds_of_stake = secondsInside value that is calculated by taking the difference between last value and the value at the stake time.
    total_seconds_of_incentive = total secondsInside value for every token that is staked between last value and the value that is recorded on stake

        reward x seconds_of_stake
        --------------------------
        total_seconds_of_incentive

*/
