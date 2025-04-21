// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title GhalbirRouter
 * @dev Router contract for the Ghalbir DEX
 */
contract GhalbirRouter is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Factory address
    address public immutable factory;
    // WGBR address (wrapped GBR for GBR/token swaps)
    address public immutable WGBR;

    // Deadline grace period
    uint private constant DEADLINE_GRACE_PERIOD = 2 minutes;

    // Events
    event LiquidityAdded(
        address indexed tokenA,
        address indexed tokenB,
        uint amountA,
        uint amountB,
        uint liquidity,
        address indexed to
    );
    event LiquidityRemoved(
        address indexed tokenA,
        address indexed tokenB,
        uint amountA,
        uint amountB,
        uint liquidity,
        address indexed to
    );
    event Swapped(
        address[] path,
        uint[] amounts,
        address indexed to
    );

    /**
     * @dev Constructor
     * @param _factory Address of the factory contract
     * @param _WGBR Address of the WGBR contract
     */
    constructor(address _factory, address _WGBR) {
        require(_factory != address(0), "GhalbirRouter: FACTORY_ADDRESS_ZERO");
        require(_WGBR != address(0), "GhalbirRouter: WGBR_ADDRESS_ZERO");
        factory = _factory;
        WGBR = _WGBR;
    }

    /**
     * @dev Add liquidity to a token pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountADesired Desired amount of tokenA
     * @param amountBDesired Desired amount of tokenB
     * @param amountAMin Minimum amount of tokenA
     * @param amountBMin Minimum amount of tokenB
     * @param to Address to receive LP tokens
     * @param deadline Transaction deadline timestamp
     * @return amountA Amount of tokenA added
     * @return amountB Amount of tokenB added
     * @return liquidity Amount of LP tokens minted
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external nonReentrant whenNotPaused returns (uint amountA, uint amountB, uint liquidity) {
        require(deadline >= block.timestamp, "GhalbirRouter: EXPIRED");
        
        // Create pair if it doesn't exist
        address pair = IGhalbirFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = IGhalbirFactory(factory).createPair(tokenA, tokenB);
        }
        
        // Calculate optimal amounts
        (amountA, amountB) = _calculateLiquidityAmounts(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        
        // Transfer tokens to pair
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        
        // Mint LP tokens
        liquidity = IGhalbirPair(pair).mint(to);
        
        emit LiquidityAdded(tokenA, tokenB, amountA, amountB, liquidity, to);
    }
    
    /**
     * @dev Remove liquidity from a token pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param liquidity Amount of LP tokens to burn
     * @param amountAMin Minimum amount of tokenA to receive
     * @param amountBMin Minimum amount of tokenB to receive
     * @param to Address to receive tokens
     * @param deadline Transaction deadline timestamp
     * @return amountA Amount of tokenA received
     * @return amountB Amount of tokenB received
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external nonReentrant returns (uint amountA, uint amountB) {
        require(deadline >= block.timestamp, "GhalbirRouter: EXPIRED");
        
        address pair = IGhalbirFactory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "GhalbirRouter: PAIR_NOT_FOUND");
        
        // Transfer LP tokens to pair
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        
        // Burn LP tokens and receive tokens
        (amountA, amountB) = IGhalbirPair(pair).burn(to);
        
        require(amountA >= amountAMin, "GhalbirRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "GhalbirRouter: INSUFFICIENT_B_AMOUNT");
        
        emit LiquidityRemoved(tokenA, tokenB, amountA, amountB, liquidity, to);
    }
    
    /**
     * @dev Swap exact tokens for tokens
     * @param amountIn Exact amount of input tokens
     * @param amountOutMin Minimum amount of output tokens
     * @param path Array of token addresses (path[0] = input token, path[path.length-1] = output token)
     * @param to Address to receive output tokens
     * @param deadline Transaction deadline timestamp
     * @return amounts Array of amounts for each step in the path
     */
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external nonReentrant whenNotPaused returns (uint[] memory amounts) {
        require(deadline >= block.timestamp, "GhalbirRouter: EXPIRED");
        require(path.length >= 2, "GhalbirRouter: INVALID_PATH");
        
        // Calculate amounts
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "GhalbirRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Transfer input tokens to first pair
        address pair = IGhalbirFactory(factory).getPair(path[0], path[1]);
        require(pair != address(0), "GhalbirRouter: PAIR_NOT_FOUND");
        IERC20(path[0]).safeTransferFrom(msg.sender, pair, amounts[0]);
        
        // Execute swaps
        _swap(amounts, path, to);
        
        emit Swapped(path, amounts, to);
    }
    
    /**
     * @dev Swap tokens for exact tokens
     * @param amountOut Exact amount of output tokens
     * @param amountInMax Maximum amount of input tokens
     * @param path Array of token addresses (path[0] = input token, path[path.length-1] = output token)
     * @param to Address to receive output tokens
     * @param deadline Transaction deadline timestamp
     * @return amounts Array of amounts for each step in the path
     */
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external nonReentrant whenNotPaused returns (uint[] memory amounts) {
        require(deadline >= block.timestamp, "GhalbirRouter: EXPIRED");
        require(path.length >= 2, "GhalbirRouter: INVALID_PATH");
        
        // Calculate amounts
        amounts = getAmountsIn(amountOut, path);
        require(amounts[0] <= amountInMax, "GhalbirRouter: EXCESSIVE_INPUT_AMOUNT");
        
        // Transfer input tokens to first pair
        address pair = IGhalbirFactory(factory).getPair(path[0], path[1]);
        require(pair != address(0), "GhalbirRouter: PAIR_NOT_FOUND");
        IERC20(path[0]).safeTransferFrom(msg.sender, pair, amounts[0]);
        
        // Execute swaps
        _swap(amounts, path, to);
        
        emit Swapped(path, amounts, to);
    }
    
    /**
     * @dev Get amounts out for a given input amount and path
     * @param amountIn Input amount
     * @param path Array of token addresses
     * @return amounts Array of output amounts
     */
    function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, "GhalbirRouter: INVALID_PATH");
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        
        for (uint i = 0; i < path.length - 1; i++) {
            address pair = IGhalbirFactory(factory).getPair(path[i], path[i + 1]);
            require(pair != address(0), "GhalbirRouter: PAIR_NOT_FOUND");
            
            (uint reserveIn, uint reserveOut) = _getReserves(path[i], path[i + 1]);
            amounts[i + 1] = _getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }
    
    /**
     * @dev Get amounts in for a given output amount and path
     * @param amountOut Output amount
     * @param path Array of token addresses
     * @return amounts Array of input amounts
     */
    function getAmountsIn(uint amountOut, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, "GhalbirRouter: INVALID_PATH");
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        
        for (uint i = path.length - 1; i > 0; i--) {
            address pair = IGhalbirFactory(factory).getPair(path[i - 1], path[i]);
            require(pair != address(0), "GhalbirRouter: PAIR_NOT_FOUND");
            
            (uint reserveIn, uint reserveOut) = _getReserves(path[i - 1], path[i]);
            amounts[i - 1] = _getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
    
    /**
     * @dev Calculate optimal liquidity amounts
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountADesired Desired amount of tokenA
     * @param amountBDesired Desired amount of tokenB
     * @param amountAMin Minimum amount of tokenA
     * @param amountBMin Minimum amount of tokenB
     * @return amountA Optimal amount of tokenA
     * @return amountB Optimal amount of tokenB
     */
    function _calculateLiquidityAmounts(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal view returns (uint amountA, uint amountB) {
        address pair = IGhalbirFactory(factory).getPair(tokenA, tokenB);
        
        // If pair doesn't exist, use desired amounts
        if (pair == address(0)) {
            amountA = amountADesired;
            amountB = amountBDesired;
            return (amountA, amountB);
        }
        
        // Get reserves
        (uint reserveA, uint reserveB) = _getReserves(tokenA, tokenB);
        
        // If reserves are empty, use desired amounts
        if (reserveA == 0 && reserveB == 0) {
            amountA = amountADesired;
            amountB = amountBDesired;
            return (amountA, amountB);
        }
        
        // Calculate optimal amounts based on current ratio
        uint amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "GhalbirRouter: INSUFFICIENT_B_AMOUNT");
            amountA = amountADesired;
            amountB = amountBOptimal;
        } else {
            uint amountAOptimal = (amountBDesired * reserveA) / reserveB;
            require(amountAOptimal <= amountADesired, "GhalbirRouter: EXCESSIVE_A_AMOUNT");
            require(amountAOptimal >= amountAMin, "GhalbirRouter: INSUFFICIENT_A_AMOUNT");
            amountA = amountAOptimal;
            amountB = amountBDesired;
        }
    }
    
    /**
     * @dev Get reserves for a token pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return reserveA Reserve of tokenA
     * @return reserveB Reserve of tokenB
     */
    function _getReserves(address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pair = IGhalbirFactory(factory).getPair(token0, token1);
        
        if (pair == address(0)) {
            return (0, 0);
        }
        
        (uint reserve0, uint reserve1,) = IGhalbirPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }
    
    /**
     * @dev Calculate output amount for a given input amount and reserves
     * @param amountIn Input amount
     * @param reserveIn Input reserve
     * @param reserveOut Output reserve
     * @return amountOut Output amount
     */
    function _getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, "GhalbirRouter: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "GhalbirRouter: INSUFFICIENT_LIQUIDITY");
        
        uint amountInWithFee = amountIn * 997; // 0.3% fee
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }
    
    /**
     * @dev Calculate input amount for a given output amount and reserves
     * @param amountOut Output amount
     * @param reserveIn Input reserve
     * @param reserveOut Output reserve
     * @return amountIn Input amount
     */
    function _getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, "GhalbirRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "GhalbirRouter: INSUFFICIENT_LIQUIDITY");
        
        uint numerator = reserveIn * amountOut * 1000;
        uint denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }
    
    /**
     * @dev Execute swap along a path
     * @param amounts Array of amounts for each step
     * @param path Array of token addresses
     * @param _to Address to receive output tokens
     */
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal {
        for (uint i = 0; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = input < output ? (input, output) : (output, input);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? IGhalbirFactory(factory).getPair(output, path[i + 2]) : _to;
            IGhalbirPair(IGhalbirFactory(factory).getPair(input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    
    /**
     * @dev Pause the router
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause the router
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Recover tokens accidentally sent to the contract
     * @param token Token address
     * @param amount Amount to recover
     */
    function recoverTokens(address token, uint amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}

/**
 * @title IGhalbirFactory
 * @dev Interface for the Ghalbir Factory contract
 */
interface IGhalbirFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/**
 * @title IGhalbirPair
 * @dev Interface for the Ghalbir Pair contract
 */
interface IGhalbirPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
}
