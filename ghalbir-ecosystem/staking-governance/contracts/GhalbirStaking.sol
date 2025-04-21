// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title GhalbirStaking
 * @dev Contract for staking GBR tokens and earning rewards
 */
contract GhalbirStaking is Ownable, ReentrancyGuard, Pausable {
    // Token being staked
    IERC20 public gbrToken;
    
    // Staking parameters
    uint256 public minimumStake = 100 * 10**18; // 100 GBR
    uint256 public baseRewardRate = 5; // 5% base APY
    uint256 public maxRewardRate = 10; // 10% max APY
    uint256 public unbondingPeriod = 14 days;
    uint256 public rewardDistributionInterval = 1 days;
    
    // Staking data structures
    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastUpdateTime;
    }
    
    struct UnbondingInfo {
        uint256 amount;
        uint256 completionTime;
    }
    
    // Mapping from staker address to their stake info
    mapping(address => StakeInfo) public stakes;
    
    // Mapping from staker address to their unbonding info
    mapping(address => UnbondingInfo[]) public unbondings;
    
    // Total staked amount
    uint256 public totalStaked;
    
    // Last reward calculation timestamp
    uint256 public lastRewardCalculation;
    
    // Accumulated rewards per share, scaled by 1e12
    uint256 public accRewardPerShare;
    
    // Events
    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event UnbondingCompleted(address indexed staker, uint256 amount);
    event RewardsClaimed(address indexed staker, uint256 amount);
    event RewardsCompounded(address indexed staker, uint256 amount);
    event RewardRateUpdated(uint256 newBaseRate, uint256 newMaxRate);
    event UnbondingPeriodUpdated(uint256 newPeriod);
    event MinimumStakeUpdated(uint256 newMinimum);
    
    /**
     * @dev Constructor
     * @param _gbrToken Address of the GBR token contract
     */
    constructor(address _gbrToken) {
        require(_gbrToken != address(0), "GhalbirStaking: token address cannot be zero");
        gbrToken = IERC20(_gbrToken);
        lastRewardCalculation = block.timestamp;
    }
    
    /**
     * @dev Updates reward variables
     */
    function updateRewardVariables() public {
        if (block.timestamp <= lastRewardCalculation) {
            return;
        }
        
        if (totalStaked == 0) {
            lastRewardCalculation = block.timestamp;
            return;
        }
        
        // Calculate reward for the period
        uint256 timeElapsed = block.timestamp - lastRewardCalculation;
        
        // Calculate current reward rate based on participation
        uint256 currentRewardRate = calculateDynamicRewardRate();
        
        // Calculate rewards generated in this period
        uint256 reward = (totalStaked * currentRewardRate * timeElapsed) / (365 days * 100);
        
        // Update accumulated reward per share
        accRewardPerShare = accRewardPerShare + ((reward * 1e12) / totalStaked);
        lastRewardCalculation = block.timestamp;
    }
    
    /**
     * @dev Calculates the dynamic reward rate based on participation
     * @return The current reward rate
     */
    function calculateDynamicRewardRate() public view returns (uint256) {
        // Get total supply of GBR
        uint256 totalSupply = gbrToken.totalSupply();
        
        // Calculate participation rate (0-100)
        uint256 participationRate = (totalStaked * 100) / totalSupply;
        
        // Adjust rate based on participation (lower participation = higher rewards)
        // Formula: baseRate + (maxRate - baseRate) * (1 - participationRate/100)
        uint256 adjustedRate = baseRewardRate + 
                              ((maxRewardRate - baseRewardRate) * (100 - participationRate)) / 100;
        
        return adjustedRate;
    }
    
    /**
     * @dev Stakes GBR tokens
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount >= minimumStake, "GhalbirStaking: amount below minimum stake");
        
        // Update reward variables
        updateRewardVariables();
        
        // Calculate pending rewards before adding new stake
        uint256 pending = 0;
        if (stakes[msg.sender].amount > 0) {
            pending = (stakes[msg.sender].amount * accRewardPerShare) / 1e12 - stakes[msg.sender].rewardDebt;
            stakes[msg.sender].pendingRewards += pending;
        }
        
        // Transfer tokens from sender
        require(gbrToken.transferFrom(msg.sender, address(this), amount), "GhalbirStaking: transfer failed");
        
        // Update stake info
        stakes[msg.sender].amount += amount;
        stakes[msg.sender].lastUpdateTime = block.timestamp;
        stakes[msg.sender].rewardDebt = (stakes[msg.sender].amount * accRewardPerShare) / 1e12;
        
        // Update total staked
        totalStaked += amount;
        
        emit Staked(msg.sender, amount);
    }
    
    /**
     * @dev Initiates unstaking of GBR tokens
     * @param amount Amount of tokens to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        require(stakes[msg.sender].amount >= amount, "GhalbirStaking: insufficient staked amount");
        
        // Update reward variables
        updateRewardVariables();
        
        // Calculate pending rewards
        uint256 pending = (stakes[msg.sender].amount * accRewardPerShare) / 1e12 - stakes[msg.sender].rewardDebt;
        stakes[msg.sender].pendingRewards += pending;
        
        // Update stake info
        stakes[msg.sender].amount -= amount;
        stakes[msg.sender].rewardDebt = (stakes[msg.sender].amount * accRewardPerShare) / 1e12;
        
        // Update total staked
        totalStaked -= amount;
        
        // Create unbonding entry
        unbondings[msg.sender].push(UnbondingInfo({
            amount: amount,
            completionTime: block.timestamp + unbondingPeriod
        }));
        
        emit Unstaked(msg.sender, amount);
    }
    
    /**
     * @dev Completes the unbonding process and withdraws tokens
     * @param unbondingIndex Index of the unbonding entry to complete
     */
    function completeUnbonding(uint256 unbondingIndex) external nonReentrant {
        require(unbondingIndex < unbondings[msg.sender].length, "GhalbirStaking: invalid unbonding index");
        
        UnbondingInfo storage unbonding = unbondings[msg.sender][unbondingIndex];
        require(block.timestamp >= unbonding.completionTime, "GhalbirStaking: unbonding period not completed");
        
        uint256 amount = unbonding.amount;
        
        // Remove unbonding entry by replacing with the last one and popping
        unbondings[msg.sender][unbondingIndex] = unbondings[msg.sender][unbondings[msg.sender].length - 1];
        unbondings[msg.sender].pop();
        
        // Transfer tokens to user
        require(gbrToken.transfer(msg.sender, amount), "GhalbirStaking: transfer failed");
        
        emit UnbondingCompleted(msg.sender, amount);
    }
    
    /**
     * @dev Claims pending rewards
     */
    function claimRewards() external nonReentrant {
        // Update reward variables
        updateRewardVariables();
        
        // Calculate pending rewards
        uint256 pending = (stakes[msg.sender].amount * accRewardPerShare) / 1e12 - stakes[msg.sender].rewardDebt;
        uint256 totalPending = pending + stakes[msg.sender].pendingRewards;
        
        require(totalPending > 0, "GhalbirStaking: no rewards to claim");
        
        // Reset pending rewards
        stakes[msg.sender].pendingRewards = 0;
        stakes[msg.sender].rewardDebt = (stakes[msg.sender].amount * accRewardPerShare) / 1e12;
        
        // Transfer rewards to user
        require(gbrToken.transfer(msg.sender, totalPending), "GhalbirStaking: transfer failed");
        
        emit RewardsClaimed(msg.sender, totalPending);
    }
    
    /**
     * @dev Compounds pending rewards by adding them to the stake
     */
    function compoundRewards() external nonReentrant whenNotPaused {
        // Update reward variables
        updateRewardVariables();
        
        // Calculate pending rewards
        uint256 pending = (stakes[msg.sender].amount * accRewardPerShare) / 1e12 - stakes[msg.sender].rewardDebt;
        uint256 totalPending = pending + stakes[msg.sender].pendingRewards;
        
        require(totalPending > 0, "GhalbirStaking: no rewards to compound");
        
        // Reset pending rewards
        stakes[msg.sender].pendingRewards = 0;
        
        // Add rewards to stake
        stakes[msg.sender].amount += totalPending;
        stakes[msg.sender].rewardDebt = (stakes[msg.sender].amount * accRewardPerShare) / 1e12;
        
        // Update total staked
        totalStaked += totalPending;
        
        emit RewardsCompounded(msg.sender, totalPending);
    }
    
    /**
     * @dev Gets the staked amount for a user
     * @param staker Address of the staker
     * @return The staked amount
     */
    function getStakedAmount(address staker) external view returns (uint256) {
        return stakes[staker].amount;
    }
    
    /**
     * @dev Gets the pending rewards for a user
     * @param staker Address of the staker
     * @return The pending rewards
     */
    function getPendingRewards(address staker) external view returns (uint256) {
        if (totalStaked == 0) {
            return stakes[staker].pendingRewards;
        }
        
        // Calculate current accumulated reward per share
        uint256 currentAccRewardPerShare = accRewardPerShare;
        
        if (block.timestamp > lastRewardCalculation) {
            uint256 timeElapsed = block.timestamp - lastRewardCalculation;
            uint256 currentRewardRate = calculateDynamicRewardRate();
            uint256 reward = (totalStaked * currentRewardRate * timeElapsed) / (365 days * 100);
            currentAccRewardPerShare = accRewardPerShare + ((reward * 1e12) / totalStaked);
        }
        
        // Calculate pending rewards
        uint256 pending = (stakes[staker].amount * currentAccRewardPerShare) / 1e12 - stakes[staker].rewardDebt;
        return pending + stakes[staker].pendingRewards;
    }
    
    /**
     * @dev Gets the total staked amount
     * @return The total staked amount
     */
    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }
    
    /**
     * @dev Gets the unbonding amount for a user
     * @param staker Address of the staker
     * @return The total unbonding amount
     */
    function getUnbondingAmount(address staker) external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < unbondings[staker].length; i++) {
            total += unbondings[staker][i].amount;
        }
        return total;
    }
    
    /**
     * @dev Gets all unbonding entries for a user
     * @param staker Address of the staker
     * @return amounts Array of unbonding amounts
     * @return completionTimes Array of unbonding completion times
     */
    function getAllUnbondings(address staker) external view returns (uint256[] memory amounts, uint256[] memory completionTimes) {
        uint256 length = unbondings[staker].length;
        amounts = new uint256[](length);
        completionTimes = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            amounts[i] = unbondings[staker][i].amount;
            completionTimes[i] = unbondings[staker][i].completionTime;
        }
        
        return (amounts, completionTimes);
    }
    
    /**
     * @dev Updates the reward rate
     * @param newBaseRate New base reward rate
     * @param newMaxRate New maximum reward rate
     */
    function updateRewardRate(uint256 newBaseRate, uint256 newMaxRate) external onlyOwner {
        require(newBaseRate <= newMaxRate, "GhalbirStaking: base rate must be <= max rate");
        require(newMaxRate <= 50, "GhalbirStaking: max rate cannot exceed 50%");
        
        // Update reward variables before changing rates
        updateRewardVariables();
        
        baseRewardRate = newBaseRate;
        maxRewardRate = newMaxRate;
        
        emit RewardRateUpdated(newBaseRate, newMaxRate);
    }
    
    /**
     * @dev Updates the unbonding period
     * @param newPeriod New unbonding period in seconds
     */
    function updateUnbondingPeriod(uint256 newPeriod) external onlyOwner {
        require(newPeriod <= 30 days, "GhalbirStaking: unbonding period cannot exceed 30 days");
        unbondingPeriod = newPeriod;
        
        emit UnbondingPeriodUpdated(newPeriod);
    }
    
    /**
     * @dev Updates the minimum stake amount
     * @param newMinimum New minimum stake amount
     */
    function updateMinimumStake(uint256 newMinimum) external onlyOwner {
        minimumStake = newMinimum;
        
        emit MinimumStakeUpdated(newMinimum);
    }
    
    /**
     * @dev Pauses the contract
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpauses the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Recovers tokens accidentally sent to the contract
     * @param tokenAddress Address of the token to recover
     * @param amount Amount of tokens to recover
     */
    function recoverTokens(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(gbrToken), "GhalbirStaking: cannot recover staked tokens");
        IERC20(tokenAddress).transfer(owner(), amount);
    }
}
