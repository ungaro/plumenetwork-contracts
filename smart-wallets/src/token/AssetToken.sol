// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { SmartWallet } from "../SmartWallet.sol";
import { WalletUtils } from "../WalletUtils.sol";
import { IAssetToken } from "../interfaces/IAssetToken.sol";
import { YieldDistributionToken } from "./YieldDistributionToken.sol";

/**
 * @title AssetToken
 * @author Eugene Y. Q. Shen
 * @notice ERC20 token that represents a tokenized real world asset
 *   and distributes yield proportionally to token holders
 */
contract AssetToken is WalletUtils, YieldDistributionToken, IAssetToken {

    // Storage

    /// @custom:storage-location erc7201:plume.storage.AssetToken
    struct AssetTokenStorage {
        /// @dev Total value of all circulating AssetTokens
        uint256 totalValue;
        /// @dev Boolean to enable whitelist for the AssetToken
        bool isWhitelistEnabled;
        /// @dev Whitelist of users that are allowed to hold AssetTokens
        address[] whitelist;
        /// @dev Mapping of whitelisted users
        mapping(address user => bool whitelisted) isWhitelisted;
        /// @dev List of all users that have ever held AssetTokens
        address[] holders;
        /// @dev Mapping of all users that have ever held AssetTokens
        mapping(address user => bool held) hasHeld;
    }

    // keccak256(abi.encode(uint256(keccak256("plume.storage.AssetToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSET_TOKEN_STORAGE_LOCATION =
        0x726dfad64e66a3008dc13dfa01e6342ee01974bb72e1b2f461563ca13356d800;

    function _getAssetTokenStorage() private pure returns (AssetTokenStorage storage $) {
        assembly {
            $.slot := ASSET_TOKEN_STORAGE_LOCATION
        }
    }

    // Events

    /**
     * @notice Emitted when a user is added to the whitelist
     * @param user Address of the user that is added to the whitelist
     */
    event AddressAddedToWhitelist(address indexed user);

    /**
     * @notice Emitted when a user is removed from the whitelist
     * @param user Address of the user that is removed from the whitelist
     */
    event AddressRemovedFromWhitelist(address indexed user);

    // Errors

    /**
     * @notice Indicates a failure because the user is not whitelisted
     * @param user Address of the user that is not whitelisted
     */
    error Unauthorized(address user);

    /**
     * @notice Indicates a failure because the user has insufficient balance
     * @param user Address of the user that has insufficient balance
     */
    error InsufficientBalance(address user);

    /// @notice Indicates a failure because the given address is 0x0
    error InvalidAddress();

    /**
     * @notice Indicates a failure because the user is already whitelisted
     * @param user Address of the user that is already whitelisted
     */
    error AddressAlreadyWhitelisted(address user);

    /**
     * @notice Indicates a failure because the user is not whitelisted
     * @param user Address of the user that is not whitelisted
     */
    error AddressNotWhitelisted(address user);

    /**
     * @notice Indicates a failure because the user's SmartWallet call failed
     * @param user Address of the user whose SmartWallet call failed
     */
    error SmartWalletCallFailed(address user);

    // Constructor

    /**
     * @notice Construct the AssetToken
     * @param owner Address of the owner of the AssetToken
     * @param name Name of the AssetToken
     * @param symbol Symbol of the AssetToken
     * @param currencyToken Token in which the yield is deposited and denominated
     * @param decimals_ Number of decimals of the AssetToken
     * @param tokenURI_ URI of the AssetToken metadata
     * @param initialSupply Initial supply of the AssetToken
     * @param totalValue_ Total value of all circulating AssetTokens
     */
    constructor(
        address owner,
        string memory name,
        string memory symbol,
        ERC20 currencyToken,
        uint8 decimals_,
        string memory tokenURI_,
        uint256 initialSupply,
        uint256 totalValue_
    ) YieldDistributionToken(owner, name, symbol, currencyToken, decimals_, tokenURI_) {
        _getAssetTokenStorage().totalValue = totalValue_;
        _mint(owner, initialSupply);
    }

    // Override Functions

    /**
     * @notice Update the balance of `from` and `to` after token transfer and accrue yield
     * @dev Require that both parties are whitelisted and `from` has enough tokens
     * @param from Address to transfer tokens from
     * @param to Address to transfer tokens to
     * @param value Amount of tokens to transfer
     */
    function _update(address from, address to, uint256 value) internal override(YieldDistributionToken) {
        AssetTokenStorage storage $ = _getAssetTokenStorage();
        if ($.isWhitelistEnabled) {
            if (!$.isWhitelisted[from]) {
                revert Unauthorized(from);
            }
            if (!$.isWhitelisted[to]) {
                revert Unauthorized(to);
            }
        }

        if (from != address(0)) {
            if (getBalanceAvailable(from) < value) {
                revert InsufficientBalance(from);
            }
        }

        if (!$.hasHeld[to]) {
            $.holders.push(to);
            $.hasHeld[to] = true;
        }
        super._update(from, to, value);
    }

    // Admin Functions

    /**
     * @notice Update the total value of all circulating AssetTokens
     * @dev Only the owner can call this function
     */
    function setTotalValue(uint256 totalValue) external onlyOwner {
        _getAssetTokenStorage().totalValue = totalValue;
    }

    /**
     * @notice Enable the whitelist
     * @dev Only the owner can call this function
     */
    function enableWhitelist() external onlyOwner {
        _getAssetTokenStorage().isWhitelistEnabled = true;
    }

    /**
     * @notice Add a user to the whitelist
     * @dev Only the owner can call this function
     * @param user Address of the user to add to the whitelist
     */
    function addToWhitelist(address user) external onlyOwner {
        if (user == address(0)) {
            revert InvalidAddress();
        }

        AssetTokenStorage storage $ = _getAssetTokenStorage();
        if ($.isWhitelistEnabled) {
            if ($.isWhitelisted[user]) {
                revert AddressAlreadyWhitelisted(user);
            }
            $.whitelist.push(user);
            $.isWhitelisted[user] = true;
            emit AddressAddedToWhitelist(user);
        }
    }

    /**
     * @notice Remove a user from the whitelist
     * @dev Only the owner can call this function
     * @param user Address of the user to remove from the whitelist
     */
    function removeFromWhitelist(address user) external onlyOwner {
        if (user == address(0)) {
            revert InvalidAddress();
        }

        AssetTokenStorage storage $ = _getAssetTokenStorage();
        if ($.isWhitelistEnabled) {
            if (!$.isWhitelisted[user]) {
                revert AddressNotWhitelisted(user);
            }
            uint256 length = $.whitelist.length;
            for (uint256 i = 0; i < length; i++) {
                if ($.whitelist[i] == user) {
                    $.whitelist[i] = $.whitelist[length - 1];
                    $.whitelist.pop();
                    break;
                }
            }
            $.isWhitelisted[user] = false;
            emit AddressRemovedFromWhitelist(user);
        }
    }

    /**
     * @notice Mint new AssetTokens to the user
     * @dev Only the owner can call this function
     * @param user Address of the user to mint AssetTokens to
     * @param assetTokenAmount Amount of AssetTokens to mint
     */
    function mint(address user, uint256 assetTokenAmount) external onlyOwner {
        _mint(user, assetTokenAmount);
    }

    /**
     * @notice Deposit yield into the AssetToken
     * @dev Only the owner can call this function, and the owner must have
     *   approved the CurrencyToken to spend the given amount
     * @param timestamp Timestamp of the deposit, must not be less than the previous deposit timestamp
     * @param currencyTokenAmount Amount of CurrencyToken to deposit as yield
     */
    function depositYield(uint256 timestamp, uint256 currencyTokenAmount) external onlyOwner {
        _depositYield(timestamp, currencyTokenAmount);
    }

    // Getter View Functions

    /// @notice Total value of all circulating AssetTokens
    function getTotalValue() external view returns (uint256) {
        return _getAssetTokenStorage().totalValue;
    }

    /// @notice Check if the whitelist is enabled
    function isWhitelistEnabled() external view returns (bool) {
        return _getAssetTokenStorage().isWhitelistEnabled;
    }

    /// @notice Whitelist of users that are allowed to hold AssetTokens
    function getWhitelist() external view returns (address[] memory) {
        return _getAssetTokenStorage().whitelist;
    }

    /**
     * @notice Check if the user is whitelisted
     * @param user Address of the user to check
     * @return isWhitelisted Boolean indicating if the user is whitelisted
     */
    function isAddressWhitelisted(address user) external view returns (bool isWhitelisted) {
        return _getAssetTokenStorage().isWhitelisted[user];
    }

    /// @notice List of all users that have ever held AssetTokens
    function getHolders() external view returns (address[] memory) {
        return _getAssetTokenStorage().holders;
    }

    /**
     * @notice Check if the user has ever held AssetTokens
     * @param user Address of the user to check
     * @return held Boolean indicating if the user has ever held AssetTokens
     */
    function hasBeenHolder(address user) external view returns (bool held) {
        return _getAssetTokenStorage().hasHeld[user];
    }

    /// @notice Price of an AssetToken based on its total value and total supply
    function getPricePerToken() external view returns (uint256) {
        return _getAssetTokenStorage().totalValue / totalSupply();
    }

    /**
     * @notice Get the available unlocked AssetToken balance of a user
     * @dev Perform a low-level call to check for locked balance in the user's SmartWallet.
     *     Decodes the returned locked balance and subtract it from the user's total balance.
     *      Reverts if the call fails.
     * @param user Address of the user to get the available balance of
     * @return balanceAvailable Available unlocked AssetToken balance of the user
     */
    function getBalanceAvailable(address user) public view returns (uint256) {
        // Perform a low-level call to check for locked balance in the user's SmartWallet.
        (bool success, bytes memory data) =
            user.call(abi.encodeWithSignature("getBalanceLocked(address)", address(this)));

        if (success) {
            uint256 lockedBalance = abi.decode(data, (uint256));
            return balanceOf(user) - lockedBalance;
        } else {
            revert SmartWalletCallFailed(user);
        }
    }

    /// @notice Total yield distributed to all AssetTokens for all users
    function totalYield() public view returns (uint256) {
        // TODO: loop through yield deposit history
        return 0;
    }

    /// @notice Claimed yield across all AssetTokens for all users
    function claimedYield() public view returns (uint256 amount) {
        AssetTokenStorage storage $ = _getAssetTokenStorage();
        uint256 length = $.whitelist.length;
        for (uint256 i = 0; i < length; ++i) {
            amount += _getYieldDistributionTokenStorage().yieldWithdrawn[$.whitelist[i]];
        }
    }

    /// @notice Unclaimed yield across all AssetTokens for all users
    function unclaimedYield() external view returns (uint256) {
        return totalYield() - claimedYield();
    }

    /**
     * @notice Total yield distributed to a specific user
     * @param user Address of the user for which to get the total yield
     * @return amount Total yield distributed to the user
     */
    function totalYield(address user) external view returns (uint256 amount) {
        return _getYieldDistributionTokenStorage().yieldAccrued[user];
    }

    /**
     * @notice Amount of yield that a specific user has claimed
     * @param user Address of the user for which to get the claimed yield
     * @return amount Amount of yield that the user has claimed
     */
    function claimedYield(address user) external view returns (uint256 amount) {
        return _getYieldDistributionTokenStorage().yieldWithdrawn[user];
    }

    /**
     * @notice Amount of yield that a specific user has not yet claimed
     * @param user Address of the user for which to get the unclaimed yield
     * @return amount Amount of yield that the user has not yet claimed
     */
    function unclaimedYield(address user) external view returns (uint256 amount) {
        return _getYieldDistributionTokenStorage().yieldAccrued[user]
            - _getYieldDistributionTokenStorage().yieldWithdrawn[user];
    }

}