// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title GhalbirYieldVault
 * @dev Yield-bearing vault for a single asset
 */
contract GhalbirYieldVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Token being stored in the vault
    IERC20 public token;
    
    // Strategy contract
    address public strategy;
    
    // Vault parameters
    uint256 public depositLimit;
    uint256 public performanceFee = 1000; // 10% (basis points)
    uint256 public withdrawalFee = 10; // 0.1% (basis points)
    uint256 public constant MAX_FEE = 3000; // 30% (basis points)
    
    // Fee recipient
    address public feeRecipient;
    
    // Total shares
    uint256 public totalShares;
    
    // Mapping of user address to their shares
    mapping(address => uint256) public shares;
    
    // Events
    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 amount, uint256 shares);
    event StrategyReported(uint256 gain, uint256 loss, uint256 debtPaid, uint256 totalDebt);
    event StrategyChanged(address indexed newStrategy);
    event PerformanceFeeChanged(uint256 newFee);
    event WithdrawalFeeChanged(uint256 newFee);
    event FeeRecipientChanged(address indexed newFeeRecipient);
    event DepositLimitChanged(uint256 newLimit);
    
    /**
     * @dev Constructor
     * @param _token Address of the token
     * @param _feeRecipient Address to receive fees
     * @param _depositLimit Maximum amount of tokens that can be deposited
     */
    constructor(address _token, address _feeRecipient, uint256 _depositLimit) {
        require(_token != address(0), "GhalbirYieldVault: token cannot be zero address");
        require(_feeRecipient != address(0), "GhalbirYieldVault: fee recipient cannot be zero address");
        
        token = IERC20(_token);
        feeRecipient = _feeRecipient;
        depositLimit = _depositLimit;
    }
    
    /**
     * @dev Deposits tokens into the vault
     * @param amount Amount of tokens to deposit
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "GhalbirYieldVault: amount must be greater than zero");
        
        // Check deposit limit
        uint256 totalAssets = totalAssets();
        require(totalAssets + amount <= depositLimit, "GhalbirYieldVault: deposit limit reached");
        
        // Calculate shares to mint
        uint256 sharesToMint;
        if (totalShares == 0) {
            sharesToMint = amount;
        } else {
            sharesToMint = (amount * totalShares) / totalAssets;
        }
        
        require(sharesToMint > 0, "GhalbirYieldVault: no shares to mint");
        
        // Update shares
        totalShares += sharesToMint;
        shares[msg.sender] += sharesToMint;
        
        // Transfer tokens from user to vault
        token.safeTransferFrom(msg.sender, address(this), amount);
        
        // Deposit to strategy if set
        if (strategy != address(0)) {
            token.safeTransfer(strategy, amount);
            IStrategy(strategy).deposit();
        }
        
        emit Deposit(msg.sender, amount, sharesToMint);
    }
    
    /**
     * @dev Withdraws tokens from the vault
     * @param shareAmount Amount of shares to withdraw
     */
    function withdraw(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "GhalbirYieldVault: share amount must be greater than zero");
        require(shares[msg.sender] >= shareAmount, "GhalbirYieldVault: insufficient shares");
        
        // Calculate amount to withdraw
        uint256 totalAssets = totalAssets();
        uint256 amountToWithdraw = (shareAmount * totalAssets) / totalShares;
        
        // Apply withdrawal fee
        uint256 feeAmount = (amountToWithdraw * withdrawalFee) / 10000;
        uint256 amountAfterFee = amountToWithdraw - feeAmount;
        
        // Update shares
        totalShares -= shareAmount;
        shares[msg.sender] -= shareAmount;
        
        // Withdraw from strategy if needed
        uint256 vaultBalance = token.balanceOf(address(this));
        if (amountToWithdraw > vaultBalance && strategy != address(0)) {
            uint256 amountNeeded = amountToWithdraw - vaultBalance;
            IStrategy(strategy).withdraw(amountNeeded);
        }
        
        // Transfer tokens to user
        token.safeTransfer(msg.sender, amountAfterFee);
        
        // Transfer fee to fee recipient
        if (feeAmount > 0) {
            token.safeTransfer(feeRecipient, feeAmount);
        }
        
        emit Withdraw(msg.sender, amountAfterFee, shareAmount);
    }
    
    /**
     * @dev Reports strategy performance
     * @param gain Amount of gain
     * @param loss Amount of loss
     * @param debtPayment Amount of debt paid
     * @return Amount of debt outstanding
     */
    function report(uint256 gain, uint256 loss, uint256 debtPayment) external returns (uint256) {
        require(msg.sender == strategy, "GhalbirYieldVault: not strategy");
        
        // Calculate performance fee
        uint256 feeAmount = (gain * performanceFee) / 10000;
        
        // Transfer fee to fee recipient
        if (feeAmount > 0) {
            token.safeTransferFrom(strategy, feeRecipient, feeAmount);
        }
        
        // Update total debt
        uint256 totalDebt = estimatedTotalAssets();
        
        emit StrategyReported(gain, loss, debtPayment, totalDebt);
        
        return totalDebt;
    }
    
    /**
     * @dev Sets a new strategy
     * @param _strategy Address of the new strategy
     */
    function setStrategy(address _strategy) external onlyOwner {
        require(_strategy != address(0), "GhalbirYieldVault: strategy cannot be zero address");
        
        // Withdraw all funds from current strategy
        if (strategy != address(0)) {
            IStrategy(strategy).withdraw(type(uint256).max);
        }
        
        // Set new strategy
        strategy = _strategy;
        
        // Deposit all funds to new strategy
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.safeTransfer(strategy, balance);
            IStrategy(strategy).deposit();
        }
        
        emit StrategyChanged(_strategy);
    }
    
    /**
     * @dev Sets the performance fee
     * @param _performanceFee New performance fee (basis points)
     */
    function setPerformanceFee(uint256 _performanceFee) external onlyOwner {
        require(_performanceFee <= MAX_FEE, "GhalbirYieldVault: fee too high");
        performanceFee = _performanceFee;
        emit PerformanceFeeChanged(_performanceFee);
    }
    
    /**
     * @dev Sets the withdrawal fee
     * @param _withdrawalFee New withdrawal fee (basis points)
     */
    function setWithdrawalFee(uint256 _withdrawalFee) external onlyOwner {
        require(_withdrawalFee <= MAX_FEE, "GhalbirYieldVault: fee too high");
        withdrawalFee = _withdrawalFee;
        emit WithdrawalFeeChanged(_withdrawalFee);
    }
    
    /**
     * @dev Sets the fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "GhalbirYieldVault: fee recipient cannot be zero address");
        feeRecipient = _feeRecipient;
        emit FeeRecipientChanged(_feeRecipient);
    }
    
    /**
     * @dev Sets the deposit limit
     * @param _depositLimit New deposit limit
     */
    function setDepositLimit(uint256 _depositLimit) external onlyOwner {
        depositLimit = _depositLimit;
        emit DepositLimitChanged(_depositLimit);
    }
    
    /**
     * @dev Gets the total assets in the vault
     * @return Total assets
     */
    function totalAssets() public view returns (uint256) {
        return token.balanceOf(address(this)) + estimatedStrategyAssets();
    }
    
    /**
     * @dev Gets the estimated assets in the strategy
     * @return Estimated strategy assets
     */
    function estimatedStrategyAssets() public view returns (uint256) {
        if (strategy == address(0)) {
            return 0;
        }
        return IStrategy(strategy).estimatedTotalAssets();
    }
    
    /**
     * @dev Gets the estimated total assets
     * @return Estimated total assets
     */
    function estimatedTotalAssets() public view returns (uint256) {
        return totalAssets();
    }
    
    /**
     * @dev Gets the price per share
     * @return Price per share
     */
    function getPricePerShare() public view returns (uint256) {
        if (totalShares == 0) {
            return 1e18;
        }
        return (totalAssets() * 1e18) / totalShares;
    }
    
    /**
     * @dev Gets the balance of a user
     * @param user Address of the user
     * @return User's balance
     */
    function balanceOf(address user) external view returns (uint256) {
        return shares[user];
    }
    
    /**
     * @dev Gets the total supply of shares
     * @return Total supply
     */
    function totalSupply() external view returns (uint256) {
        return totalShares;
    }
    
    /**
     * @dev Gets the available deposit limit
     * @return Available deposit limit
     */
    function availableDepositLimit() external view returns (uint256) {
        uint256 totalAssets = totalAssets();
        if (totalAssets >= depositLimit) {
            return 0;
        }
        return depositLimit - totalAssets;
    }
    
    /**
     * @dev Pauses the vault
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpauses the vault
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Recovers tokens accidentally sent to the vault
     * @param tokenAddress Address of the token to recover
     * @param amount Amount to recover
     */
    function recoverERC20(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(token), "GhalbirYieldVault: cannot recover vault token");
        IERC20(tokenAddress).safeTransfer(owner(), amount);
    }
}

/**
 * @title GhalbirStrategy
 * @dev Base strategy for yield generation
 */
contract GhalbirStrategy is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // Vault that owns this strategy
    address public vault;
    
    // Token being managed by this strategy
    IERC20 public want;
    
    // Whether the strategy is in emergency exit mode
    bool public emergencyExit;
    
    // Performance fee
    uint256 public performanceFee = 1000; // 10% (basis points)
    
    // Events
    event Harvested(uint256 profit, uint256 loss, uint256 debtPayment, uint256 debtOutstanding);
    event EmergencyExitEnabled();
    
    /**
     * @dev Constructor
     * @param _vault Address of the vault
     * @param _want Address of the token
     */
    constructor(address _vault, address _want) {
        require(_vault != address(0), "GhalbirStrategy: vault cannot be zero address");
        require(_want != address(0), "GhalbirStrategy: want cannot be zero address");
        
        vault = _vault;
        want = IERC20(_want);
    }
    
    /**
     * @dev Modifier to check if caller is the vault
     */
    modifier onlyVault() {
        require(msg.sender == vault, "GhalbirStrategy: caller not vault");
        _;
    }
    
    /**
     * @dev Deposits tokens into the strategy
     */
    function deposit() external onlyVault whenNotPaused {
        // Implement strategy-specific deposit logic
        _deposit();
    }
    
    /**
     * @dev Withdraws tokens from the strategy
     * @param _amount Amount to withdraw
     * @return Amount withdrawn
     */
    function withdraw(uint256 _amount) external onlyVault returns (uint256) {
        uint256 wantBalance = want.balanceOf(address(this));
        
        // If we have enough balance, just return it
        if (wantBalance >= _amount) {
            want.safeTransfer(vault, _amount);
            return _amount;
        }
        
        // Otherwise, withdraw what we need
        uint256 amountNeeded = _amount - wantBalance;
        
        // Implement strategy-specific withdrawal logic
        uint256 withdrawn = _withdraw(amountNeeded);
        
        // Calculate total amount to return
        uint256 totalWithdrawn = Math.min(withdrawn + wantBalance, _amount);
        
        // Transfer to vault
        want.safeTransfer(vault, totalWithdrawn);
        
        return totalWithdrawn;
    }
    
    /**
     * @dev Harvests profits and reports to vault
     */
    function harvest() external whenNotPaused {
        // Implement strategy-specific harvesting logic
        (uint256 profit, uint256 loss, uint256 debtPayment) = _harvest();
        
        // Report to vault
        uint256 debtOutstanding = IGhalbirYieldVault(vault).report(profit, loss, debtPayment);
        
        emit Harvested(profit, loss, debtPayment, debtOutstanding);
    }
    
    /**
     * @dev Sets emergency exit mode
     */
    function setEmergencyExit() external onlyOwner {
        emergencyExit = true;
        emit EmergencyExitEnabled();
    }
    
    /**
     * @dev Gets the estimated total assets
     * @return Estimated total assets
     */
    function estimatedTotalAssets() external view returns (uint256) {
        // Implement strategy-specific asset calculation
        return _estimatedTotalAssets();
    }
    
    /**
     * @dev Gets the expected return
     * @return Expected return
     */
    function expectedReturn() external view returns (uint256) {
        // Implement strategy-specific return calculation
        return _expectedReturn();
    }
    
    /**
     * @dev Checks if the strategy is active
     * @return True if active
     */
    function isActive() external view returns (bool) {
        return !emergencyExit && !paused();
    }
    
    /**
     * @dev Pauses the strategy
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpauses the strategy
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Recovers tokens accidentally sent to the strategy
     * @param tokenAddress Address of the token to recover
     * @param amount Amount to recover
     */
    function recoverERC20(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(want), "GhalbirStrategy: cannot recover want token");
        IERC20(tokenAddress).safeTransfer(owner(), amount);
    }
    
    /**
     * @dev Internal function for deposit logic
     */
    function _deposit() internal virtual {
        // To be implemented by specific strategies
    }
    
    /**
     * @dev Internal function for withdrawal logic
     * @param _amount Amount to withdraw
     * @return Amount withdrawn
     */
    function _withdraw(uint256 _amount) internal virtual returns (uint256) {
        // To be implemented by specific strategies
        return 0;
    }
    
    /**
     * @dev Internal function for harvest logic
     * @return profit Amount of profit
     * @return loss Amount of loss
     * @return debtPayment Amount of debt payment
     */
    function _harvest() internal virtual returns (uint256 profit, uint256 loss, uint256 debtPayment) {
        // To be implemented by specific strategies
        return (0, 0, 0);
    }
    
    /**
     * @dev Internal function for asset calculation
     * @return Estimated total assets
     */
    function _estimatedTotalAssets() internal view virtual returns (uint256) {
        // To be implemented by specific strategies
        return want.balanceOf(address(this));
    }
    
    /**
     * @dev Internal function for return calculation
     * @return Expected return
     */
    function _expectedReturn() internal view virtual returns (uint256) {
        // To be implemented by specific strategies
        return 0;
    }
}

/**
 * @title GhalbirLendingStrategy
 * @dev Strategy that deposits tokens into lending protocols
 */
contract GhalbirLendingStrategy is GhalbirStrategy {
    using SafeERC20 for IERC20;
    
    // Lending pool address
    address public lendingPool;
    
    // gToken address (interest-bearing token)
    address public gToken;
    
    /**
     * @dev Constructor
     * @param _vault Address of the vault
     * @param _want Address of the token
     * @param _lendingPool Address of the lending pool
     * @param _gToken Address of the gToken
     */
    constructor(
        address _vault,
        address _want,
        address _lendingPool,
        address _gToken
    ) GhalbirStrategy(_vault, _want) {
        require(_lendingPool != address(0), "GhalbirLendingStrategy: lending pool cannot be zero address");
        require(_gToken != address(0), "GhalbirLendingStrategy: gToken cannot be zero address");
        
        lendingPool = _lendingPool;
        gToken = _gToken;
        
        // Approve lending pool to spend want tokens
        want.safeApprove(lendingPool, type(uint256).max);
    }
    
    /**
     * @dev Internal function for deposit logic
     */
    function _deposit() internal override {
        uint256 wantBalance = want.balanceOf(address(this));
        if (wantBalance > 0) {
            IGhalbirLendingPool(lendingPool).deposit(address(want), wantBalance, address(this), 0);
        }
    }
    
    /**
     * @dev Internal function for withdrawal logic
     * @param _amount Amount to withdraw
     * @return Amount withdrawn
     */
    function _withdraw(uint256 _amount) internal override returns (uint256) {
        return IGhalbirLendingPool(lendingPool).withdraw(address(want), _amount, address(this));
    }
    
    /**
     * @dev Internal function for harvest logic
     * @return profit Amount of profit
     * @return loss Amount of loss
     * @return debtPayment Amount of debt payment
     */
    function _harvest() internal override returns (uint256 profit, uint256 loss, uint256 debtPayment) {
        // Calculate profit
        uint256 totalAssets = _estimatedTotalAssets();
        uint256 totalDebt = IGhalbirYieldVault(vault).estimatedTotalAssets();
        
        if (totalAssets > totalDebt) {
            profit = totalAssets - totalDebt;
            
            // Withdraw profit
            IGhalbirLendingPool(lendingPool).withdraw(address(want), profit, address(this));
            
            // Transfer profit to vault
            want.safeTransfer(vault, profit);
        } else if (totalAssets < totalDebt) {
            loss = totalDebt - totalAssets;
        }
        
        return (profit, loss, 0);
    }
    
    /**
     * @dev Internal function for asset calculation
     * @return Estimated total assets
     */
    function _estimatedTotalAssets() internal view override returns (uint256) {
        return want.balanceOf(address(this)) + IERC20(gToken).balanceOf(address(this));
    }
    
    /**
     * @dev Internal function for return calculation
     * @return Expected return
     */
    function _expectedReturn() internal view override returns (uint256) {
        uint256 gTokenBalance = IERC20(gToken).balanceOf(address(this));
        if (gTokenBalance == 0) {
            return 0;
        }
        
        // Estimate APY at 5%
        return (gTokenBalance * 5) / 100;
    }
}

/**
 * @title GhalbirYieldAggregator
 * @dev Factory for creating and managing yield vaults
 */
contract GhalbirYieldAggregator is Ownable {
    // Mapping of token address to vault address
    mapping(address => address) public vaults;
    
    // List of all vaults
    address[] public allVaults;
    
    // Events
    event VaultCreated(address indexed token, address indexed vault, address strategy);
    
    /**
     * @dev Creates a new vault for a token
     * @param token Address of the token
     * @param strategy Address of the strategy
     * @param feeRecipient Address to receive fees
     * @param depositLimit Maximum amount of tokens that can be deposited
     * @return vault Address of the created vault
     */
    function createVault(
        address token,
        address strategy,
        address feeRecipient,
        uint256 depositLimit
    ) external onlyOwner returns (address vault) {
        require(token != address(0), "GhalbirYieldAggregator: token cannot be zero address");
        require(strategy != address(0), "GhalbirYieldAggregator: strategy cannot be zero address");
        require(vaults[token] == address(0), "GhalbirYieldAggregator: vault already exists for token");
        
        // Create vault
        vault = address(new GhalbirYieldVault(token, feeRecipient, depositLimit));
        
        // Set strategy
        GhalbirYieldVault(vault).setStrategy(strategy);
        
        // Store vault
        vaults[token] = vault;
        allVaults.push(vault);
        
        emit VaultCreated(token, vault, strategy);
    }
    
    /**
     * @dev Gets all vaults
     * @return Array of vault addresses
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }
    
    /**
     * @dev Gets the number of vaults
     * @return Number of vaults
     */
    function getVaultsCount() external view returns (uint256) {
        return allVaults.length;
    }
}

/**
 * @title IGhalbirYieldVault
 * @dev Interface for the GhalbirYieldVault contract
 */
interface IGhalbirYieldVault {
    function report(uint256 gain, uint256 loss, uint256 debtPayment) external returns (uint256);
    function estimatedTotalAssets() external view returns (uint256);
}

/**
 * @title IGhalbirLendingPool
 * @dev Interface for the GhalbirLendingPool contract
 */
interface IGhalbirLendingPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @title IStrategy
 * @dev Interface for the Strategy contract
 */
interface IStrategy {
    function deposit() external;
    function withdraw(uint256 amount) external returns (uint256);
    function estimatedTotalAssets() external view returns (uint256);
}
