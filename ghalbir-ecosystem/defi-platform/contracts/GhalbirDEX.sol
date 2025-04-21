// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title GhalbirFactory
 * @dev Factory contract for creating liquidity pairs in the Ghalbir DEX
 */
contract GhalbirFactory is Ownable {
    // Events
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    
    // Fee settings
    address public feeTo;
    address public feeToSetter;
    
    // Mapping of token pairs to pair addresses
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    
    // Protocol fee (1/6 of 0.3% = 0.05%)
    uint public protocolFeeDenominator = 6;
    
    /**
     * @dev Constructor
     * @param _feeToSetter Address that can change fee settings
     */
    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }
    
    /**
     * @dev Returns the number of pairs created
     */
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }
    
    /**
     * @dev Creates a new pair for two tokens
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return pair Address of the created pair
     */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "GhalbirFactory: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "GhalbirFactory: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "GhalbirFactory: PAIR_EXISTS");
        
        // Create new pair contract
        bytes memory bytecode = type(GhalbirPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        
        // Initialize pair
        GhalbirPair(pair).initialize(token0, token1);
        
        // Store pair mapping
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
    
    /**
     * @dev Sets the address that receives protocol fees
     * @param _feeTo Address to receive fees
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "GhalbirFactory: FORBIDDEN");
        feeTo = _feeTo;
    }
    
    /**
     * @dev Sets the address that can change fee settings
     * @param _feeToSetter New fee setter address
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "GhalbirFactory: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
    
    /**
     * @dev Sets the protocol fee denominator
     * @param _protocolFeeDenominator New fee denominator
     */
    function setProtocolFeeDenominator(uint _protocolFeeDenominator) external {
        require(msg.sender == feeToSetter, "GhalbirFactory: FORBIDDEN");
        require(_protocolFeeDenominator > 0, "GhalbirFactory: INVALID_DENOMINATOR");
        protocolFeeDenominator = _protocolFeeDenominator;
    }
}

/**
 * @title GhalbirPair
 * @dev Liquidity pair contract for the Ghalbir DEX
 */
contract GhalbirPair is ERC20, ReentrancyGuard {
    // Using libraries
    using Math for uint;
    
    // Constants
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
    
    // Factory address
    address public factory;
    
    // Tokens in the pair
    address public token0;
    address public token1;
    
    // Reserve data
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    
    // Price accumulators for TWAP
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    
    // Invariant k = reserve0 * reserve1
    uint public kLast;
    
    // Lock to prevent reentrancy
    uint private unlocked = 1;
    
    // Events
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    
    // Modifier to prevent reentrancy
    modifier lock() {
        require(unlocked == 1, "GhalbirPair: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }
    
    /**
     * @dev Constructor
     */
    constructor() ERC20("Ghalbir Liquidity", "GHLP") {
        factory = msg.sender;
    }
    
    /**
     * @dev Initialize the pair with token addresses
     * @param _token0 Address of token0
     * @param _token1 Address of token1
     */
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "GhalbirPair: FORBIDDEN");
        token0 = _token0;
        token1 = _token1;
    }
    
    /**
     * @dev Update reserves and time accumulator
     * @param balance0 Current balance of token0
     * @param balance1 Current balance of token1
     */
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "GhalbirPair: OVERFLOW");
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // Update price accumulators for TWAP
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }
    
    /**
     * @dev Mint fee to protocol if enabled
     * @return feeOn Whether protocol fee is enabled
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = GhalbirFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint protocolFeeDenominator = GhalbirFactory(factory).protocolFeeDenominator();
        uint _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0) * _reserve1);
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply() * (rootK - rootKLast);
                    uint denominator = (rootK * protocolFeeDenominator) + rootKLast;
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }
    
    /**
     * @dev Mint liquidity tokens for provided token amounts
     * @param to Address to receive liquidity tokens
     * @return liquidity Amount of liquidity tokens minted
     */
    function mint(address to) external lock nonReentrant returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0 - _reserve0;
        uint amount1 = balance1 - _reserve1;
        
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // Permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }
        require(liquidity > 0, "GhalbirPair: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0) * reserve1;
        
        emit Mint(msg.sender, amount0, amount1);
    }
    
    /**
     * @dev Burn liquidity tokens and receive underlying tokens
     * @param to Address to receive underlying tokens
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function burn(address to) external lock nonReentrant returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf(address(this));
        
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "GhalbirPair: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0) * reserve1;
        
        emit Burn(msg.sender, amount0, amount1, to);
    }
    
    /**
     * @dev Swap tokens
     * @param amount0Out Amount of token0 to output
     * @param amount1Out Amount of token1 to output
     * @param to Address to receive output tokens
     * @param data Additional data for flash swaps
     */
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, "GhalbirPair: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "GhalbirPair: INSUFFICIENT_LIQUIDITY");
        
        uint balance0;
        uint balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "GhalbirPair: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "GhalbirPair: INSUFFICIENT_INPUT_AMOUNT");
        {
            // Calculate fee (0.3%)
            uint balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
            uint balance1Adjusted = (balance1 * 1000) - (amount1In * 3);
            require(
                balance0Adjusted * balance1Adjusted >= uint(_reserve0) * _reserve1 * 1000**2,
                "GhalbirPair: K"
            );
        }
        
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }
    
    /**
     * @dev Force balances to match reserves
     * @param to Address to receive excess tokens
     */
    function skim(address to) external lock nonReentrant {
        address _token0 = token0;
        address _token1 = token1;
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)) - reserve0);
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)) - reserve1);
    }
    
    /**
     * @dev Force reserves to match balances
     */
    function sync() external lock nonReentrant {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }
    
    /**
     * @dev Get current reserves and last update timestamp
     * @return _reserve0 Reserve of token0
     * @return _reserve1 Reserve of token1
     * @return _blockTimestampLast Last update timestamp
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }
    
    /**
     * @dev Safe transfer function to handle non-standard ERC20 tokens
     * @param token Token address
     * @param to Recipient address
     * @param value Amount to transfer
     */
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "GhalbirPair: TRANSFER_FAILED");
    }
}

/**
 * @title UQ112x112
 * @dev Library for handling fixed point arithmetic with 112.112 format
 */
library UQ112x112 {
    uint224 constant Q112 = 2**112;

    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112;
    }

    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}

/**
 * @title IUniswapV2Callee
 * @dev Interface for flash swap callback
 */
interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external;
}
