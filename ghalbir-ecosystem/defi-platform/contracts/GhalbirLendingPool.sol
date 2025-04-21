// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title GhalbirLendingPool
 * @dev Main contract for the Ghalbir Lending Protocol
 */
contract GhalbirLendingPool is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Struct to store reserve data
    struct ReserveData {
        // Configuration data
        uint256 configuration;
        // Liquidity index (for interest accrual)
        uint128 liquidityIndex;
        // Variable borrow index (for interest accrual)
        uint128 variableBorrowIndex;
        // Current liquidity rate (APY for lenders)
        uint128 currentLiquidityRate;
        // Current variable borrow rate (APY for borrowers)
        uint128 currentVariableBorrowRate;
        // Current stable borrow rate (APY for stable borrowers)
        uint128 currentStableBorrowRate;
        // Last update timestamp
        uint40 lastUpdateTimestamp;
        // gToken address (interest-bearing token)
        address gTokenAddress;
        // Stable debt token address
        address stableDebtTokenAddress;
        // Variable debt token address
        address variableDebtTokenAddress;
        // Interest rate strategy address
        address interestRateStrategyAddress;
        // Reserve ID
        uint8 id;
    }

    // Struct to store user configuration
    struct UserConfiguration {
        // Bitmap of collaterals and borrows
        uint256 data;
    }

    // Mapping of asset address to reserve data
    mapping(address => ReserveData) public reserves;
    
    // List of all reserves
    address[] public reservesList;
    
    // Mapping of user address to user configuration
    mapping(address => UserConfiguration) public usersConfig;
    
    // Address of the price oracle
    address public priceOracle;
    
    // Address of the lending pool configurator
    address public poolConfigurator;
    
    // Events
    event Deposit(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint16 indexed referral
    );
    
    event Withdraw(
        address indexed reserve,
        address indexed user,
        address indexed to,
        uint256 amount
    );
    
    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 borrowRateMode,
        uint256 borrowRate,
        uint16 indexed referral
    );
    
    event Repay(
        address indexed reserve,
        address indexed user,
        address indexed repayer,
        uint256 amount
    );
    
    event ReserveDataUpdated(
        address indexed reserve,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex
    );
    
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator,
        bool receiveGToken
    );
    
    /**
     * @dev Modifier to check if caller is pool configurator
     */
    modifier onlyPoolConfigurator() {
        require(msg.sender == poolConfigurator, "GhalbirLendingPool: CALLER_NOT_POOL_CONFIGURATOR");
        _;
    }
    
    /**
     * @dev Constructor
     * @param _priceOracle Address of the price oracle
     * @param _poolConfigurator Address of the pool configurator
     */
    constructor(address _priceOracle, address _poolConfigurator) {
        require(_priceOracle != address(0), "GhalbirLendingPool: INVALID_PRICE_ORACLE_ADDRESS");
        require(_poolConfigurator != address(0), "GhalbirLendingPool: INVALID_POOL_CONFIGURATOR_ADDRESS");
        
        priceOracle = _priceOracle;
        poolConfigurator = _poolConfigurator;
    }
    
    /**
     * @dev Initializes a reserve
     * @param asset The address of the underlying asset
     * @param gTokenAddress The address of the gToken contract
     * @param stableDebtAddress The address of the stable debt token
     * @param variableDebtAddress The address of the variable debt token
     * @param interestRateStrategyAddress The address of the interest rate strategy
     */
    function initReserve(
        address asset,
        address gTokenAddress,
        address stableDebtAddress,
        address variableDebtAddress,
        address interestRateStrategyAddress
    ) external onlyPoolConfigurator {
        require(asset != address(0), "GhalbirLendingPool: ZERO_ADDRESS_NOT_VALID");
        require(reserves[asset].gTokenAddress == address(0), "GhalbirLendingPool: RESERVE_ALREADY_INITIALIZED");
        
        reserves[asset].gTokenAddress = gTokenAddress;
        reserves[asset].stableDebtTokenAddress = stableDebtAddress;
        reserves[asset].variableDebtTokenAddress = variableDebtAddress;
        reserves[asset].interestRateStrategyAddress = interestRateStrategyAddress;
        
        reserves[asset].liquidityIndex = uint128(1e27);
        reserves[asset].variableBorrowIndex = uint128(1e27);
        reserves[asset].currentLiquidityRate = 0;
        reserves[asset].currentVariableBorrowRate = 0;
        reserves[asset].currentStableBorrowRate = 0;
        reserves[asset].lastUpdateTimestamp = uint40(block.timestamp);
        reserves[asset].id = uint8(reservesList.length);
        
        reservesList.push(asset);
    }
    
    /**
     * @dev Updates the address of the price oracle
     * @param _priceOracle The address of the price oracle
     */
    function setPriceOracle(address _priceOracle) external onlyOwner {
        require(_priceOracle != address(0), "GhalbirLendingPool: INVALID_PRICE_ORACLE_ADDRESS");
        priceOracle = _priceOracle;
    }
    
    /**
     * @dev Updates the address of the pool configurator
     * @param _poolConfigurator The address of the pool configurator
     */
    function setPoolConfigurator(address _poolConfigurator) external onlyOwner {
        require(_poolConfigurator != address(0), "GhalbirLendingPool: INVALID_POOL_CONFIGURATOR_ADDRESS");
        poolConfigurator = _poolConfigurator;
    }
    
    /**
     * @dev Deposits an amount of underlying asset into the reserve
     * @param asset The address of the underlying asset
     * @param amount The amount to be deposited
     * @param onBehalfOf The address that will receive the gTokens
     * @param referralCode Code used for referral system
     */
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "GhalbirLendingPool: INVALID_AMOUNT");
        
        ReserveData storage reserve = reserves[asset];
        
        // Validate reserve is initialized
        require(reserve.gTokenAddress != address(0), "GhalbirLendingPool: RESERVE_NOT_INITIALIZED");
        
        // Update reserve state
        _updateState(asset);
        
        // Transfer underlying asset to gToken contract
        IERC20(asset).safeTransferFrom(msg.sender, reserve.gTokenAddress, amount);
        
        // Mint gTokens to onBehalfOf
        IGToken(reserve.gTokenAddress).mint(onBehalfOf, amount, reserve.liquidityIndex);
        
        emit Deposit(asset, msg.sender, onBehalfOf, amount, referralCode);
    }
    
    /**
     * @dev Withdraws an amount of underlying asset from the reserve
     * @param asset The address of the underlying asset
     * @param amount The amount to be withdrawn
     * @param to The address that will receive the underlying
     * @return The final amount withdrawn
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external nonReentrant returns (uint256) {
        require(to != address(0), "GhalbirLendingPool: INVALID_TARGET_ADDRESS");
        
        ReserveData storage reserve = reserves[asset];
        
        // Validate reserve is initialized
        require(reserve.gTokenAddress != address(0), "GhalbirLendingPool: RESERVE_NOT_INITIALIZED");
        
        // Update reserve state
        _updateState(asset);
        
        // Get user balance
        uint256 userBalance = IGToken(reserve.gTokenAddress).balanceOf(msg.sender);
        
        // If amount is MAX_UINT, withdraw everything
        uint256 amountToWithdraw = amount;
        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }
        
        // Validate amount
        require(amountToWithdraw > 0, "GhalbirLendingPool: INVALID_AMOUNT");
        require(amountToWithdraw <= userBalance, "GhalbirLendingPool: NOT_ENOUGH_BALANCE");
        
        // Burn gTokens and transfer underlying to user
        uint256 amountWithdrawn = IGToken(reserve.gTokenAddress).burn(
            msg.sender,
            to,
            amountToWithdraw,
            reserve.liquidityIndex
        );
        
        emit Withdraw(asset, msg.sender, to, amountWithdrawn);
        
        return amountWithdrawn;
    }
    
    /**
     * @dev Borrows an amount of asset with either stable or variable rate
     * @param asset The address of the underlying asset
     * @param amount The amount to be borrowed
     * @param interestRateMode The interest rate mode (1 = stable, 2 = variable)
     * @param referralCode Code used for referral system
     * @param onBehalfOf The address that will receive the debt tokens
     */
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "GhalbirLendingPool: INVALID_AMOUNT");
        require(interestRateMode == 1 || interestRateMode == 2, "GhalbirLendingPool: INVALID_INTEREST_RATE_MODE");
        
        ReserveData storage reserve = reserves[asset];
        
        // Validate reserve is initialized
        require(reserve.gTokenAddress != address(0), "GhalbirLendingPool: RESERVE_NOT_INITIALIZED");
        
        // Update reserve state
        _updateState(asset);
        
        // Check user has enough collateral
        require(_checkUserHasEnoughCollateral(onBehalfOf, asset, amount), "GhalbirLendingPool: COLLATERAL_NOT_ENOUGH");
        
        // Get current borrow rate
        uint256 borrowRate;
        if (interestRateMode == 1) {
            // Stable rate
            borrowRate = reserve.currentStableBorrowRate;
            
            // Mint stable debt tokens
            IDebtToken(reserve.stableDebtTokenAddress).mint(
                onBehalfOf,
                amount,
                borrowRate
            );
        } else {
            // Variable rate
            borrowRate = reserve.currentVariableBorrowRate;
            
            // Mint variable debt tokens
            IDebtToken(reserve.variableDebtTokenAddress).mint(
                onBehalfOf,
                amount,
                reserve.variableBorrowIndex
            );
        }
        
        // Update user configuration
        _updateUserConfig(onBehalfOf, asset, true);
        
        // Transfer underlying to user
        IGToken(reserve.gTokenAddress).transferUnderlyingTo(msg.sender, amount);
        
        emit Borrow(asset, msg.sender, onBehalfOf, amount, interestRateMode, borrowRate, referralCode);
    }
    
    /**
     * @dev Repays a borrowed amount on the specific reserve
     * @param asset The address of the underlying asset
     * @param amount The amount to repay
     * @param interestRateMode The interest rate mode (1 = stable, 2 = variable)
     * @param onBehalfOf The address of the user who will get his debt reduced
     * @return The final amount repaid
     */
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external nonReentrant returns (uint256) {
        require(interestRateMode == 1 || interestRateMode == 2, "GhalbirLendingPool: INVALID_INTEREST_RATE_MODE");
        
        ReserveData storage reserve = reserves[asset];
        
        // Validate reserve is initialized
        require(reserve.gTokenAddress != address(0), "GhalbirLendingPool: RESERVE_NOT_INITIALIZED");
        
        // Update reserve state
        _updateState(asset);
        
        // Get user debt
        uint256 userDebt;
        if (interestRateMode == 1) {
            userDebt = IDebtToken(reserve.stableDebtTokenAddress).balanceOf(onBehalfOf);
        } else {
            userDebt = IDebtToken(reserve.variableDebtTokenAddress).balanceOf(onBehalfOf);
        }
        
        // If amount is MAX_UINT, repay everything
        uint256 amountToRepay = amount;
        if (amount == type(uint256).max) {
            amountToRepay = userDebt;
        }
        
        // Validate amount
        require(amountToRepay > 0, "GhalbirLendingPool: INVALID_AMOUNT");
        require(amountToRepay <= userDebt, "GhalbirLendingPool: AMOUNT_EXCEEDS_DEBT");
        
        // Transfer underlying from user to gToken contract
        IERC20(asset).safeTransferFrom(msg.sender, reserve.gTokenAddress, amountToRepay);
        
        // Burn debt tokens
        if (interestRateMode == 1) {
            IDebtToken(reserve.stableDebtTokenAddress).burn(onBehalfOf, amountToRepay);
        } else {
            IDebtToken(reserve.variableDebtTokenAddress).burn(onBehalfOf, amountToRepay, reserve.variableBorrowIndex);
        }
        
        // If debt is fully repaid, update user configuration
        if (amountToRepay == userDebt) {
            _updateUserConfig(onBehalfOf, asset, false);
        }
        
        emit Repay(asset, onBehalfOf, msg.sender, amountToRepay);
        
        return amountToRepay;
    }
    
    /**
     * @dev Liquidates a non-healthy position
     * @param collateralAsset The address of the collateral asset
     * @param debtAsset The address of the debt asset
     * @param user The address of the borrower
     * @param debtToCover The amount of debt to cover
     * @param receiveGToken True if liquidator wants to receive gTokens, false for underlying asset
     */
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveGToken
    ) external nonReentrant whenNotPaused {
        require(debtToCover > 0, "GhalbirLendingPool: INVALID_DEBT_AMOUNT");
        
        // Validate reserves are initialized
        require(reserves[collateralAsset].gTokenAddress != address(0), "GhalbirLendingPool: COLLATERAL_RESERVE_NOT_INITIALIZED");
        require(reserves[debtAsset].gTokenAddress != address(0), "GhalbirLendingPool: DEBT_RESERVE_NOT_INITIALIZED");
        
        // Update reserve states
        _updateState(collateralAsset);
        _updateState(debtAsset);
        
        // Check if position is unhealthy
        require(!_isPositionHealthy(user, collateralAsset, debtAsset), "GhalbirLendingPool: POSITION_IS_HEALTHY");
        
        // Get user debt
        uint256 userStableDebt = IDebtToken(reserves[debtAsset].stableDebtTokenAddress).balanceOf(user);
        uint256 userVariableDebt = IDebtToken(reserves[debtAsset].variableDebtTokenAddress).balanceOf(user);
        uint256 userTotalDebt = userStableDebt + userVariableDebt;
        
        // Validate debt amount
        if (debtToCover == type(uint256).max) {
            debtToCover = userTotalDebt;
        }
        require(debtToCover <= userTotalDebt, "GhalbirLendingPool: INVALID_DEBT_AMOUNT");
        
        // Calculate liquidation values
        (
            uint256 collateralPrice,
            uint256 debtPrice,
            uint256 liquidationBonus,
            uint256 collateralAmount
        ) = _calculateLiquidationValues(
            collateralAsset,
            debtAsset,
            debtToCover,
            user
        );
        
        // Transfer debt asset from liquidator to gToken contract
        IERC20(debtAsset).safeTransferFrom(msg.sender, reserves[debtAsset].gTokenAddress, debtToCover);
        
        // Burn debt tokens
        if (userStableDebt > 0) {
            uint256 stableDebtToCover = Math.min(debtToCover, userStableDebt);
            IDebtToken(reserves[debtAsset].stableDebtTokenAddress).burn(user, stableDebtToCover);
            debtToCover -= stableDebtToCover;
        }
        
        if (debtToCover > 0) {
            IDebtToken(reserves[debtAsset].variableDebtTokenAddress).burn(
                user,
                debtToCover,
                reserves[debtAsset].variableBorrowIndex
            );
        }
        
        // Transfer collateral to liquidator
        if (receiveGToken) {
            // Transfer gTokens directly
            IGToken(reserves[collateralAsset].gTokenAddress).transferOnLiquidation(user, msg.sender, collateralAmount);
        } else {
            // Burn gTokens and transfer underlying
            IGToken(reserves[collateralAsset].gTokenAddress).burn(
                user,
                msg.sender,
                collateralAmount,
                reserves[collateralAsset].liquidityIndex
            );
        }
        
        // Update user configuration if all debt is repaid
        if (userStableDebt + userVariableDebt - debtToCover == 0) {
            _updateUserConfig(user, debtAsset, false);
        }
        
        emit LiquidationCall(
            collateralAsset,
            debtAsset,
            user,
            debtToCover,
            collateralAmount,
            msg.sender,
            receiveGToken
        );
    }
    
    /**
     * @dev Sets the user's asset as collateral or not
     * @param asset The address of the underlying asset
     * @param useAsCollateral True if the user wants to use the asset as collateral
     */
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external nonReentrant {
        ReserveData storage reserve = reserves[asset];
        
        // Validate reserve is initialized
        require(reserve.gTokenAddress != address(0), "GhalbirLendingPool: RESERVE_NOT_INITIALIZED");
        
        // Get user balance
        uint256 userBalance = IGToken(reserve.gTokenAddress).balanceOf(msg.sender);
        require(userBalance > 0, "GhalbirLendingPool: NO_BALANCE_TO_SET_AS_COLLATERAL");
        
        // Update user configuration
        _updateUserConfig(msg.sender, asset, useAsCollateral);
    }
    
    /**
     * @dev Gets the user account data
     * @param user The address of the user
     * @return totalCollateralETH The total collateral in ETH
     * @return totalDebtETH The total debt in ETH
     * @return availableBorrowsETH The available borrows in ETH
     * @return currentLiquidationThreshold The current liquidation threshold
     * @return ltv The loan to value ratio
     * @return healthFactor The health factor
     */
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 availableBorrowsETH,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    ) {
        // Calculate total collateral and debt
        (
            totalCollateralETH,
            totalDebtETH,
            ltv,
            currentLiquidationThreshold,
            healthFactor
        ) = _calculateUserAccountData(user);
        
        // Calculate available borrows
        availableBorrowsETH = totalCollateralETH * ltv / 10000;
        if (availableBorrowsETH > totalDebtETH) {
            availableBorrowsETH = availableBorrowsETH - totalDebtETH;
        } else {
            availableBorrowsETH = 0;
        }
    }
    
    /**
     * @dev Gets the reserve data
     * @param asset The address of the underlying asset
     * @return The reserve data
     */
    function getReserveData(address asset) external view returns (ReserveData memory) {
        return reserves[asset];
    }
    
    /**
     * @dev Gets the list of all reserves
     * @return The list of reserve addresses
     */
    function getReservesList() external view returns (address[] memory) {
        return reservesList;
    }
    
    /**
     * @dev Updates the state of a reserve
     * @param asset The address of the underlying asset
     */
    function _updateState(address asset) internal {
        ReserveData storage reserve = reserves[asset];
        uint40 timestamp = uint40(block.timestamp);
        
        // Skip if already updated in this block
        if (reserve.lastUpdateTimestamp == timestamp) {
            return;
        }
        
        // Get current supply and borrow data
        uint256 totalStableDebt = IDebtToken(reserve.stableDebtTokenAddress).totalSupply();
        uint256 totalVariableDebt = IDebtToken(reserve.variableDebtTokenAddress).totalSupply();
        uint256 availableLiquidity = IERC20(asset).balanceOf(reserve.gTokenAddress);
        
        // Calculate new interest rates
        (
            uint256 liquidityRate,
            uint256 stableBorrowRate,
            uint256 variableBorrowRate
        ) = IInterestRateStrategy(reserve.interestRateStrategyAddress).calculateInterestRates(
            asset,
            availableLiquidity,
            totalStableDebt,
            totalVariableDebt,
            reserve.currentStableBorrowRate,
            reserve.configuration
        );
        
        // Update indices
        uint256 timeDelta = timestamp - reserve.lastUpdateTimestamp;
        if (timeDelta > 0) {
            // Update liquidity index
            uint256 liquidityIndex = reserve.liquidityIndex;
            liquidityIndex = liquidityIndex + (liquidityIndex * reserve.currentLiquidityRate * timeDelta / 365 days / 10000);
            reserve.liquidityIndex = uint128(liquidityIndex);
            
            // Update variable borrow index
            uint256 variableBorrowIndex = reserve.variableBorrowIndex;
            variableBorrowIndex = variableBorrowIndex + (variableBorrowIndex * reserve.currentVariableBorrowRate * timeDelta / 365 days / 10000);
            reserve.variableBorrowIndex = uint128(variableBorrowIndex);
        }
        
        // Update rates
        reserve.currentLiquidityRate = uint128(liquidityRate);
        reserve.currentStableBorrowRate = uint128(stableBorrowRate);
        reserve.currentVariableBorrowRate = uint128(variableBorrowRate);
        reserve.lastUpdateTimestamp = timestamp;
        
        emit ReserveDataUpdated(
            asset,
            liquidityRate,
            stableBorrowRate,
            variableBorrowRate,
            reserve.liquidityIndex,
            reserve.variableBorrowIndex
        );
    }
    
    /**
     * @dev Updates the user configuration for an asset
     * @param user The address of the user
     * @param asset The address of the underlying asset
     * @param useAsCollateralOrBorrow True if the user is using the asset as collateral or borrowing
     */
    function _updateUserConfig(address user, address asset, bool useAsCollateralOrBorrow) internal {
        UserConfiguration storage userConfig = usersConfig[user];
        uint256 reserveId = reserves[asset].id;
        
        if (useAsCollateralOrBorrow) {
            // Set bit to 1
            userConfig.data = userConfig.data | (1 << reserveId);
        } else {
            // Set bit to 0
            userConfig.data = userConfig.data & ~(1 << reserveId);
        }
    }
    
    /**
     * @dev Checks if a user has enough collateral to borrow
     * @param user The address of the user
     * @param asset The address of the underlying asset
     * @param amount The amount to borrow
     * @return True if the user has enough collateral
     */
    function _checkUserHasEnoughCollateral(
        address user,
        address asset,
        uint256 amount
    ) internal view returns (bool) {
        // Get asset price
        uint256 assetPrice = IPriceOracle(priceOracle).getAssetPrice(asset);
        
        // Calculate user account data
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 ltv,
            ,
            uint256 healthFactor
        ) = _calculateUserAccountData(user);
        
        // Calculate new debt
        uint256 amountETH = amount * assetPrice / 1e18;
        uint256 newDebtETH = totalDebtETH + amountETH;
        
        // Check if new debt is within limits
        if (newDebtETH == 0) {
            return true;
        }
        
        uint256 maxDebtETH = totalCollateralETH * ltv / 10000;
        
        return newDebtETH <= maxDebtETH;
    }
    
    /**
     * @dev Checks if a position is healthy
     * @param user The address of the user
     * @param collateralAsset The address of the collateral asset
     * @param debtAsset The address of the debt asset
     * @return True if the position is healthy
     */
    function _isPositionHealthy(
        address user,
        address collateralAsset,
        address debtAsset
    ) internal view returns (bool) {
        // Calculate user account data
        (
            ,
            ,
            ,
            ,
            uint256 healthFactor
        ) = _calculateUserAccountData(user);
        
        // Position is healthy if health factor >= 1
        return healthFactor >= 1e18;
    }
    
    /**
     * @dev Calculates liquidation values
     * @param collateralAsset The address of the collateral asset
     * @param debtAsset The address of the debt asset
     * @param debtToCover The amount of debt to cover
     * @param user The address of the user
     * @return collateralPrice The price of the collateral
     * @return debtPrice The price of the debt
     * @return liquidationBonus The liquidation bonus
     * @return collateralAmount The amount of collateral to liquidate
     */
    function _calculateLiquidationValues(
        address collateralAsset,
        address debtAsset,
        uint256 debtToCover,
        address user
    ) internal view returns (
        uint256 collateralPrice,
        uint256 debtPrice,
        uint256 liquidationBonus,
        uint256 collateralAmount
    ) {
        // Get prices
        collateralPrice = IPriceOracle(priceOracle).getAssetPrice(collateralAsset);
        debtPrice = IPriceOracle(priceOracle).getAssetPrice(debtAsset);
        
        // Get liquidation bonus (e.g., 110% = 11000)
        liquidationBonus = 11000; // 10% bonus
        
        // Calculate collateral amount to liquidate
        uint256 debtAmountETH = debtToCover * debtPrice / 1e18;
        uint256 collateralAmountETH = debtAmountETH * liquidationBonus / 10000;
        collateralAmount = collateralAmountETH * 1e18 / collateralPrice;
        
        // Ensure we don't liquidate more than user has
        uint256 userCollateralBalance = IGToken(reserves[collateralAsset].gTokenAddress).balanceOf(user);
        if (collateralAmount > userCollateralBalance) {
            collateralAmount = userCollateralBalance;
        }
    }
    
    /**
     * @dev Calculates user account data
     * @param user The address of the user
     * @return totalCollateralETH The total collateral in ETH
     * @return totalDebtETH The total debt in ETH
     * @return ltv The loan to value ratio
     * @return liquidationThreshold The liquidation threshold
     * @return healthFactor The health factor
     */
    function _calculateUserAccountData(address user) internal view returns (
        uint256 totalCollateralETH,
        uint256 totalDebtETH,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 healthFactor
    ) {
        // Initialize values
        totalCollateralETH = 0;
        totalDebtETH = 0;
        ltv = 0;
        liquidationThreshold = 0;
        
        // Get user configuration
        UserConfiguration storage userConfig = usersConfig[user];
        
        // If user has no configuration, return zeros
        if (userConfig.data == 0) {
            return (0, 0, 0, 0, type(uint256).max);
        }
        
        // Calculate weighted values
        uint256 totalCollateralETHWithLTV = 0;
        uint256 totalCollateralETHWithThreshold = 0;
        
        // Loop through all reserves
        for (uint256 i = 0; i < reservesList.length; i++) {
            address asset = reservesList[i];
            
            // Check if user is using this asset
            if ((userConfig.data & (1 << i)) == 0) {
                continue;
            }
            
            // Get asset price
            uint256 assetPrice = IPriceOracle(priceOracle).getAssetPrice(asset);
            
            // Calculate collateral
            uint256 userBalance = IGToken(reserves[asset].gTokenAddress).balanceOf(user);
            if (userBalance > 0) {
                uint256 collateralETH = userBalance * assetPrice / 1e18;
                totalCollateralETH += collateralETH;
                
                // Get asset LTV and liquidation threshold
                uint256 assetLTV = 8000; // 80%
                uint256 assetThreshold = 8500; // 85%
                
                totalCollateralETHWithLTV += collateralETH * assetLTV / 10000;
                totalCollateralETHWithThreshold += collateralETH * assetThreshold / 10000;
            }
            
            // Calculate debt
            uint256 userStableDebt = IDebtToken(reserves[asset].stableDebtTokenAddress).balanceOf(user);
            uint256 userVariableDebt = IDebtToken(reserves[asset].variableDebtTokenAddress).balanceOf(user);
            
            if (userStableDebt > 0 || userVariableDebt > 0) {
                totalDebtETH += (userStableDebt + userVariableDebt) * assetPrice / 1e18;
            }
        }
        
        // Calculate weighted LTV and liquidation threshold
        if (totalCollateralETH > 0) {
            ltv = totalCollateralETHWithLTV * 10000 / totalCollateralETH;
            liquidationThreshold = totalCollateralETHWithThreshold * 10000 / totalCollateralETH;
        }
        
        // Calculate health factor
        if (totalDebtETH == 0) {
            healthFactor = type(uint256).max; // Max value if no debt
        } else {
            healthFactor = totalCollateralETHWithThreshold * 1e18 / totalDebtETH;
        }
    }
    
    /**
     * @dev Pauses the lending pool
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpauses the lending pool
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}

/**
 * @title IGToken
 * @dev Interface for the GToken contract
 */
interface IGToken {
    function mint(address user, uint256 amount, uint256 index) external returns (bool);
    function burn(address user, address receiverOfUnderlying, uint256 amount, uint256 index) external returns (uint256);
    function balanceOf(address user) external view returns (uint256);
    function transferOnLiquidation(address from, address to, uint256 value) external;
    function transferUnderlyingTo(address target, uint256 amount) external returns (uint256);
}

/**
 * @title IDebtToken
 * @dev Interface for the DebtToken contract
 */
interface IDebtToken {
    function mint(address user, uint256 amount, uint256 index) external returns (bool);
    function burn(address user, uint256 amount) external;
    function burn(address user, uint256 amount, uint256 index) external;
    function balanceOf(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/**
 * @title IInterestRateStrategy
 * @dev Interface for the InterestRateStrategy contract
 */
interface IInterestRateStrategy {
    function calculateInterestRates(
        address reserve,
        uint256 availableLiquidity,
        uint256 totalStableDebt,
        uint256 totalVariableDebt,
        uint256 averageStableBorrowRate,
        uint256 reserveFactor
    ) external view returns (
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate
    );
}

/**
 * @title IPriceOracle
 * @dev Interface for the PriceOracle contract
 */
interface IPriceOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);
}
