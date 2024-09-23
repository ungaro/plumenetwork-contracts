// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Proxy } from "@openzeppelin/contracts/proxy/Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { WalletUtils } from "./WalletUtils.sol";
import { AssetVault } from "./extensions/AssetVault.sol";
import { SignedOperations } from "./extensions/SignedOperations.sol";
import { IAssetToken } from "./interfaces/IAssetToken.sol";
import { IAssetVault } from "./interfaces/IAssetVault.sol";
import { ISmartWallet } from "./interfaces/ISmartWallet.sol";

/**
 * @title SmartWallet
 * @author Eugene Y. Q. Shen
 * @notice Base implementation of smart wallets on Plume, which can be
 *   upgraded by changing the SmartWallet implementation in the WalletFactory
 *   and extended for each individual user by calling `upgrade`.
 * @dev The SmartWallet has a set of core functionalities, such as the AssetVault
 *   and SignedOperations, but any functions that are not defined in the base
 *   implementation are delegated to the custom implementation for each user.
 */
contract SmartWallet is Proxy, WalletUtils, SignedOperations, ISmartWallet {

    // Storage

    /**
     * @notice Storage layout for the SmartWallet
     * @dev Because the WalletProxy applies to every EOA, every user has their own
     *   SmartWalletStorage and their own storage slot to store their custom
     *   user wallet implementation, on which they can add any extensions.
     * @custom:storage-location erc7201:plume.storage.SmartWallet
     */
    struct SmartWalletStorage {
        /// @dev Address of the current user wallet implementation for each user
        address userWallet;
        /// @dev AssetVault associated with the smart wallet
        IAssetVault assetVault;
    }

    // keccak256(abi.encode(uint256(keccak256("plume.storage.SmartWallet")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SMART_WALLET_STORAGE_LOCATION =
        0xc74f5f530706068223c06633e3be3a7b2d2fced239e7caaa9b10e1da346c1a00;

    function _getSmartWalletStorage() private pure returns (SmartWalletStorage storage $) {
        assembly {
            $.slot := SMART_WALLET_STORAGE_LOCATION
        }
    }

    // Events

    /**
     * @notice Emitted when a user upgrades their user wallet implementation
     * @param userWallet Address of the new user wallet implementation
     */
    event UserWalletUpgraded(address indexed userWallet);

    // Errors

    /**
     * @notice Indicates a failure because the sender is not the AssetVault
     * @param sender Address of the sender that is not the AssetVault
     */
    error UnauthorizedAssetVault(address sender);

    /**
     * @notice Indicates a failure because the AssetVault for the user already exists
     * @param assetVault Existing AssetVault for the user
     */
    error AssetVaultAlreadyExists(IAssetVault assetVault);

    // Base Smart Wallet Functions

    /// @notice Deploy an AssetVault for this smart wallet if it does not already exist
    function deployAssetVault() public {
        SmartWalletStorage storage $ = _getSmartWalletStorage();
        if (address($.assetVault) != address(0)) {
            revert AssetVaultAlreadyExists($.assetVault);
        }
        $.assetVault = new AssetVault();
    }

    /// @notice AssetVault associated with the smart wallet
    function getAssetVault() external view returns (IAssetVault assetVault) {
        return _getSmartWalletStorage().assetVault;
    }

    /**
     * @notice Get the number of AssetTokens that are currently locked in the AssetVault
     * @param assetToken AssetToken from which the yield is to be redistributed
     * @return balanceLocked Amount of the AssetToken that is currently locked
     */
    function getBalanceLocked(IAssetToken assetToken) public view returns (uint256 balanceLocked) {
        return _getSmartWalletStorage().assetVault.getBalanceLocked(assetToken);
    }

    // User Wallet Functions

    /**
     * @notice Upgrade the user wallet implementation
     * @dev Only the user can upgrade the implementation for their own wallet
     * @param userWallet Address of the new user wallet implementation
     */
    function upgrade(address userWallet) public onlyWallet {
        _getSmartWalletStorage().userWallet = userWallet;
        emit UserWalletUpgraded(userWallet);
    }

    /**
     * @notice Fallback function to the user wallet implementation if
     *   the function is not implemented in the base SmartWallet implementation
     * @return impl Address of the user wallet implementation
     */
    function _implementation() internal view virtual override returns (address impl) {
        return _getSmartWalletStorage().userWallet;
    }

    /// @notice Fallback function to receive ether
    receive() external payable { }

}
