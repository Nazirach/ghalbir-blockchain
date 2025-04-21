// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title GhalbirMultiToken
 * @dev Implementation of the GhalbirMultiToken standard, compatible with ERC1155
 */
contract GhalbirMultiToken is ERC1155, ERC1155Supply, ERC2981, Ownable, Pausable, ReentrancyGuard {
    using Strings for uint256;
    
    // Token ID counter
    uint256 private _nextTokenId = 1;
    
    // Collection info
    string public name;
    string public symbol;
    string public description;
    
    // Creator address
    address public creator;
    
    // Mapping from token ID to token URI
    mapping(uint256 => string) private _tokenURIs;
    
    // Events
    event TokenMinted(uint256 indexed tokenId, address indexed creator, address indexed to, uint256 amount, string tokenURI);
    event BatchMinted(uint256[] tokenIds, address indexed creator, address indexed to, uint256[] amounts, string[] tokenURIs);
    event URISet(uint256 indexed tokenId, string tokenURI);
    event RoyaltySet(uint256 indexed tokenId, address receiver, uint96 feeNumerator);
    
    /**
     * @dev Constructor
     * @param _name Name of the token collection
     * @param _symbol Symbol of the token collection
     * @param _description Description of the token collection
     * @param _uri Base URI for token metadata
     * @param _royaltyReceiver Address to receive royalties
     * @param _royaltyFeeNumerator Royalty fee in basis points (e.g., 1000 = 10%)
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _description,
        string memory _uri,
        address _royaltyReceiver,
        uint96 _royaltyFeeNumerator
    ) ERC1155(_uri) {
        name = _name;
        symbol = _symbol;
        description = _description;
        creator = msg.sender;
        
        // Set default royalty
        _setDefaultRoyalty(_royaltyReceiver, _royaltyFeeNumerator);
    }
    
    /**
     * @dev Mints a new token
     * @param to Address to mint the token to
     * @param amount Amount of tokens to mint
     * @param tokenURI URI for token metadata
     * @param data Additional data to pass to the receiver
     * @return tokenId ID of the minted token
     */
    function mint(
        address to,
        uint256 amount,
        string memory tokenURI,
        bytes memory data
    ) public whenNotPaused nonReentrant returns (uint256) {
        require(to != address(0), "GhalbirMultiToken: mint to the zero address");
        require(amount > 0, "GhalbirMultiToken: amount must be greater than zero");
        
        uint256 tokenId = _nextTokenId++;
        
        _mint(to, tokenId, amount, data);
        _setURI(tokenId, tokenURI);
        
        emit TokenMinted(tokenId, msg.sender, to, amount, tokenURI);
        
        return tokenId;
    }
    
    /**
     * @dev Mints a new token with custom royalty
     * @param to Address to mint the token to
     * @param amount Amount of tokens to mint
     * @param tokenURI URI for token metadata
     * @param data Additional data to pass to the receiver
     * @param royaltyReceiver Address to receive royalties
     * @param royaltyFeeNumerator Royalty fee in basis points (e.g., 1000 = 10%)
     * @return tokenId ID of the minted token
     */
    function mintWithRoyalty(
        address to,
        uint256 amount,
        string memory tokenURI,
        bytes memory data,
        address royaltyReceiver,
        uint96 royaltyFeeNumerator
    ) public whenNotPaused nonReentrant returns (uint256) {
        uint256 tokenId = mint(to, amount, tokenURI, data);
        _setTokenRoyalty(tokenId, royaltyReceiver, royaltyFeeNumerator);
        
        emit RoyaltySet(tokenId, royaltyReceiver, royaltyFeeNumerator);
        
        return tokenId;
    }
    
    /**
     * @dev Mints multiple tokens in a batch
     * @param to Address to mint the tokens to
     * @param amounts Amounts of each token to mint
     * @param tokenURIs URIs for token metadata
     * @param data Additional data to pass to the receiver
     * @return tokenIds IDs of the minted tokens
     */
    function mintBatch(
        address to,
        uint256[] memory amounts,
        string[] memory tokenURIs,
        bytes memory data
    ) public whenNotPaused nonReentrant returns (uint256[] memory) {
        require(to != address(0), "GhalbirMultiToken: mint to the zero address");
        require(amounts.length == tokenURIs.length, "GhalbirMultiToken: amounts and URIs length mismatch");
        
        uint256[] memory tokenIds = new uint256[](amounts.length);
        
        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] > 0, "GhalbirMultiToken: amount must be greater than zero");
            tokenIds[i] = _nextTokenId++;
            _setURI(tokenIds[i], tokenURIs[i]);
        }
        
        _mintBatch(to, tokenIds, amounts, data);
        
        emit BatchMinted(tokenIds, msg.sender, to, amounts, tokenURIs);
        
        return tokenIds;
    }
    
    /**
     * @dev Burns tokens
     * @param account Address to burn tokens from
     * @param id ID of the token to burn
     * @param value Amount to burn
     */
    function burn(address account, uint256 id, uint256 value) public whenNotPaused {
        require(
            account == msg.sender || isApprovedForAll(account, msg.sender),
            "GhalbirMultiToken: caller is not owner nor approved"
        );
        _burn(account, id, value);
    }
    
    /**
     * @dev Burns multiple tokens in a batch
     * @param account Address to burn tokens from
     * @param ids IDs of the tokens to burn
     * @param values Amounts to burn
     */
    function burnBatch(address account, uint256[] memory ids, uint256[] memory values) public whenNotPaused {
        require(
            account == msg.sender || isApprovedForAll(account, msg.sender),
            "GhalbirMultiToken: caller is not owner nor approved"
        );
        _burnBatch(account, ids, values);
    }
    
    /**
     * @dev Sets the URI for a token
     * @param tokenId ID of the token
     * @param tokenURI URI for token metadata
     */
    function setURI(uint256 tokenId, string memory tokenURI) public {
        require(exists(tokenId), "GhalbirMultiToken: URI set for nonexistent token");
        require(
            msg.sender == creator || msg.sender == owner(),
            "GhalbirMultiToken: caller is not creator nor owner"
        );
        
        _setURI(tokenId, tokenURI);
        
        emit URISet(tokenId, tokenURI);
    }
    
    /**
     * @dev Sets the base URI for all tokens
     * @param newuri New base URI
     */
    function setBaseURI(string memory newuri) public onlyOwner {
        _setURI(newuri);
    }
    
    /**
     * @dev Sets the default royalty for all tokens
     * @param receiver Address to receive royalties
     * @param feeNumerator Royalty fee in basis points (e.g., 1000 = 10%)
     */
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) public onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }
    
    /**
     * @dev Sets the royalty for a specific token
     * @param tokenId ID of the token
     * @param receiver Address to receive royalties
     * @param feeNumerator Royalty fee in basis points (e.g., 1000 = 10%)
     */
    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 feeNumerator) public {
        require(exists(tokenId), "GhalbirMultiToken: royalty set for nonexistent token");
        require(
            msg.sender == creator || msg.sender == owner(),
            "GhalbirMultiToken: caller is not creator nor owner"
        );
        
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
        
        emit RoyaltySet(tokenId, receiver, feeNumerator);
    }
    
    /**
     * @dev Pauses token transfers and minting
     */
    function pause() public onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpauses token transfers and minting
     */
    function unpause() public onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Gets the URI for a token
     * @param tokenId ID of the token
     * @return Token URI
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        require(exists(tokenId), "GhalbirMultiToken: URI query for nonexistent token");
        
        string memory tokenURI = _tokenURIs[tokenId];
        string memory baseURI = super.uri(tokenId);
        
        // If there is no token-specific URI, return the base URI with the token ID
        if (bytes(tokenURI).length == 0) {
            return string(abi.encodePacked(baseURI, tokenId.toString()));
        }
        
        // If the base URI is empty, return the token-specific URI
        if (bytes(baseURI).length == 0) {
            return tokenURI;
        }
        
        // Otherwise, concatenate the base URI and token-specific URI
        return string(abi.encodePacked(baseURI, tokenURI));
    }
    
    /**
     * @dev Gets the next token ID
     * @return Next token ID
     */
    function nextTokenId() public view returns (uint256) {
        return _nextTokenId;
    }
    
    /**
     * @dev Sets the URI for a token
     * @param tokenId ID of the token
     * @param tokenURI URI for token metadata
     */
    function _setURI(uint256 tokenId, string memory tokenURI) internal {
        _tokenURIs[tokenId] = tokenURI;
    }
    
    /**
     * @dev Hook that is called before any token transfer
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override(ERC1155, ERC1155Supply) whenNotPaused {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }
    
    /**
     * @dev Required override for inherited contracts
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
