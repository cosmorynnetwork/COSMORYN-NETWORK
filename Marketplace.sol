// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Marketplace
 * @dev Non-custodial marketplace for COSMORYN NETWORK ERC-1155 NFTs on Ethereum with multi-currency payment (ETH / CMR) and protocol fees.
 */
contract Marketplace is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC1155 public immutable nftContract;
    IERC20 public immutable cmrToken;
    address public treasury;

    // Marketplace fee in basis points (250 = 2.5%)
    uint256 public feeBps = 250;

    struct Listing {
        uint256 listingId;
        address seller;
        uint256 tokenId;
        uint256 amount;
        uint256 pricePerUnit;
        address paymentToken; // address(0) for native ETH, or address(cmrToken)
        uint256 expiresAt;
        uint256 nonce;
        bool active;
    }

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => uint256) public listingNonce;
    mapping(address => mapping(uint256 => uint256)) public activeListedAmount;
    mapping(address => uint256) public pendingProceeds;

    event ItemListed(
        uint256 indexed listingId,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 pricePerUnit,
        address paymentToken
    );
    event ItemSold(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 tokenId,
        uint256 amount,
        uint256 totalPrice,
        uint256 protocolFee
    );
    event ListingCancelled(uint256 indexed listingId, address indexed seller);
    event ListingPriceUpdated(uint256 indexed listingId, uint256 newPricePerUnit, uint256 nonce);
    event ItemDelisted(uint256 indexed listingId, string reason);
    event FeeUpdated(uint256 newFeeBps);
    event TreasuryUpdated(address indexed newTreasury);
    event SellerProceedsHeld(address indexed seller, uint256 amount);
    event ProceedsWithdrawn(address indexed seller, uint256 amount);

    constructor(
        IERC1155 _nftContract,
        IERC20 _cmrToken,
        address _treasury,
        address admin
    ) {
        require(address(_nftContract) != address(0), "Invalid NFT contract");
        require(address(_cmrToken) != address(0), "Invalid token");
        require(_treasury != address(0), "Invalid treasury");
        require(admin != address(0), "Invalid admin");

        nftContract = _nftContract;
        cmrToken = _cmrToken;
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MODERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    function createListing(
        uint256 tokenId,
        uint256 amount,
        uint256 pricePerUnit,
        address paymentToken,
        uint256 durationSeconds
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(amount > 0, "Amount must be > 0");
        require(pricePerUnit > 0, "Price must be > 0");
        require(paymentToken == address(0) || paymentToken == address(cmrToken), "Unsupported payment token");
        require(durationSeconds > 0 && durationSeconds <= 90 days, "Invalid duration");
        require(
            nftContract.balanceOf(msg.sender, tokenId) >= activeListedAmount[msg.sender][tokenId] + amount,
            "Insufficient NFT balance"
        );
        require(nftContract.isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        activeListedAmount[msg.sender][tokenId] += amount;

        uint256 listingId = nextListingId++;
        listings[listingId] = Listing({
            listingId: listingId,
            seller: msg.sender,
            tokenId: tokenId,
            amount: amount,
            pricePerUnit: pricePerUnit,
            paymentToken: paymentToken,
            expiresAt: block.timestamp + durationSeconds,
            nonce: 0,
            active: true
        });

        emit ItemListed(listingId, msg.sender, tokenId, amount, pricePerUnit, paymentToken);
        return listingId;
    }

    function updateListingPrice(uint256 listingId, uint256 newPricePerUnit) external whenNotPaused nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing inactive");
        require(block.timestamp <= listing.expiresAt, "Listing expired");
        require(listing.seller == msg.sender, "Not seller");
        require(newPricePerUnit > 0, "Price must be > 0");
        require(nftContract.balanceOf(msg.sender, listing.tokenId) >= listing.amount, "Seller balance moved");
        listing.pricePerUnit = newPricePerUnit;
        listing.nonce += 1;
        listingNonce[listingId] = listing.nonce;
        emit ListingPriceUpdated(listingId, newPricePerUnit, listing.nonce);
    }

    function buyItem(uint256 listingId, uint256 amountToBuy) external payable whenNotPaused nonReentrant {
        _buyItem(listingId, amountToBuy);
    }

    function buyItemWithMaxPrice(
        uint256 listingId,
        uint256 amountToBuy,
        uint256 maxPricePerUnit
    ) external payable whenNotPaused nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.pricePerUnit <= maxPricePerUnit, "Price exceeds max slippage");
        _buyItem(listingId, amountToBuy);
    }

    function _buyItem(uint256 listingId, uint256 amountToBuy) internal {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing inactive");
        require(block.timestamp <= listing.expiresAt, "Listing expired");
        require(amountToBuy > 0 && amountToBuy <= listing.amount, "Invalid buy amount");
        require(listing.seller != msg.sender, "Seller cannot buy own item");
        require(nftContract.balanceOf(listing.seller, listing.tokenId) >= amountToBuy, "Seller balance moved");

        uint256 totalPrice = listing.pricePerUnit * amountToBuy;
        uint256 fee = (totalPrice * feeBps) / 10000;

        address paymentToken = listing.paymentToken;
        address seller = listing.seller;
        uint256 tokenId = listing.tokenId;

        // Checks-Effects-Interactions (CEI): mutate state before external calls
        listing.amount -= amountToBuy;
        if (listing.amount == 0) {
            listing.active = false;
        }
        if (activeListedAmount[seller][tokenId] >= amountToBuy) {
            activeListedAmount[seller][tokenId] -= amountToBuy;
        } else {
            activeListedAmount[seller][tokenId] = 0;
        }

        emit ItemSold(listingId, msg.sender, seller, tokenId, amountToBuy, totalPrice, fee);

        // Deliver NFT to buyer first (validates seller approval & balance before moving funds)
        nftContract.safeTransferFrom(seller, msg.sender, tokenId, amountToBuy, "");

        address royaltyReceiver = address(0);
        uint256 royaltyAmount = 0;
        try IERC2981(address(nftContract)).royaltyInfo(tokenId, totalPrice) returns (address receiver, uint256 royalty) {
            if (receiver != address(0) && royalty > 0 && royalty < (totalPrice - fee)) {
                royaltyReceiver = receiver;
                royaltyAmount = royalty;
            }
        } catch {}

        _processPayment(paymentToken, seller, totalPrice, fee, royaltyReceiver, royaltyAmount);
    }

    function _processPayment(
        address paymentToken,
        address seller,
        uint256 _totalPrice,
        uint256 fee,
        address royaltyReceiver,
        uint256 royaltyAmount
    ) internal {
        if (fee > _totalPrice) {
            fee = _totalPrice;
        }
        if (fee + royaltyAmount > _totalPrice) {
            royaltyAmount = _totalPrice - fee;
        }
        uint256 sellerProceeds = _totalPrice - fee - royaltyAmount;

        if (paymentToken == address(0)) {
            // Payment in Native ETH (pull-friendly: treat treasury/seller failures as sale failure, no stuck state)
            require(msg.value >= _totalPrice, "Insufficient ETH sent");

            (bool feeSent, ) = payable(treasury).call{ value: fee }("");
            require(feeSent, "ETH fee transfer failed");

            if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
                (bool royaltySent, ) = payable(royaltyReceiver).call{ value: royaltyAmount }("");
                if (!royaltySent) {
                    pendingProceeds[royaltyReceiver] += royaltyAmount;
                    emit SellerProceedsHeld(royaltyReceiver, royaltyAmount);
                }
            }

            (bool sellerSent, ) = payable(seller).call{ value: sellerProceeds }("");
            if (!sellerSent) {
                pendingProceeds[seller] += sellerProceeds;
                emit SellerProceedsHeld(seller, sellerProceeds);
            }

            // Excess refund
            if (msg.value > _totalPrice) {
                (bool refundSent, ) = payable(msg.sender).call{ value: msg.value - _totalPrice }("");
                require(refundSent, "ETH refund failed");
            }
        } else {
            // Payment in CMR Token
            require(msg.value == 0, "ETH not accepted for token listing");
            cmrToken.safeTransferFrom(msg.sender, treasury, fee);
            if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
                cmrToken.safeTransferFrom(msg.sender, royaltyReceiver, royaltyAmount);
            }
            cmrToken.safeTransferFrom(msg.sender, seller, sellerProceeds);
        }
    }

    function cancelListing(uint256 listingId) external whenNotPaused nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing inactive");
        require(listing.seller == msg.sender, "Not seller");

        listing.active = false;
        if (activeListedAmount[listing.seller][listing.tokenId] >= listing.amount) {
            activeListedAmount[listing.seller][listing.tokenId] -= listing.amount;
        } else {
            activeListedAmount[listing.seller][listing.tokenId] = 0;
        }
        emit ListingCancelled(listingId, msg.sender);
    }

    function pruneExpiredListing(uint256 listingId) external whenNotPaused nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing inactive");
        require(block.timestamp > listing.expiresAt, "Listing not expired");

        listing.active = false;
        if (activeListedAmount[listing.seller][listing.tokenId] >= listing.amount) {
            activeListedAmount[listing.seller][listing.tokenId] -= listing.amount;
        } else {
            activeListedAmount[listing.seller][listing.tokenId] = 0;
        }
        emit ListingCancelled(listingId, listing.seller);
    }

    function pruneInvalidListing(uint256 listingId) external whenNotPaused nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing inactive");

        bool hasBalance = nftContract.balanceOf(listing.seller, listing.tokenId) >= listing.amount;
        bool hasApproval = nftContract.isApprovedForAll(listing.seller, address(this));

        require(!hasBalance || !hasApproval, "Listing is still valid");

        listing.active = false;
        if (activeListedAmount[listing.seller][listing.tokenId] >= listing.amount) {
            activeListedAmount[listing.seller][listing.tokenId] -= listing.amount;
        } else {
            activeListedAmount[listing.seller][listing.tokenId] = 0;
        }
        emit ListingCancelled(listingId, listing.seller);
    }

    function withdrawProceeds() external nonReentrant {
        uint256 amount = pendingProceeds[msg.sender];
        require(amount > 0, "No proceeds to withdraw");
        pendingProceeds[msg.sender] = 0;
        (bool sent, ) = payable(msg.sender).call{ value: amount }("");
        require(sent, "ETH withdraw failed");
        emit ProceedsWithdrawn(msg.sender, amount);
    }

    function moderateDelist(uint256 listingId, string calldata reason) external onlyRole(MODERATOR_ROLE) {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing inactive");

        listing.active = false;
        if (activeListedAmount[listing.seller][listing.tokenId] >= listing.amount) {
            activeListedAmount[listing.seller][listing.tokenId] -= listing.amount;
        } else {
            activeListedAmount[listing.seller][listing.tokenId] = 0;
        }
        emit ItemDelisted(listingId, reason);
    }

    function setFeeBps(uint256 _feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeBps <= 1000, "Fee cannot exceed 10%");
        feeBps = _feeBps;
        emit FeeUpdated(_feeBps);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
