// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IUbeswapV3Farming.sol';
import './libraries/IncentiveId.sol';
import './libraries/RewardMath.sol';
import './libraries/NFTPositionInfo.sol';
import './libraries/TransferHelperExtended.sol';
import './OffChainIncentiveCalculations.sol';

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';

/// @title Off-chain assisted Ubeswap V3 Farming Protocol
contract UbeswapV3Farming is IUbeswapV3Farming, AccessControl, OffChainIncentiveCalculations, Multicall {
    bytes32 public constant INCENTIVE_MANAGER_ROLE = keccak256('INCENTIVE_MANAGER_ROLE');
    bytes32 public constant INCENTIVE_UPDATER_ROLE = keccak256('INCENTIVE_UPDATER_ROLE');

    /// @notice Represents a staking incentive
    struct Incentive {
        uint128 cumulativeReward;
        uint32 currentPeriodId;
        uint32 lastUpdateTime; // last update date for cumulativeReward and IncentiveDistributionInfo
        uint32 endTime; // this will be updated when new reward added
        uint32 numberOfStakes;
    }

    struct IncentivePeriod {
        uint128 rewardPerSecond;
        uint32 startTime;
        uint32 endTime;
    }

    struct IncentiveDistributionInfo {
        uint160 totalSecondsInsideX128; // total liquidity-seconds that are staked in the incentive. (this value is calculated off-chain)
        uint96 cumulativeRewardMicroEth; // accumulated reward distribution on specific time (unit: microether)
    }

    struct IncentiveRewardInfo {
        uint128 claimedRewards;
        uint128 addedRewards;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint128 liquidity;
        uint128 claimedReward;
        // ------
        uint160 initialSecondsPerLiquidityInsideX128;
        uint32 stakeTime;
        uint32 incentiveLastUpdateTimeOnStake;
    }

    /// @inheritdoc IUbeswapV3Farming
    IUniswapV3Factory public immutable override factory;
    /// @inheritdoc IUbeswapV3Farming
    INonfungiblePositionManager public immutable override nonfungiblePositionManager;

    /// @inheritdoc IUbeswapV3Farming
    uint256 public immutable override maxIncentiveStartLeadTime;
    /// @inheritdoc IUbeswapV3Farming
    uint256 public immutable override maxIncentivePeriodDuration;
    /// @inheritdoc IUbeswapV3Farming
    uint256 public immutable override minIncentiveEndLagTime;
    /// @inheritdoc IUbeswapV3Farming
    uint256 public immutable override maxLockTime;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;

    /// @dev incentivePeriods[incentiveId][periodId] => IncentivePeriod
    mapping(bytes32 => mapping(uint32 => IncentivePeriod)) public override incentivePeriods;

    /// @dev incentiveId => lastUpdateTime => totalSecondsInsideX128
    mapping(bytes32 => mapping(uint32 => IncentiveDistributionInfo)) public override incentiveDistributionInfos;

    /// @dev incentiveId => rewardInfo
    mapping(bytes32 => IncentiveRewardInfo) public override incentiveRewardInfos;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev stakes[incentiveId][tokenId] => Stake
    mapping(bytes32 => mapping(uint256 => Stake)) public override stakes;

    /// @param _factory the Uniswap V3 compatible factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentivePeriodDuration the max amount of seconds into the future the incentive startTime can be set
    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentivePeriodDuration,
        uint256 _minIncentiveEndLagTime,
        uint256 _maxLockTime
    ) {
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentivePeriodDuration = _maxIncentivePeriodDuration;
        minIncentiveEndLagTime = _minIncentiveEndLagTime;
        maxLockTime = _maxLockTime;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(INCENTIVE_MANAGER_ROLE, msg.sender);
        _setupRole(INCENTIVE_UPDATER_ROLE, msg.sender);
    }

    /// @inheritdoc IUbeswapV3Farming
    function createIncentive(IncentiveKey memory key, uint32 duration, uint128 reward) external override {
        require(hasRole(INCENTIVE_MANAGER_ROLE, msg.sender));
        uint32 endTime = key.startTime + duration;
        require(reward > 0, 'reward must be positive');
        require(duration > 0, 'duration must be positive');
        require(block.timestamp <= key.startTime, 'start time must be now or in the future');
        require(key.startTime - block.timestamp <= maxIncentiveStartLeadTime, 'start time too far into future');
        require(duration <= maxIncentivePeriodDuration, 'incentive duration is too long');
        require(key.lockTime <= maxLockTime, 'wrong lock time');
        require(key.maxTickLower > key.minTickLower, 'wrong tickLower range');
        require(key.maxTickUpper > key.minTickUpper, 'wrong tickUpper range');

        bytes32 incentiveId = IncentiveId.compute(key);

        require(incentives[incentiveId].endTime == 0, 'incentive already exists');

        incentives[incentiveId].endTime = endTime;
        incentivePeriods[incentiveId][0] = IncentivePeriod({
            rewardPerSecond: reward / duration,
            startTime: key.startTime,
            endTime: endTime
        });

        incentiveRewardInfos[incentiveId].addedRewards = reward;

        TransferHelperExtended.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward);

        emit IncentiveCreated(
            incentiveId,
            key.rewardToken,
            key.pool,
            key.startTime,
            key.lockTime,
            key.minimumTickRange,
            key.maxTickLower,
            key.minTickLower,
            key.maxTickUpper,
            key.minTickUpper
        );
        emit IncentiveExtended(incentiveId, 0, duration, reward);
    }

    /// @inheritdoc IUbeswapV3Farming
    function extendIncentive(
        IncentiveKey memory key,
        uint32 newPeriodId,
        uint32 duration,
        uint128 reward
    ) external override {
        require(hasRole(INCENTIVE_MANAGER_ROLE, msg.sender));
        require(reward > 0, 'reward must be positive');
        require(duration > 0, 'duration must be positive');
        require(duration <= maxIncentivePeriodDuration, 'incentive duration is too long');

        bytes32 incentiveId = IncentiveId.compute(key);
        uint32 currentEndTime = incentives[incentiveId].endTime;
        require(currentEndTime > 0, 'incentive not exists');
        require(incentives[incentiveId].currentPeriodId == (newPeriodId - 1), 'wrong period id');

        uint32 newEndTime = currentEndTime + duration;
        incentivePeriods[incentiveId][newPeriodId] = IncentivePeriod({
            rewardPerSecond: reward / duration,
            startTime: currentEndTime,
            endTime: newEndTime
        });

        incentiveRewardInfos[incentiveId].addedRewards += reward;

        TransferHelperExtended.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward);

        emit IncentiveExtended(incentiveId, newPeriodId, duration, reward);
    }

    /// @inheritdoc IUbeswapV3Farming
    function updateIncentiveDistributionInfo(
        IncentiveKey memory key,
        uint160 totalSecondsInsideX128,
        uint32 timestamp
    ) external override {
        require(hasRole(INCENTIVE_UPDATER_ROLE, msg.sender));
        require(timestamp < block.timestamp, 'time must be before now');
        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive memory currIncentive = incentives[incentiveId];
        require(timestamp > currIncentive.lastUpdateTime, 'time must be after lastUpdateTime');
        IncentiveDistributionInfo memory currInfo = incentiveDistributionInfos[incentiveId][
            currIncentive.lastUpdateTime
        ];
        require(totalSecondsInsideX128 >= currInfo.totalSecondsInsideX128, 'totalSecondsInsideX128 must increase');
        IncentivePeriod memory currPeriod = incentivePeriods[incentiveId][currIncentive.currentPeriodId];
        uint128 accumulatedReward = 0;
        if (timestamp > currIncentive.endTime) {
            accumulatedReward = (currIncentive.endTime - currIncentive.lastUpdateTime) * currPeriod.rewardPerSecond;
            IncentivePeriod memory nextPeriod = incentivePeriods[incentiveId][currIncentive.currentPeriodId + 1];
            require(nextPeriod.rewardPerSecond > 0, 'next period not exists');
            accumulatedReward += (timestamp - currIncentive.endTime) * nextPeriod.rewardPerSecond;
            currIncentive.currentPeriodId += 1;
            currIncentive.endTime = nextPeriod.endTime;
        } else {
            accumulatedReward = (timestamp - currIncentive.lastUpdateTime) * currPeriod.rewardPerSecond;
        }

        // if totalSecondsInsideX128 is not increased we dont distribute reward
        if (currInfo.totalSecondsInsideX128 != totalSecondsInsideX128) {
            currIncentive.cumulativeReward += accumulatedReward;
        }
        currIncentive.lastUpdateTime = timestamp;
        incentives[incentiveId] = currIncentive;

        incentiveDistributionInfos[incentiveId][timestamp] = IncentiveDistributionInfo({
            totalSecondsInsideX128: totalSecondsInsideX128,
            cumulativeRewardMicroEth: uint96(currIncentive.cumulativeReward / 10 ** 6)
        });

        emit IncentiveUpdated(
            incentiveId,
            timestamp,
            totalSecondsInsideX128,
            currIncentive.cumulativeReward,
            currIncentive.currentPeriodId
        );
    }

    /// @inheritdoc IUbeswapV3Farming
    function endIncentive(IncentiveKey memory key) external override returns (uint128 refund) {
        require(hasRole(INCENTIVE_MANAGER_ROLE, msg.sender));
        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        require(
            incentive.endTime > 0 && block.timestamp >= (incentive.endTime + minIncentiveEndLagTime),
            'cannot end incentive before end time'
        );
        require(incentive.numberOfStakes == 0, 'cannot end incentive while deposits are staked');

        IncentiveRewardInfo memory rewardInfo = incentiveRewardInfos[incentiveId];
        require(rewardInfo.addedRewards > rewardInfo.claimedRewards, 'no refund available');

        refund = rewardInfo.addedRewards - rewardInfo.claimedRewards;

        delete incentives[incentiveId];
        delete incentiveRewardInfos[incentiveId];

        TransferHelperExtended.safeTransfer(address(key.rewardToken), msg.sender, refund);

        emit IncentiveEnded(incentiveId, refund);
    }

    /// @notice Upon receiving a Ubeswap V3 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(msg.sender == address(nonfungiblePositionManager), 'not a univ3 nft');

        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager.positions(tokenId);

        deposits[tokenId] = Deposit({ owner: from, numberOfStakes: 0, tickLower: tickLower, tickUpper: tickUpper });
        emit DepositTransferred(tokenId, address(0), from);

        if (data.length > 0) {
            if (data.length == 160) {
                _stakeToken(abi.decode(data, (IncentiveKey)), tokenId);
            } else {
                IncentiveKey[] memory keys = abi.decode(data, (IncentiveKey[]));
                for (uint256 i = 0; i < keys.length; i++) {
                    _stakeToken(keys[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IUbeswapV3Farming
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(0), 'invalid transfer recipient');
        address owner = deposits[tokenId].owner;
        require(owner == msg.sender, 'can only be called by deposit owner');
        deposits[tokenId].owner = to;
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IUbeswapV3Farming
    function collectFee(
        INonfungiblePositionManager.CollectParams calldata params
    ) external payable override returns (uint256 amount0, uint256 amount1) {
        address owner = deposits[params.tokenId].owner;
        require(owner == msg.sender, 'can only be called by deposit owner');
        (amount0, amount1) = nonfungiblePositionManager.collect{ value: msg.value }(params);
        emit FeeCollected(msg.sender, params.tokenId, params.recipient, params.amount0Max, params.amount1Max);
    }

    /// @inheritdoc IUbeswapV3Farming
    function withdrawToken(uint256 tokenId, address to, bytes memory data) external override {
        require(to != address(this), 'cannot withdraw to staker');
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'cannot withdraw token while staked');
        require(deposit.owner == msg.sender, 'only owner can withdraw token');

        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    /// @inheritdoc IUbeswapV3Farming
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        require(deposits[tokenId].owner == msg.sender, 'only owner can stake token');

        _stakeToken(key, tokenId);
    }

    /// @inheritdoc IUbeswapV3Farming
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        bytes32 incentiveId = IncentiveId.compute(key);
        Deposit memory deposit = deposits[tokenId];
        Incentive memory incentive = incentives[incentiveId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        if (block.timestamp < incentive.endTime) {
            require(deposit.owner == msg.sender, 'only owner can withdraw token before incentive end time');
        }

        if (key.lockTime > 0) {
            require(key.lockTime < (block.timestamp - stakes[incentiveId][tokenId].stakeTime), 'token locked');
        }

        uint160 accumulatedSeconds = _collectReward(key, tokenId, deposit.tickLower, deposit.tickUpper);

        _removeStakedToken(incentiveId, tokenId, incentive.numberOfStakes, accumulatedSeconds);

        deposits[tokenId].numberOfStakes--;
        incentives[incentiveId].numberOfStakes--;

        delete stakes[incentiveId][tokenId];

        emit TokenUnstaked(tokenId, incentiveId);
    }

    /// @inheritdoc IUbeswapV3Farming
    function collectReward(IncentiveKey memory key, uint256 tokenId) external override {
        Deposit memory deposit = deposits[tokenId];
        require(deposit.owner == msg.sender, 'only owner can stake token');

        _collectReward(key, tokenId, deposit.tickLower, deposit.tickUpper);
    }

    /// @inheritdoc IUbeswapV3Farming
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId) external view override returns (uint128 reward) {
        bytes32 incentiveId = IncentiveId.compute(key);

        Stake memory stake = stakes[incentiveId][tokenId];
        require(stake.liquidity > 0, 'stake does not exist');

        Deposit memory deposit = deposits[tokenId];
        Incentive memory incentive = incentives[incentiveId];

        (, uint160 secondsPerLiquidityInsideX128, ) = key.pool.snapshotCumulativesInside(
            deposit.tickLower,
            deposit.tickUpper
        );

        IncentiveDistributionInfo memory incentiveInfoWhenStaked = incentiveDistributionInfos[incentiveId][
            stake.incentiveLastUpdateTimeOnStake
        ];

        (reward, ) = RewardMath.computeRewardAmount(
            incentive.cumulativeReward, // incentiveCumulativeReward
            uint128(incentiveInfoWhenStaked.cumulativeRewardMicroEth) * 10 ** 6, // incentiveCumulativeRewardWhenStaked
            incentiveDistributionInfos[incentiveId][incentive.lastUpdateTime].totalSecondsInsideX128, // incentiveTotalSecondsInsideX128
            incentiveInfoWhenStaked.totalSecondsInsideX128, // incentiveTotalSecondsInsideX128WhenStaked
            stake.initialSecondsPerLiquidityInsideX128, // stakeInitialSecondsPerLiquidityInsideX128
            secondsPerLiquidityInsideX128, // positionSecondsPerLiquidityInsideX128
            stake.liquidity, // liquidity
            stake.stakeTime, // stakeTime
            incentive.lastUpdateTime, // incentiveLastUpdateTime
            stake.claimedReward // stakeClaimedReward
        );
    }

    function _collectReward(
        IncentiveKey memory key,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper
    ) private returns (uint160) {
        bytes32 incentiveId = IncentiveId.compute(key);

        Stake memory stake = stakes[incentiveId][tokenId];
        require(stake.liquidity > 0, 'stake does not exist');

        Incentive memory incentive = incentives[incentiveId];

        (, uint160 secondsPerLiquidityInsideX128, ) = key.pool.snapshotCumulativesInside(tickLower, tickUpper);

        IncentiveDistributionInfo memory incentiveInfoWhenStaked = incentiveDistributionInfos[incentiveId][
            stake.incentiveLastUpdateTimeOnStake
        ];

        (uint128 reward, uint160 accumulatedSeconds) = RewardMath.computeRewardAmount(
            incentive.cumulativeReward, // incentiveCumulativeReward
            uint128(incentiveInfoWhenStaked.cumulativeRewardMicroEth) * 10 ** 6, // incentiveCumulativeRewardWhenStaked
            incentiveDistributionInfos[incentiveId][incentive.lastUpdateTime].totalSecondsInsideX128, // incentiveTotalSecondsInsideX128
            incentiveInfoWhenStaked.totalSecondsInsideX128, // incentiveTotalSecondsInsideX128WhenStaked
            stake.initialSecondsPerLiquidityInsideX128, // stakeInitialSecondsPerLiquidityInsideX128
            secondsPerLiquidityInsideX128, // positionSecondsPerLiquidityInsideX128
            stake.liquidity, // liquidity
            stake.stakeTime, // stakeTime
            incentive.lastUpdateTime, // incentiveLastUpdateTime
            stake.claimedReward // stakeClaimedReward
        );

        stakes[incentiveId][tokenId].claimedReward += reward;

        incentiveRewardInfos[incentiveId].claimedRewards += reward;

        TransferHelperExtended.safeTransferFrom(address(key.rewardToken), address(this), msg.sender, reward);

        emit RewardCollected(tokenId, incentiveId, msg.sender, reward, accumulatedSeconds);

        return accumulatedSeconds;
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId) private {
        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive memory incentive = incentives[incentiveId];

        require(incentive.endTime > 0, 'non-existent incentive');
        require(block.timestamp >= key.startTime && block.timestamp < incentive.endTime, 'incentive not active');
        require(stakes[incentiveId][tokenId].liquidity == 0, 'token already staked');

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) = NFTPositionInfo.getPositionInfo(
            factory,
            nonfungiblePositionManager,
            tokenId
        );

        require(pool == key.pool, 'token pool is not the incentive pool');
        require(key.minimumTickRange <= (tickUpper - tickLower), 'wrong tick range');
        require(key.maxTickLower >= tickLower && key.minTickLower <= tickLower, 'wrong tickLower');
        require(key.maxTickUpper >= tickUpper && key.minTickUpper <= tickUpper, 'wrong tickUpper');
        require(liquidity > 0, 'cannot stake token with 0 liquidity');

        _addStakedToken(incentiveId, tokenId, incentive.numberOfStakes);

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(tickLower, tickUpper);

        stakes[incentiveId][tokenId] = Stake({
            liquidity: liquidity,
            claimedReward: 0,
            initialSecondsPerLiquidityInsideX128: secondsPerLiquidityInsideX128,
            stakeTime: uint32(block.timestamp),
            incentiveLastUpdateTimeOnStake: incentive.lastUpdateTime
        });

        emit TokenStaked(tokenId, incentiveId, liquidity);
    }

    function _getStakeInfoForOffChainCalc(
        bytes32 incentiveId,
        uint256 tokenId
    )
        internal
        view
        override
        returns (uint160 initialSecondsPerLiquidityInsideX128, uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        initialSecondsPerLiquidityInsideX128 = stakes[incentiveId][tokenId].initialSecondsPerLiquidityInsideX128;
        liquidity = stakes[incentiveId][tokenId].liquidity;
        Deposit memory deposit = deposits[tokenId];
        tickLower = deposit.tickLower;
        tickUpper = deposit.tickUpper;
    }
}
