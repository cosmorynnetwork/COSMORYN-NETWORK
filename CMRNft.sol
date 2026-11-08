// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Pausable.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CMRNft
 * @dev Multi-token ERC1155 gaming assets (characters, weapons, land, vehicles, collectibles) for COSMORYN NETWORK ecosystem with EIP-2981 royalty support.
 */
contract CMRNft is ERC1155, ERC1155Pausable, ERC1155Supply, AccessControl, ERC2981 {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    string public name = "COSMORYN NETWORK NFT";
    string public symbol = "CMRNFT";

    uint256 public constant MAX_SUPPLY_PER_ID = 1_000_000;
    bool public uriFrozen;

    mapping(uint256 => string) private _tokenUris;

    event NFTMinted(address indexed to, uint256 indexed id, uint256 amount);
    event NFTBatchMinted(address indexed to, uint256[] ids, uint256[] amounts);
    event TokenURIUpdated(uint256 indexed tokenId, string newUri);
    event URIFrozen();

    constructor(string memory baseUri, address admin) ERC1155(baseUri) {
        require(admin != address(0), "Invalid admin");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be > 0");
        require(totalSupply(id) + amount <= MAX_SUPPLY_PER_ID, "Supply cap exceeded");
        _mint(to, id, amount, data);
        emit NFTMinted(to, id, amount);
    }

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "Invalid recipient");
        require(ids.length == amounts.length && ids.length > 0, "Length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            require(amounts[i] > 0, "Amount must be > 0");
            require(totalSupply(ids[i]) + amounts[i] <= MAX_SUPPLY_PER_ID, "Supply cap exceeded");
        }
        _mintBatch(to, ids, amounts, data);
        emit NFTBatchMinted(to, ids, amounts);
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(from == msg.sender || isApprovedForAll(from, msg.sender), "Not authorized");
        _burn(from, id, amount);
    }

    function freezeURI() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uriFrozen = true;
        emit URIFrozen();
    }

    function setURI(string memory newuri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!uriFrozen, "URI frozen");
        _setURI(newuri);
    }

    function setTokenURI(uint256 tokenId, string memory tokenUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!uriFrozen, "URI frozen");
        _tokenUris[tokenId] = tokenUri;
        emit TokenURIUpdated(tokenId, tokenUri);
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        string memory tokenUri = _tokenUris[tokenId];
        if (bytes(tokenUri).length > 0) {
            return tokenUri;
        }
        return super.uri(tokenId);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Pausable, ERC1155Supply) {
        super._update(from, to, ids, values);
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 feeNumerator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
