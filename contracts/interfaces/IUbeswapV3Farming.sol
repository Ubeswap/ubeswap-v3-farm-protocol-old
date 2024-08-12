// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol';
import './IOffChainIncentiveCalculations.sol';

/// @title Ubeswap V3 Farming Interface
/// @notice Allows staking V3 nonfungible liquidity tokens in exchange for reward tokens
interface IUbeswapV3Farming is IERC721Receiver, IOffChainIncentiveCalculations, IMulticall {
    /// @param rewardToken The token being distributed as a reward
    /// @param pool The Uniswap V3 compatible pool
    /// @param startTime The time when the incentive program begins
    struct IncentiveKey {
        IERC20Minimal rewardToken;
        IUniswapV3Pool pool;
        uint32 startTime;
        uint32 lockTime;
        int24 minimumTickRange;
        int24 maxTickLower;
        int24 minTickLower;
        int24 maxTickUpper;
        int24 minTickUpper;
    }

    /// @notice The Uniswap V3 compatible Factory
    function factory() external view returns (IUniswapV3Factory);

    /// @notice The nonfungible position manager with which this staking contract is compatible
    function nonfungiblePositionManager() external view returns (INonfungiblePositionManager);

    /// @notice The max amount of seconds into the future the incentive startTime can be set
    function maxIncentiveStartLeadTime() external view returns (uint256);

    /// @notice The max duration of an incentive in seconds
    function maxIncentivePeriodDuration() external view returns (uint256);

    /// @notice The min amount of seconds that an incentive can be ended after endTime
    function minIncentiveEndLagTime() external view returns (uint256);

    /// @notice The max duration oc lock time that can be given to an incentive
    function maxLockTime() external view returns (uint256);

    /// @notice Represents a staking incentive
    /// @param incentiveId The ID of the incentive computed from its parameters
    /// @return cumulativeReward The amount of reward distributed until last update time
    /// @return currentPeriodId current reward distribution period id
    /// @return lastUpdateTime time of last update of cumulativeReward and IncentiveDistributionInfo
    /// @return endTime End time of incentive
    /// @return numberOfStakes Number of tokens that are staked on the incentive
    function incentives(bytes32 incentiveId)
        external
        view
        returns (
            uint128 cumulativeReward,
            uint32 currentPeriodId,
            uint32 lastUpdateTime,
            uint32 endTime,
            uint32 numberOfStakes
        );

    /// @notice 
    function incentivePeriods(bytes32 incentiveId, uint32 periodId) external view returns (
        uint128 rewardPerSecond,
        uint32 startTime,
        uint32 endTime
    );

    /// @notice 
    function incentiveDistributionInfos(bytes32 incentiveId, uint32 lastUpdateTime) external view returns (
        uint160 totalSecondsInsideX128,
        uint96 cumulativeRewardMicroEth
    );

    /// @notice 
    function incentiveRewardInfos(bytes32 incentiveId) external view returns (
        uint128 claimedRewards,
        uint128 addedRewards
    );

    /// @notice Returns information about a deposited NFT
    /// @return owner The owner of the deposited NFT
    /// @return numberOfStakes Counter of how many incentives for which the liquidity is staked
    /// @return tickLower The lower tick of the range
    /// @return tickUpper The upper tick of the range
    function deposits(uint256 tokenId)
        external
        view
        returns (
            address owner,
            uint48 numberOfStakes,
            int24 tickLower,
            int24 tickUpper
        );

    /// @notice Returns information about a staked liquidity NFT
    /// @param incentiveId The ID of the incentive for which the token is staked
    /// @param tokenId The ID of the staked token
    function stakes(bytes32 incentiveId, uint256 tokenId)
        external
        view
        returns (
            uint128 liquidity,
            uint128 claimedReward,
            uint160 initialSecondsPerLiquidityInsideX128,
            uint32 stakeTime,
            uint32 incentiveLastUpdateTimeOnStake
        );

    /// @notice Creates a new liquidity mining incentive program
    /// @param key Details of the incentive to create
    /// @param duration The amount of seconds for the first period
    /// @param reward The amount of reward tokens to be distributed on the first period
    function createIncentive(IncentiveKey memory key, uint32 duration, uint128 reward) external;

    /// @notice Creates a new period for the incentive
    /// @param key Details of the incentive to extend
    /// @param newPeriodId the id for the new period. It should be one more from the previous period. This is taken for security
    /// @param duration The amount of seconds for the new period
    /// @param reward The amount of reward tokens to be distributed on the new period
    function extendIncentive(IncentiveKey memory key, uint32 newPeriodId, uint32 duration, uint128 reward) external;

    /// @notice Update function for total liqudity seconds that is calculated off-chain
    /// @param key Details of the incentive to create
    /// @param totalSecondsInsideX128 total liquidity-seconds
    /// @param timestamp The timestamp of the block that the calculation is done on
    function updateIncentiveDistributionInfo(IncentiveKey memory key, uint160 totalSecondsInsideX128, uint32 timestamp) external;

    /// @notice Ends an incentive after the incentive end time has passed and all stakes have been withdrawn
    /// @param key Details of the incentive to end
    /// @return refund The remaining reward tokens when the incentive is ended
    function endIncentive(IncentiveKey memory key) external returns (uint128 refund);

    /// @notice Transfers ownership of a deposit from the sender to the given recipient
    /// @param tokenId The ID of the token (and the deposit) to transfer
    /// @param to The new owner of the deposit
    function transferDeposit(uint256 tokenId, address to) external;

    /// @notice
    function collectFee(INonfungiblePositionManager.CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Withdraws a Ubeswap V3 LP token `tokenId` from this contract to the recipient `to`
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param to The address where the LP token will be sent
    /// @param data An optional data array that will be passed along to the `to` address via the NFT safeTransferFrom
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external;

    /// @notice Stakes a Ubeswap V3 LP token
    /// @param key The key of the incentive for which to stake the NFT
    /// @param tokenId The ID of the token to stake
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external;

    /// @notice Unstakes a Ubeswap V3 LP token
    /// @param key The key of the incentive for which to unstake the NFT
    /// @param tokenId The ID of the token to unstake
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external;

    /// @notice Transfers the rewards that are accumulated for the token in the incentive
    /// @param key The key of the incentive for which to unstake the NFT
    /// @param tokenId The ID of the token that has rewards
    function collectReward(IncentiveKey memory key, uint256 tokenId) external;

    /// @notice Calculates the reward amount that will be received for the given stake
    /// @param key The key of the incentive
    /// @param tokenId The ID of the token
    /// @return reward The reward accrued to the NFT for the given incentive thus far
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId)
        external
        view
        returns (uint128 reward);

    /// @notice Event emitted when a liquidity mining incentive has been created
    /// @param rewardToken The token being distributed as a reward
    /// @param pool The Uniswap V3 compatible pool
    /// @param startTime The time when the incentive program begins
    /// @param initialDuration The duration of the first period
    /// @param initialReward The amount of reward tokens to be distributed in the first period
    event IncentiveCreated(
        bytes32 indexed incentiveId,
        IERC20Minimal indexed rewardToken,
        IUniswapV3Pool indexed pool,
        uint32 startTime,
        uint32 initialDuration,
        uint128 initialReward
    );

    /// @notice
    event IncentiveExtended(bytes32 indexed incentiveId, uint32 newPeriodId, uint32 duration, uint128 reward);

    /// @notice
    event IncentiveUpdated(bytes32 indexed incentiveId, uint32 timestamp, uint160 totalSecondsInsideX128, uint128 newCumulativeReward, uint32 newPeriodId);

    /// @notice Event that can be emitted when a liquidity mining incentive has ended
    /// @param incentiveId The incentive which is ending
    /// @param refund The amount of reward tokens refunded
    event IncentiveEnded(bytes32 indexed incentiveId, uint128 refund);

    /// @notice Emitted when ownership of a deposit changes
    /// @param tokenId The ID of the deposit (and token) that is being transferred
    /// @param oldOwner The owner before the deposit was transferred
    /// @param newOwner The owner after the deposit was transferred
    event DepositTransferred(uint256 indexed tokenId, address indexed oldOwner, address indexed newOwner);

    /// @notice Event emitted when a Ubeswap V3 LP token has been staked
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param liquidity The amount of liquidity staked
    /// @param incentiveId The incentive in which the token is staking
    event TokenStaked(uint256 indexed tokenId, bytes32 indexed incentiveId, uint128 liquidity);

    /// @notice Event emitted when a Ubeswap V3 LP token has been unstaked
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param incentiveId The incentive in which the token is staking
    event TokenUnstaked(uint256 indexed tokenId, bytes32 indexed incentiveId);

    /// @notice Event emitted when a reward collected for an incentive
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param incentiveId The incentive in which the token is staking
    /// @param to The address where claimed rewards were sent to
    /// @param reward The amount of reward tokens claimed
    /// @param accumulatedSeconds The liquidity-seconds that is accumulated for the token from time of stake
    event RewardCollected(uint256 indexed tokenId, bytes32 indexed incentiveId, address indexed to, uint256 reward, uint160 accumulatedSeconds);

    /// @notice Event emitted when a fee collected from a pool
    /// @param owner Owner account of the deposited token when the fee collected
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param recipient Fee recepient
    event FeeCollected(
        address indexed owner,
        uint256 indexed tokenId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    );
}
