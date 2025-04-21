// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
 * @title GhalbirMarketplace
 * @dev NFT marketplace for buying and selling NFTs on the Ghalbir blockchain
 */
contract GhalbirMarketplace is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;
    
    // Listing counter
    Counters.Counter private _listingIdCounter;
    
    // Auction counter
    Counters.Counter private _auctionIdCounter;
    
    // Offer counter
    Counters.Counter private _offerIdCounter;
    
    // Platform fee percentage (in basis points, e.g., 250 = 2.5%)
    uint256 public platformFeePercentage = 250;
    
    // Platform fee recipient
    address public feeRecipient;
    
    // Minimum auction duration (in seconds)
    uint256 public minAuctionDuration = 1 days;
    
    // Maximum auction duration (in seconds)
    uint256 public maxAuctionDuration = 30 days;
    
    // Minimum bid increment percentage (in basis points, e.g., 500 = 5%)
    uint256 public minBidIncrementPercentage = 500;
    
    // Supported payment tokens
    mapping(address => bool) public supportedPaymentTokens;
    
    // Native token (GBR)
    address public constant NATIVE_TOKEN = address(0);
    
    // Listing status enum
    enum ListingStatus { Active, Sold, Canceled }
    
    // Auction status enum
    enum AuctionStatus { Active, Ended, Canceled }
    
    // Token type enum
    enum TokenType { ERC721, ERC1155 }
    
    // Listing struct
    struct Listing {
        uint256 listingId;
        address seller;
        address tokenAddress;
        uint256 tokenId;
        uint256 quantity;
        address paymentToken;
        uint256 price;
        ListingStatus status;
        TokenType tokenType;
    }
    
    // Auction struct
    struct Auction {
        uint256 auctionId;
        address seller;
        address tokenAddress;
        uint256 tokenId;
        uint256 quantity;
        address paymentToken;
        uint256 startingPrice;
        uint256 reservePrice;
        uint256 currentBid;
        address currentBidder;
        uint256 startTime;
        uint256 endTime;
        AuctionStatus status;
        TokenType tokenType;
    }
    
    // Offer struct
    struct Offer {
        uint256 offerId;
        address buyer;
        address tokenAddress;
        uint256 tokenId;
        uint256 quantity;
        address paymentToken;
        uint256 price;
        uint256 expirationTime;
        bool accepted;
        bool canceled;
        TokenType tokenType;
    }
    
    // Mappings
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Offer) public offers;
    
    // Events
    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address indexed tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 price,
        TokenType tokenType
    );
    
    event ListingUpdated(
        uint256 indexed listingId,
        uint256 price
    );
    
    event ListingSold(
        uint256 indexed listingId,
        address indexed seller,
        address indexed buyer,
        address tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 price
    );
    
    event ListingCanceled(
        uint256 indexed listingId
    );
    
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 startingPrice,
        uint256 reservePrice,
        uint256 startTime,
        uint256 endTime,
        TokenType tokenType
    );
    
    event AuctionBid(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 bid
    );
    
    event AuctionEnded(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed winner,
        address tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 winningBid
    );
    
    event AuctionCanceled(
        uint256 indexed auctionId
    );
    
    event OfferCreated(
        uint256 indexed offerId,
        address indexed buyer,
        address indexed tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 price,
        uint256 expirationTime,
        TokenType tokenType
    );
    
    event OfferAccepted(
        uint256 indexed offerId,
        address indexed seller,
        address indexed buyer,
        address tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 price
    );
    
    event OfferCanceled(
        uint256 indexed offerId
    );
    
    event PlatformFeePercentageUpdated(
        uint256 platformFeePercentage
    );
    
    event FeeRecipientUpdated(
        address feeRecipient
    );
    
    event PaymentTokenStatusUpdated(
        address paymentToken,
        bool supported
    );
    
    /**
     * @dev Constructor
     * @param _feeRecipient Address to receive platform fees
     */
    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "GhalbirMarketplace: fee recipient cannot be zero address");
        feeRecipient = _feeRecipient;
        
        // Add native token as supported payment token
        supportedPaymentTokens[NATIVE_TOKEN] = true;
    }
    
    /**
     * @dev Creates a new listing
     * @param tokenAddress Address of the NFT contract
     * @param tokenId ID of the token
     * @param quantity Quantity to sell (always 1 for ERC721)
     * @param paymentToken Address of the payment token (address(0) for native token)
     * @param price Listing price
     * @param tokenType Type of token (ERC721 or ERC1155)
     * @return listingId ID of the created listing
     */
    function createListing(
        address tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 price,
        TokenType tokenType
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(tokenAddress != address(0), "GhalbirMarketplace: token address cannot be zero");
        require(quantity > 0, "GhalbirMarketplace: quantity must be greater than zero");
        require(price > 0, "GhalbirMarketplace: price must be greater than zero");
        require(supportedPaymentTokens[paymentToken], "GhalbirMarketplace: payment token not supported");
        
        // Validate token type
        if (tokenType == TokenType.ERC721) {
            require(quantity == 1, "GhalbirMarketplace: quantity must be 1 for ERC721");
            require(IERC721(tokenAddress).ownerOf(tokenId) == msg.sender, "GhalbirMarketplace: not token owner");
            require(IERC721(tokenAddress).isApprovedForAll(msg.sender, address(this)), "GhalbirMarketplace: not approved");
        } else if (tokenType == TokenType.ERC1155) {
            require(IERC1155(tokenAddress).balanceOf(msg.sender, tokenId) >= quantity, "GhalbirMarketplace: insufficient token balance");
            require(IERC1155(tokenAddress).isApprovedForAll(msg.sender, address(this)), "GhalbirMarketplace: not approved");
        } else {
            revert("GhalbirMarketplace: invalid token type");
        }
        
        // Create listing
        uint256 listingId = _listingIdCounter.current();
        _listingIdCounter.increment();
        
        listings[listingId] = Listing({
            listingId: listingId,
            seller: msg.sender,
            tokenAddress: tokenAddress,
            tokenId: tokenId,
            quantity: quantity,
            paymentToken: paymentToken,
            price: price,
            status: ListingStatus.Active,
            tokenType: tokenType
        });
        
        emit ListingCreated(
            listingId,
            msg.sender,
            tokenAddress,
            tokenId,
            quantity,
            paymentToken,
            price,
            tokenType
        );
        
        return listingId;
    }
    
    /**
     * @dev Updates a listing price
     * @param listingId ID of the listing
     * @param newPrice New listing price
     */
    function updateListing(uint256 listingId, uint256 newPrice) external whenNotPaused nonReentrant {
        require(newPrice > 0, "GhalbirMarketplace: price must be greater than zero");
        
        Listing storage listing = listings[listingId];
        require(listing.seller == msg.sender, "GhalbirMarketplace: not listing seller");
        require(listing.status == ListingStatus.Active, "GhalbirMarketplace: listing not active");
        
        listing.price = newPrice;
        
        emit ListingUpdated(listingId, newPrice);
    }
    
    /**
     * @dev Cancels a listing
     * @param listingId ID of the listing
     */
    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.seller == msg.sender || msg.sender == owner(), "GhalbirMarketplace: not listing seller or owner");
        require(listing.status == ListingStatus.Active, "GhalbirMarketplace: listing not active");
        
        listing.status = ListingStatus.Canceled;
        
        emit ListingCanceled(listingId);
    }
    
    /**
     * @dev Buys a listed NFT
     * @param listingId ID of the listing
     */
    function buyListing(uint256 listingId) external payable whenNotPaused nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.Active, "GhalbirMarketplace: listing not active");
        
        // Process payment
        uint256 platformFee = (listing.price * platformFeePercentage) / 10000;
        uint256 sellerAmount = listing.price - platformFee;
        
        if (listing.paymentToken == NATIVE_TOKEN) {
            require(msg.value == listing.price, "GhalbirMarketplace: incorrect payment amount");
            
            // Transfer platform fee
            (bool feeSuccess, ) = feeRecipient.call{value: platformFee}("");
            require(feeSuccess, "GhalbirMarketplace: fee transfer failed");
            
            // Transfer seller amount
            (bool sellerSuccess, ) = listing.seller.call{value: sellerAmount}("");
            require(sellerSuccess, "GhalbirMarketplace: seller transfer failed");
        } else {
            require(msg.value == 0, "GhalbirMarketplace: native token not accepted");
            
            // Transfer payment token from buyer to this contract
            IERC20(listing.paymentToken).safeTransferFrom(msg.sender, address(this), listing.price);
            
            // Transfer platform fee
            IERC20(listing.paymentToken).safeTransfer(feeRecipient, platformFee);
            
            // Transfer seller amount
            IERC20(listing.paymentToken).safeTransfer(listing.seller, sellerAmount);
        }
        
        // Transfer NFT to buyer
        if (listing.tokenType == TokenType.ERC721) {
            IERC721(listing.tokenAddress).safeTransferFrom(listing.seller, msg.sender, listing.tokenId);
        } else {
            IERC1155(listing.tokenAddress).safeTransferFrom(listing.seller, msg.sender, listing.tokenId, listing.quantity, "");
        }
        
        // Update listing status
        listing.status = ListingStatus.Sold;
        
        emit ListingSold(
            listingId,
            listing.seller,
            msg.sender,
            listing.tokenAddress,
            listing.tokenId,
            listing.quantity,
            listing.paymentToken,
            listing.price
        );
    }
    
    /**
     * @dev Creates a new auction
     * @param tokenAddress Address of the NFT contract
     * @param tokenId ID of the token
     * @param quantity Quantity to auction (always 1 for ERC721)
     * @param paymentToken Address of the payment token (address(0) for native token)
     * @param startingPrice Starting price for the auction
     * @param reservePrice Reserve price for the auction (0 for no reserve)
     * @param duration Duration of the auction in seconds
     * @param tokenType Type of token (ERC721 or ERC1155)
     * @return auctionId ID of the created auction
     */
    function createAuction(
        address tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 startingPrice,
        uint256 reservePrice,
        uint256 duration,
        TokenType tokenType
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(tokenAddress != address(0), "GhalbirMarketplace: token address cannot be zero");
        require(quantity > 0, "GhalbirMarketplace: quantity must be greater than zero");
        require(startingPrice > 0, "GhalbirMarketplace: starting price must be greater than zero");
        require(reservePrice >= startingPrice, "GhalbirMarketplace: reserve price must be greater than or equal to starting price");
        require(duration >= minAuctionDuration, "GhalbirMarketplace: duration too short");
        require(duration <= maxAuctionDuration, "GhalbirMarketplace: duration too long");
        require(supportedPaymentTokens[paymentToken], "GhalbirMarketplace: payment token not supported");
        
        // Validate token type
        if (tokenType == TokenType.ERC721) {
            require(quantity == 1, "GhalbirMarketplace: quantity must be 1 for ERC721");
            require(IERC721(tokenAddress).ownerOf(tokenId) == msg.sender, "GhalbirMarketplace: not token owner");
            require(IERC721(tokenAddress).isApprovedForAll(msg.sender, address(this)), "GhalbirMarketplace: not approved");
        } else if (tokenType == TokenType.ERC1155) {
            require(IERC1155(tokenAddress).balanceOf(msg.sender, tokenId) >= quantity, "GhalbirMarketplace: insufficient token balance");
            require(IERC1155(tokenAddress).isApprovedForAll(msg.sender, address(this)), "GhalbirMarketplace: not approved");
        } else {
            revert("GhalbirMarketplace: invalid token type");
        }
        
        // Create auction
        uint256 auctionId = _auctionIdCounter.current();
        _auctionIdCounter.increment();
        
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + duration;
        
        auctions[auctionId] = Auction({
            auctionId: auctionId,
            seller: msg.sender,
            tokenAddress: tokenAddress,
            tokenId: tokenId,
            quantity: quantity,
            paymentToken: paymentToken,
            startingPrice: startingPrice,
            reservePrice: reservePrice,
            currentBid: 0,
            currentBidder: address(0),
            startTime: startTime,
            endTime: endTime,
            status: AuctionStatus.Active,
            tokenType: tokenType
        });
        
        emit AuctionCreated(
            auctionId,
            msg.sender,
            tokenAddress,
            tokenId,
            quantity,
            paymentToken,
            startingPrice,
            reservePrice,
            startTime,
            endTime,
            tokenType
        );
        
        return auctionId;
    }
    
    /**
     * @dev Places a bid on an auction
     * @param auctionId ID of the auction
     * @param bidAmount Bid amount
     */
    function placeBid(uint256 auctionId, uint256 bidAmount) external payable whenNotPaused nonReentrant {
        Auction storage auction = auctions[auctionId];
        require(auction.status == AuctionStatus.Active, "GhalbirMarketplace: auction not active");
        require(block.timestamp >= auction.startTime, "GhalbirMarketplace: auction not started");
        require(block.timestamp <= auction.endTime, "GhalbirMarketplace: auction ended");
        require(msg.sender != auction.seller, "GhalbirMarketplace: seller cannot bid");
        
        // Check if this is the first bid
        if (auction.currentBid == 0) {
            require(bidAmount >= auction.startingPrice, "GhalbirMarketplace: bid too low");
        } else {
            // Calculate minimum bid increment
            uint256 minBidAmount = auction.currentBid + (auction.currentBid * minBidIncrementPercentage / 10000);
            require(bidAmount >= minBidAmount, "GhalbirMarketplace: bid too low");
            
            // Refund previous bidder
            if (auction.currentBidder != address(0)) {
                if (auction.paymentToken == NATIVE_TOKEN) {
                    (bool success, ) = auction.currentBidder.call{value: auction.currentBid}("");
                    require(success, "GhalbirMarketplace: refund failed");
                } else {
                    IERC20(auction.paymentToken).safeTransfer(auction.currentBidder, auction.currentBid);
                }
            }
        }
        
        // Process payment
        if (auction.paymentToken == NATIVE_TOKEN) {
            require(msg.value == bidAmount, "GhalbirMarketplace: incorrect payment amount");
        } else {
            require(msg.value == 0, "GhalbirMarketplace: native token not accepted");
            IERC20(auction.paymentToken).safeTransferFrom(msg.sender, address(this), bidAmount);
        }
        
        // Update auction
        auction.currentBid = bidAmount;
        auction.currentBidder = msg.sender;
        
        // Extend auction if bid is placed in the last 10 minutes
        if (auction.endTime - block.timestamp < 10 minutes) {
            auction.endTime = block.timestamp + 10 minutes;
        }
        
        emit AuctionBid(auctionId, msg.sender, bidAmount);
    }
    
    /**
     * @dev Ends an auction
     * @param auctionId ID of the auction
     */
    function endAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        require(auction.status == AuctionStatus.Active, "GhalbirMarketplace: auction not active");
        require(block.timestamp > auction.endTime, "GhalbirMarketplace: auction not ended");
        
        // Check if there was a winning bid
        if (auction.currentBidder != address(0) && auction.currentBid >= auction.reservePrice) {
            // Calculate platform fee
            uint256 platformFee = (auction.currentBid * platformFeePercentage) / 10000;
            uint256 sellerAmount = auction.currentBid - platformFee;
            
            // Transfer platform fee
            if (auction.paymentToken == NATIVE_TOKEN) {
                (bool feeSuccess, ) = feeRecipient.call{value: platformFee}("");
                require(feeSuccess, "GhalbirMarketplace: fee transfer failed");
                
                // Transfer seller amount
                (bool sellerSuccess, ) = auction.seller.call{value: sellerAmount}("");
                require(sellerSuccess, "GhalbirMarketplace: seller transfer failed");
            } else {
                IERC20(auction.paymentToken).safeTransfer(feeRecipient, platformFee);
                IERC20(auction.paymentToken).safeTransfer(auction.seller, sellerAmount);
            }
            
            // Transfer NFT to winner
            if (auction.tokenType == TokenType.ERC721) {
                IERC721(auction.tokenAddress).safeTransferFrom(auction.seller, auction.currentBidder, auction.tokenId);
            } else {
                IERC1155(auction.tokenAddress).safeTransferFrom(auction.seller, auction.currentBidder, auction.tokenId, auction.quantity, "");
            }
            
            emit AuctionEnded(
                auctionId,
                auction.seller,
                auction.currentBidder,
                auction.tokenAddress,
                auction.tokenId,
                auction.quantity,
                auction.paymentToken,
                auction.currentBid
            );
        } else {
            // No winning bid, refund current bidder if there was a bid
            if (auction.currentBidder != address(0)) {
                if (auction.paymentToken == NATIVE_TOKEN) {
                    (bool success, ) = auction.currentBidder.call{value: auction.currentBid}("");
                    require(success, "GhalbirMarketplace: refund failed");
                } else {
                    IERC20(auction.paymentToken).safeTransfer(auction.currentBidder, auction.currentBid);
                }
            }
            
            emit AuctionCanceled(auctionId);
        }
        
        // Update auction status
        auction.status = AuctionStatus.Ended;
    }
    
    /**
     * @dev Cancels an auction
     * @param auctionId ID of the auction
     */
    function cancelAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = auctions[auctionId];
        require(auction.seller == msg.sender || msg.sender == owner(), "GhalbirMarketplace: not auction seller or owner");
        require(auction.status == AuctionStatus.Active, "GhalbirMarketplace: auction not active");
        require(auction.currentBidder == address(0), "GhalbirMarketplace: auction has bids");
        
        auction.status = AuctionStatus.Canceled;
        
        emit AuctionCanceled(auctionId);
    }
    
    /**
     * @dev Creates an offer for an NFT
     * @param tokenAddress Address of the NFT contract
     * @param tokenId ID of the token
     * @param quantity Quantity to offer (always 1 for ERC721)
     * @param paymentToken Address of the payment token (address(0) for native token)
     * @param price Offer price
     * @param expirationTime Expiration time for the offer
     * @param tokenType Type of token (ERC721 or ERC1155)
     * @return offerId ID of the created offer
     */
    function createOffer(
        address tokenAddress,
        uint256 tokenId,
        uint256 quantity,
        address paymentToken,
        uint256 price,
        uint256 expirationTime,
        TokenType tokenType
    ) external payable whenNotPaused nonReentrant returns (uint256) {
        require(tokenAddress != address(0), "GhalbirMarketplace: token address cannot be zero");
        require(quantity > 0, "GhalbirMarketplace: quantity must be greater than zero");
        require(price > 0, "GhalbirMarketplace: price must be greater than zero");
        require(expirationTime > block.timestamp, "GhalbirMarketplace: expiration time must be in the future");
        require(supportedPaymentTokens[paymentToken], "GhalbirMarketplace: payment token not supported");
        
        // Validate token type
        if (tokenType == TokenType.ERC721) {
            require(quantity == 1, "GhalbirMarketplace: quantity must be 1 for ERC721");
            address tokenOwner = IERC721(tokenAddress).ownerOf(tokenId);
            require(tokenOwner != msg.sender, "GhalbirMarketplace: cannot make offer on own token");
        } else if (tokenType == TokenType.ERC1155) {
            // No specific validation for ERC1155 offers
        } else {
            revert("GhalbirMarketplace: invalid token type");
        }
        
        // Process payment
        if (paymentToken == NATIVE_TOKEN) {
            require(msg.value == price, "GhalbirMarketplace: incorrect payment amount");
        } else {
            require(msg.value == 0, "GhalbirMarketplace: native token not accepted");
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);
        }
        
        // Create offer
        uint256 offerId = _offerIdCounter.current();
        _offerIdCounter.increment();
        
        offers[offerId] = Offer({
            offerId: offerId,
            buyer: msg.sender,
            tokenAddress: tokenAddress,
            tokenId: tokenId,
            quantity: quantity,
            paymentToken: paymentToken,
            price: price,
            expirationTime: expirationTime,
            accepted: false,
            canceled: false,
            tokenType: tokenType
        });
        
        emit OfferCreated(
            offerId,
            msg.sender,
            tokenAddress,
            tokenId,
            quantity,
            paymentToken,
            price,
            expirationTime,
            tokenType
        );
        
        return offerId;
    }
    
    /**
     * @dev Accepts an offer
     * @param offerId ID of the offer
     */
    function acceptOffer(uint256 offerId) external whenNotPaused nonReentrant {
        Offer storage offer = offers[offerId];
        require(!offer.accepted, "GhalbirMarketplace: offer already accepted");
        require(!offer.canceled, "GhalbirMarketplace: offer canceled");
        require(block.timestamp <= offer.expirationTime, "GhalbirMarketplace: offer expired");
        
        // Validate token ownership
        if (offer.tokenType == TokenType.ERC721) {
            require(IERC721(offer.tokenAddress).ownerOf(offer.tokenId) == msg.sender, "GhalbirMarketplace: not token owner");
            require(IERC721(offer.tokenAddress).isApprovedForAll(msg.sender, address(this)), "GhalbirMarketplace: not approved");
        } else if (offer.tokenType == TokenType.ERC1155) {
            require(IERC1155(offer.tokenAddress).balanceOf(msg.sender, offer.tokenId) >= offer.quantity, "GhalbirMarketplace: insufficient token balance");
            require(IERC1155(offer.tokenAddress).isApprovedForAll(msg.sender, address(this)), "GhalbirMarketplace: not approved");
        } else {
            revert("GhalbirMarketplace: invalid token type");
        }
        
        // Calculate platform fee
        uint256 platformFee = (offer.price * platformFeePercentage) / 10000;
        uint256 sellerAmount = offer.price - platformFee;
        
        // Transfer platform fee
        if (offer.paymentToken == NATIVE_TOKEN) {
            (bool feeSuccess, ) = feeRecipient.call{value: platformFee}("");
            require(feeSuccess, "GhalbirMarketplace: fee transfer failed");
            
            // Transfer seller amount
            (bool sellerSuccess, ) = msg.sender.call{value: sellerAmount}("");
            require(sellerSuccess, "GhalbirMarketplace: seller transfer failed");
        } else {
            IERC20(offer.paymentToken).safeTransfer(feeRecipient, platformFee);
            IERC20(offer.paymentToken).safeTransfer(msg.sender, sellerAmount);
        }
        
        // Transfer NFT to buyer
        if (offer.tokenType == TokenType.ERC721) {
            IERC721(offer.tokenAddress).safeTransferFrom(msg.sender, offer.buyer, offer.tokenId);
        } else {
            IERC1155(offer.tokenAddress).safeTransferFrom(msg.sender, offer.buyer, offer.tokenId, offer.quantity, "");
        }
        
        // Update offer
        offer.accepted = true;
        
        emit OfferAccepted(
            offerId,
            msg.sender,
            offer.buyer,
            offer.tokenAddress,
            offer.tokenId,
            offer.quantity,
            offer.paymentToken,
            offer.price
        );
    }
    
    /**
     * @dev Cancels an offer
     * @param offerId ID of the offer
     */
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = offers[offerId];
        require(offer.buyer == msg.sender, "GhalbirMarketplace: not offer creator");
        require(!offer.accepted, "GhalbirMarketplace: offer already accepted");
        require(!offer.canceled, "GhalbirMarketplace: offer already canceled");
        
        // Refund payment
        if (offer.paymentToken == NATIVE_TOKEN) {
            (bool success, ) = offer.buyer.call{value: offer.price}("");
            require(success, "GhalbirMarketplace: refund failed");
        } else {
            IERC20(offer.paymentToken).safeTransfer(offer.buyer, offer.price);
        }
        
        // Update offer
        offer.canceled = true;
        
        emit OfferCanceled(offerId);
    }
    
    /**
     * @dev Sets the platform fee percentage
     * @param _platformFeePercentage New platform fee percentage (in basis points)
     */
    function setPlatformFeePercentage(uint256 _platformFeePercentage) external onlyOwner {
        require(_platformFeePercentage <= 1000, "GhalbirMarketplace: fee too high"); // Max 10%
        platformFeePercentage = _platformFeePercentage;
        emit PlatformFeePercentageUpdated(_platformFeePercentage);
    }
    
    /**
     * @dev Sets the fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "GhalbirMarketplace: fee recipient cannot be zero address");
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }
    
    /**
     * @dev Sets the minimum auction duration
     * @param _minAuctionDuration New minimum auction duration (in seconds)
     */
    function setMinAuctionDuration(uint256 _minAuctionDuration) external onlyOwner {
        require(_minAuctionDuration <= maxAuctionDuration, "GhalbirMarketplace: min duration cannot exceed max duration");
        minAuctionDuration = _minAuctionDuration;
    }
    
    /**
     * @dev Sets the maximum auction duration
     * @param _maxAuctionDuration New maximum auction duration (in seconds)
     */
    function setMaxAuctionDuration(uint256 _maxAuctionDuration) external onlyOwner {
        require(_maxAuctionDuration >= minAuctionDuration, "GhalbirMarketplace: max duration cannot be less than min duration");
        maxAuctionDuration = _maxAuctionDuration;
    }
    
    /**
     * @dev Sets the minimum bid increment percentage
     * @param _minBidIncrementPercentage New minimum bid increment percentage (in basis points)
     */
    function setMinBidIncrementPercentage(uint256 _minBidIncrementPercentage) external onlyOwner {
        require(_minBidIncrementPercentage > 0, "GhalbirMarketplace: increment must be greater than zero");
        minBidIncrementPercentage = _minBidIncrementPercentage;
    }
    
    /**
     * @dev Sets the supported status of a payment token
     * @param paymentToken Address of the payment token
     * @param supported Whether the token is supported
     */
    function setPaymentTokenSupported(address paymentToken, bool supported) external onlyOwner {
        supportedPaymentTokens[paymentToken] = supported;
        emit PaymentTokenStatusUpdated(paymentToken, supported);
    }
    
    /**
     * @dev Pauses the marketplace
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpauses the marketplace
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Gets active listings count
     * @return Count of active listings
     */
    function getActiveListingsCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _listingIdCounter.current(); i++) {
            if (listings[i].status == ListingStatus.Active) {
                count++;
            }
        }
        return count;
    }
    
    /**
     * @dev Gets active auctions count
     * @return Count of active auctions
     */
    function getActiveAuctionsCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < _auctionIdCounter.current(); i++) {
            if (auctions[i].status == AuctionStatus.Active) {
                count++;
            }
        }
        return count;
    }
    
    /**
     * @dev Checks if an offer is valid
     * @param offerId ID of the offer
     * @return True if the offer is valid
     */
    function isOfferValid(uint256 offerId) external view returns (bool) {
        Offer storage offer = offers[offerId];
        return !offer.accepted && !offer.canceled && block.timestamp <= offer.expirationTime;
    }
    
    /**
     * @dev Receive function to accept native token payments
     */
    receive() external payable {}
}
