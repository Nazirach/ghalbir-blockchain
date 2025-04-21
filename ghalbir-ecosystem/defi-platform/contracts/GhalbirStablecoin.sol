// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title GhalbirStablecoin
 * @dev Implementation of the gUSD stablecoin
 */
contract GhalbirStablecoin is ERC20, Ownable, Pausable {
    // Events
    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);
    
    /**
     * @dev Constructor
     */
    constructor() ERC20("Ghalbir USD", "gUSD") {
        // Initialize with no supply
    }
    
    /**
     * @dev Mints new tokens
     * @param to The address that will receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner whenNotPaused {
        require(to != address(0), "GhalbirStablecoin: mint to the zero address");
        _mint(to, amount);
        emit Mint(to, amount);
    }
    
    /**
     * @dev Burns tokens
     * @param from The address whose tokens will be burned
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyOwner {
        require(from != address(0), "GhalbirStablecoin: burn from the zero address");
        _burn(from, amount);
        emit Burn(from, amount);
    }
    
    /**
     * @dev Allows users to burn their own tokens
     * @param amount The amount of tokens to burn
     */
    function burnSelf(uint256 amount) external whenNotPaused {
        _burn(msg.sender, amount);
        emit Burn(msg.sender, amount);
    }
    
    /**
     * @dev Pauses token transfers
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpauses token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Hook that is called before any transfer of tokens
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }
}

/**
 * @title GhalbirVaultManager
 * @dev Manages collateralized debt positions (CDPs) for the gUSD stablecoin
 */
contract GhalbirVaultManager is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // Struct to store vault data
    struct Vault {
        address owner;
        address collateralType;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 lastInterestUpdate;
    }
    
    // Struct to store collateral parameters
    struct CollateralParams {
        uint256 debtCeiling;        // Maximum debt allowed for this collateral type
        uint256 collateralRatio;    // Minimum collateral ratio (e.g., 150% = 15000)
        uint256 stabilityFee;       // Annual stability fee (e.g., 5% = 500)
        uint256 liquidationPenalty; // Liquidation penalty (e.g., 13% = 1300)
        bool active;                // Whether this collateral type is active
    }
    
    // Stablecoin contract
    GhalbirStablecoin public stablecoin;
    
    // Price oracle
    address public priceOracle;
    
    // Vaults
    mapping(uint256 => Vault) public vaults;
    uint256 public nextVaultId = 1;
    
    // Collateral types
    mapping(address => CollateralParams) public collateralParams;
    address[] public collateralTypes;
    
    // Global debt ceiling
    uint256 public globalDebtCeiling;
    
    // Total debt
    uint256 public totalDebt;
    
    // Events
    event VaultCreated(uint256 indexed vaultId, address indexed owner, address collateralType);
    event CollateralDeposited(uint256 indexed vaultId, uint256 amount);
    event CollateralWithdrawn(uint256 indexed vaultId, uint256 amount);
    event DebtGenerated(uint256 indexed vaultId, uint256 amount);
    event DebtRepaid(uint256 indexed vaultId, uint256 amount);
    event VaultLiquidated(uint256 indexed vaultId, address liquidator, uint256 debtRepaid, uint256 collateralLiquidated);
    event CollateralTypeAdded(address indexed collateralType, uint256 debtCeiling, uint256 collateralRatio);
    event CollateralParamsUpdated(address indexed collateralType, uint256 debtCeiling, uint256 collateralRatio, uint256 stabilityFee);
    
    /**
     * @dev Constructor
     * @param _stablecoin Address of the stablecoin contract
     * @param _priceOracle Address of the price oracle
     */
    constructor(address _stablecoin, address _priceOracle) {
        require(_stablecoin != address(0), "GhalbirVaultManager: stablecoin address cannot be zero");
        require(_priceOracle != address(0), "GhalbirVaultManager: price oracle address cannot be zero");
        
        stablecoin = GhalbirStablecoin(_stablecoin);
        priceOracle = _priceOracle;
        globalDebtCeiling = 1_000_000 * 10**18; // 1 million gUSD
    }
    
    /**
     * @dev Adds a new collateral type
     * @param collateralType Address of the collateral token
     * @param debtCeiling Maximum debt allowed for this collateral type
     * @param collateralRatio Minimum collateral ratio (e.g., 150% = 15000)
     * @param stabilityFee Annual stability fee (e.g., 5% = 500)
     * @param liquidationPenalty Liquidation penalty (e.g., 13% = 1300)
     */
    function addCollateralType(
        address collateralType,
        uint256 debtCeiling,
        uint256 collateralRatio,
        uint256 stabilityFee,
        uint256 liquidationPenalty
    ) external onlyOwner {
        require(collateralType != address(0), "GhalbirVaultManager: collateral type cannot be zero address");
        require(collateralParams[collateralType].collateralRatio == 0, "GhalbirVaultManager: collateral type already exists");
        require(collateralRatio >= 10000, "GhalbirVaultManager: collateral ratio must be at least 100%");
        
        collateralParams[collateralType] = CollateralParams({
            debtCeiling: debtCeiling,
            collateralRatio: collateralRatio,
            stabilityFee: stabilityFee,
            liquidationPenalty: liquidationPenalty,
            active: true
        });
        
        collateralTypes.push(collateralType);
        
        emit CollateralTypeAdded(collateralType, debtCeiling, collateralRatio);
    }
    
    /**
     * @dev Updates parameters for a collateral type
     * @param collateralType Address of the collateral token
     * @param debtCeiling Maximum debt allowed for this collateral type
     * @param collateralRatio Minimum collateral ratio
     * @param stabilityFee Annual stability fee
     * @param liquidationPenalty Liquidation penalty
     * @param active Whether this collateral type is active
     */
    function updateCollateralParams(
        address collateralType,
        uint256 debtCeiling,
        uint256 collateralRatio,
        uint256 stabilityFee,
        uint256 liquidationPenalty,
        bool active
    ) external onlyOwner {
        require(collateralParams[collateralType].collateralRatio > 0, "GhalbirVaultManager: collateral type does not exist");
        require(collateralRatio >= 10000, "GhalbirVaultManager: collateral ratio must be at least 100%");
        
        collateralParams[collateralType].debtCeiling = debtCeiling;
        collateralParams[collateralType].collateralRatio = collateralRatio;
        collateralParams[collateralType].stabilityFee = stabilityFee;
        collateralParams[collateralType].liquidationPenalty = liquidationPenalty;
        collateralParams[collateralType].active = active;
        
        emit CollateralParamsUpdated(collateralType, debtCeiling, collateralRatio, stabilityFee);
    }
    
    /**
     * @dev Updates the global debt ceiling
     * @param newCeiling New global debt ceiling
     */
    function updateGlobalDebtCeiling(uint256 newCeiling) external onlyOwner {
        globalDebtCeiling = newCeiling;
    }
    
    /**
     * @dev Updates the price oracle address
     * @param newOracle New price oracle address
     */
    function updatePriceOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "GhalbirVaultManager: price oracle address cannot be zero");
        priceOracle = newOracle;
    }
    
    /**
     * @dev Creates a new vault
     * @param collateralType Address of the collateral token
     * @return vaultId ID of the created vault
     */
    function createVault(address collateralType) external whenNotPaused returns (uint256 vaultId) {
        require(collateralParams[collateralType].active, "GhalbirVaultManager: collateral type not active");
        
        vaultId = nextVaultId++;
        vaults[vaultId] = Vault({
            owner: msg.sender,
            collateralType: collateralType,
            collateralAmount: 0,
            debtAmount: 0,
            lastInterestUpdate: block.timestamp
        });
        
        emit VaultCreated(vaultId, msg.sender, collateralType);
    }
    
    /**
     * @dev Deposits collateral into a vault
     * @param vaultId ID of the vault
     * @param amount Amount of collateral to deposit
     */
    function depositCollateral(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "GhalbirVaultManager: deposit amount must be greater than zero");
        
        Vault storage vault = vaults[vaultId];
        require(vault.owner == msg.sender, "GhalbirVaultManager: not vault owner");
        
        // Update stability fee
        _updateStabilityFee(vaultId);
        
        // Transfer collateral from user to this contract
        IERC20(vault.collateralType).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update vault
        vault.collateralAmount += amount;
        
        emit CollateralDeposited(vaultId, amount);
    }
    
    /**
     * @dev Withdraws collateral from a vault
     * @param vaultId ID of the vault
     * @param amount Amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "GhalbirVaultManager: withdraw amount must be greater than zero");
        
        Vault storage vault = vaults[vaultId];
        require(vault.owner == msg.sender, "GhalbirVaultManager: not vault owner");
        require(vault.collateralAmount >= amount, "GhalbirVaultManager: insufficient collateral");
        
        // Update stability fee
        _updateStabilityFee(vaultId);
        
        // Check if withdrawal would make vault unsafe
        uint256 newCollateralAmount = vault.collateralAmount - amount;
        if (vault.debtAmount > 0) {
            require(_isVaultSafe(vault.collateralType, newCollateralAmount, vault.debtAmount), 
                    "GhalbirVaultManager: withdrawal would make vault unsafe");
        }
        
        // Update vault
        vault.collateralAmount = newCollateralAmount;
        
        // Transfer collateral to user
        IERC20(vault.collateralType).safeTransfer(msg.sender, amount);
        
        emit CollateralWithdrawn(vaultId, amount);
    }
    
    /**
     * @dev Generates debt (mints gUSD) from a vault
     * @param vaultId ID of the vault
     * @param amount Amount of debt to generate
     */
    function generateDebt(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "GhalbirVaultManager: debt amount must be greater than zero");
        
        Vault storage vault = vaults[vaultId];
        require(vault.owner == msg.sender, "GhalbirVaultManager: not vault owner");
        
        // Update stability fee
        _updateStabilityFee(vaultId);
        
        // Check debt ceilings
        uint256 newTotalDebt = totalDebt + amount;
        require(newTotalDebt <= globalDebtCeiling, "GhalbirVaultManager: global debt ceiling reached");
        
        CollateralParams storage params = collateralParams[vault.collateralType];
        uint256 collateralTypeDebt = _getCollateralTypeDebt(vault.collateralType);
        require(collateralTypeDebt + amount <= params.debtCeiling, "GhalbirVaultManager: collateral debt ceiling reached");
        
        // Check if vault would be safe after generating debt
        uint256 newDebtAmount = vault.debtAmount + amount;
        require(_isVaultSafe(vault.collateralType, vault.collateralAmount, newDebtAmount), 
                "GhalbirVaultManager: vault would be unsafe");
        
        // Update vault
        vault.debtAmount = newDebtAmount;
        
        // Update total debt
        totalDebt += amount;
        
        // Mint gUSD to user
        stablecoin.mint(msg.sender, amount);
        
        emit DebtGenerated(vaultId, amount);
    }
    
    /**
     * @dev Repays debt (burns gUSD) for a vault
     * @param vaultId ID of the vault
     * @param amount Amount of debt to repay
     */
    function repayDebt(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "GhalbirVaultManager: repay amount must be greater than zero");
        
        Vault storage vault = vaults[vaultId];
        require(vault.debtAmount > 0, "GhalbirVaultManager: no debt to repay");
        
        // Update stability fee
        _updateStabilityFee(vaultId);
        
        // Calculate actual repay amount
        uint256 repayAmount = Math.min(amount, vault.debtAmount);
        
        // Update vault
        vault.debtAmount -= repayAmount;
        
        // Update total debt
        totalDebt -= repayAmount;
        
        // Transfer gUSD from user to this contract and burn it
        stablecoin.burn(msg.sender, repayAmount);
        
        emit DebtRepaid(vaultId, repayAmount);
    }
    
    /**
     * @dev Liquidates an unsafe vault
     * @param vaultId ID of the vault to liquidate
     */
    function liquidateVault(uint256 vaultId) external nonReentrant whenNotPaused {
        Vault storage vault = vaults[vaultId];
        require(vault.debtAmount > 0, "GhalbirVaultManager: no debt to liquidate");
        
        // Update stability fee
        _updateStabilityFee(vaultId);
        
        // Check if vault is unsafe
        require(!_isVaultSafe(vault.collateralType, vault.collateralAmount, vault.debtAmount), 
                "GhalbirVaultManager: vault is safe");
        
        // Calculate liquidation values
        CollateralParams storage params = collateralParams[vault.collateralType];
        uint256 debtToRepay = vault.debtAmount;
        uint256 liquidationPenalty = debtToRepay * params.liquidationPenalty / 10000;
        uint256 totalDebtWithPenalty = debtToRepay + liquidationPenalty;
        
        // Calculate collateral to liquidate
        uint256 collateralPrice = IPriceOracle(priceOracle).getAssetPrice(vault.collateralType);
        uint256 collateralToLiquidate = totalDebtWithPenalty * 1e18 / collateralPrice;
        
        // Cap collateral to liquidate at vault's collateral amount
        if (collateralToLiquidate > vault.collateralAmount) {
            collateralToLiquidate = vault.collateralAmount;
        }
        
        // Update vault
        vault.collateralAmount -= collateralToLiquidate;
        vault.debtAmount = 0;
        
        // Update total debt
        totalDebt -= debtToRepay;
        
        // Transfer gUSD from liquidator to this contract and burn it
        stablecoin.burn(msg.sender, debtToRepay);
        
        // Transfer liquidated collateral to liquidator
        IERC20(vault.collateralType).safeTransfer(msg.sender, collateralToLiquidate);
        
        emit VaultLiquidated(vaultId, msg.sender, debtToRepay, collateralToLiquidate);
    }
    
    /**
     * @dev Gets information about a vault
     * @param vaultId ID of the vault
     * @return owner Owner of the vault
     * @return collateralType Collateral token address
     * @return collateralAmount Amount of collateral in the vault
     * @return debtAmount Amount of debt in the vault
     * @return liquidationPrice Price at which the vault becomes unsafe
     */
    function getVaultInfo(uint256 vaultId) external view returns (
        address owner,
        address collateralType,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 liquidationPrice
    ) {
        Vault storage vault = vaults[vaultId];
        owner = vault.owner;
        collateralType = vault.collateralType;
        collateralAmount = vault.collateralAmount;
        
        // Calculate debt with accrued stability fee
        uint256 timeDelta = block.timestamp - vault.lastInterestUpdate;
        uint256 stabilityFee = collateralParams[vault.collateralType].stabilityFee;
        debtAmount = vault.debtAmount + (vault.debtAmount * stabilityFee * timeDelta / 365 days / 10000);
        
        // Calculate liquidation price
        if (collateralAmount > 0 && debtAmount > 0) {
            uint256 collateralRatio = collateralParams[vault.collateralType].collateralRatio;
            liquidationPrice = debtAmount * collateralRatio * 1e18 / (collateralAmount * 10000);
        } else {
            liquidationPrice = 0;
        }
    }
    
    /**
     * @dev Gets all collateral types
     * @return Array of collateral token addresses
     */
    function getCollateralTypes() external view returns (address[] memory) {
        return collateralTypes;
    }
    
    /**
     * @dev Gets parameters for a collateral type
     * @param collateralType Address of the collateral token
     * @return debtCeiling Maximum debt allowed for this collateral type
     * @return collateralRatio Minimum collateral ratio
     * @return stabilityFee Annual stability fee
     * @return liquidationPenalty Liquidation penalty
     */
    function getCollateralParameters(address collateralType) external view returns (
        uint256 debtCeiling,
        uint256 collateralRatio,
        uint256 stabilityFee,
        uint256 liquidationPenalty
    ) {
        CollateralParams storage params = collateralParams[collateralType];
        return (
            params.debtCeiling,
            params.collateralRatio,
            params.stabilityFee,
            params.liquidationPenalty
        );
    }
    
    /**
     * @dev Updates the stability fee for a vault
     * @param vaultId ID of the vault
     */
    function _updateStabilityFee(uint256 vaultId) internal {
        Vault storage vault = vaults[vaultId];
        
        if (vault.debtAmount == 0 || vault.lastInterestUpdate == block.timestamp) {
            return;
        }
        
        uint256 timeDelta = block.timestamp - vault.lastInterestUpdate;
        uint256 stabilityFee = collateralParams[vault.collateralType].stabilityFee;
        uint256 feeAmount = vault.debtAmount * stabilityFee * timeDelta / 365 days / 10000;
        
        if (feeAmount > 0) {
            vault.debtAmount += feeAmount;
            totalDebt += feeAmount;
        }
        
        vault.lastInterestUpdate = block.timestamp;
    }
    
    /**
     * @dev Checks if a vault is safe
     * @param collateralType Collateral token address
     * @param collateralAmount Amount of collateral
     * @param debtAmount Amount of debt
     * @return True if the vault is safe
     */
    function _isVaultSafe(
        address collateralType,
        uint256 collateralAmount,
        uint256 debtAmount
    ) internal view returns (bool) {
        if (debtAmount == 0) {
            return true;
        }
        
        if (collateralAmount == 0) {
            return false;
        }
        
        uint256 collateralPrice = IPriceOracle(priceOracle).getAssetPrice(collateralType);
        uint256 collateralValue = collateralAmount * collateralPrice / 1e18;
        uint256 minCollateralValue = debtAmount * collateralParams[collateralType].collateralRatio / 10000;
        
        return collateralValue >= minCollateralValue;
    }
    
    /**
     * @dev Gets the total debt for a collateral type
     * @param collateralType Collateral token address
     * @return Total debt for the collateral type
     */
    function _getCollateralTypeDebt(address collateralType) internal view returns (uint256) {
        uint256 debt = 0;
        for (uint256 i = 1; i < nextVaultId; i++) {
            if (vaults[i].collateralType == collateralType) {
                debt += vaults[i].debtAmount;
            }
        }
        return debt;
    }
    
    /**
     * @dev Pauses the vault manager
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpauses the vault manager
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}

/**
 * @title IPriceOracle
 * @dev Interface for the price oracle
 */
interface IPriceOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}
