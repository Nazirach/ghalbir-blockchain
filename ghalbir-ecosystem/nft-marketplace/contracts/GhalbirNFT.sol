// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title GhalbirNFT
 * @dev Implementation of the GhalbirNFT standard, compatible with ERC721
 */
contract GhalbirNFT is ERC721Enumerable, ERC721URIStorage, ERC721Royalty, Ownable, Pausable, ReentrancyGuard {
    using Counters for Counters.Counter;
    
    // Token ID counter
    Counters.Counter private _tokenIdCounter;
    
    // Base URI for metadata
    string private _baseTokenURI;
    
    // Collection info
    string public collectionName;
    string public collectionSymbol;
    string public collectionDescription;
    
    // Creator address
    address public creator;
    
    // Events
    event NFTMinted(uint256 indexed tokenId, address indexed creator, address indexed owner, string tokenURI);
    event BaseURIChanged(string newBaseURI);
    event RoyaltySet(uint256 indexed tokenId, address receiver, uint96 feeNumerator);
    
    /**
     * @dev Constructor
     * @param name Name of the NFT collection
     * @param symbol Symbol of the NFT collection
     * @param description Description of the NFT collection
     * @param baseTokenURI Base URI for token metadata
     * @param royaltyReceiver Address to receive royalties
     * @param royaltyFeeNumerator Royalty fee in basis points (e.g., 1000 = 10%)
     */
    constructor(
        string memory name,
        string memory symbol,
        string memory description,
        string memory baseTokenURI,
        address royaltyReceiver,
        uint96 royaltyFeeNumerator
    ) ERC721(name, symbol) {
        collectionName = name;
        collectionSymbol = symbol;
        collectionDescription = description;
        _baseTokenURI = baseTokenURI;
        creator = msg.sender;
        
        // Set default royalty
        _setDefaultRoyalty(royaltyReceiver, royaltyFeeNumerator);
    }
    
    /**
     * @dev Mints a new NFT
     * @param to Address to mint the NFT to
     * @param tokenURI URI for token metadata
     * @return tokenId ID of the minted token
     */
    function mint(address to, string memory tokenURI) public whenNotPaused nonReentrant returns (uint256) {
        require(to != address(0), "GhalbirNFT: mint to the zero address");
        
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI);
        
        emit NFTMinted(tokenId, msg.sender, to, tokenURI);
        
        return tokenId;
    }
    
    /**
     * @dev Mints a new NFT with custom royalty
     * @param to Address to mint the NFT to
     * @param tokenURI URI for token metadata
     * @param royaltyReceiver Address to receive royalties
     * @param royaltyFeeNumerator Royalty fee in basis points (e.g., 1000 = 10%)
     * @return tokenId ID of the minted token
     */
    function mintWithRoyalty(
        address to,
        string memory tokenURI,
        address royaltyReceiver,
        uint96 royaltyFeeNumerator
    ) public whenNotPaused nonReentrant returns (uint256) {
        uint256 tokenId = mint(to, tokenURI);
        _setTokenRoyalty(tokenId, royaltyReceiver, royaltyFeeNumerator);
        
        emit RoyaltySet(tokenId, royaltyReceiver, royaltyFeeNumerator);
        
        return tokenId;
    }
    
    /**
     * @dev Burns a token
     * @param tokenId ID of the token to burn
     */
    function burn(uint256 tokenId) public whenNotPaused {
        require(_isApprovedOrOwner(msg.sender, tokenId), "GhalbirNFT: caller is not owner nor approved");
        _burn(tokenId);
    }
    
    /**
     * @dev Sets the base URI for all token metadata
     * @param baseTokenURI New base URI
     */
    function setBaseURI(string memory baseTokenURI) public onlyOwner {
        _baseTokenURI = baseTokenURI;
        emit BaseURIChanged(baseTokenURI);
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
        require(_isApprovedOrOwner(msg.sender, tokenId), "GhalbirNFT: caller is not owner nor approved");
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
     * @dev Gets the total number of tokens minted
     * @return Total supply
     */
    function totalMinted() public view returns (uint256) {
        return _tokenIdCounter.current();
    }
    
    /**
     * @dev Gets the base URI for token metadata
     * @return Base URI
     */
    function baseURI() public view returns (string memory) {
        return _baseURI();
    }
    
    /**
     * @dev Gets the token URI
     * @param tokenId ID of the token
     * @return Token URI
     */
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    
    /**
     * @dev Gets the tokens owned by an address
     * @param owner Address to query
     * @return Array of token IDs
     */
    function tokensOfOwner(address owner) public view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(owner);
        uint256[] memory tokenIds = new uint256[](tokenCount);
        
        for (uint256 i = 0; i < tokenCount; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }
        
        return tokenIds;
    }
    
    /**
     * @dev Base URI for computing {tokenURI}
     * @return Base URI
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    /**
     * @dev Hook that is called before any token transfer
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) whenNotPaused {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }
    
    /**
     * @dev Burns a token
     * @param tokenId ID of the token to burn
     */
    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage, ERC721Royalty) {
        super._burn(tokenId);
    }
    
    /**
     * @dev Required override for inherited contracts
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable, ERC721URIStorage, ERC721Royalty) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
