// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IYieldDistributionToken } from "../interfaces/IYieldDistributionToken.sol";

/**
 * @title YieldDistributionToken
 * @author Eugene Y. Q. Shen
 * @notice ERC20 token that receives yield deposits and distributes yield
 *   to token holders proportionally based on how long they have held the token
 */
abstract contract YieldDistributionToken is ERC20, Ownable, IYieldDistributionToken {

    // Types

    /**
     * @notice State of a holder of the YieldDistributionToken
     * @param amount Amount of YieldDistributionTokens currently held by the user
     * @param amountSeconds Cumulative sum of the amount of YieldDistributionTokens held by
     *   the user, multiplied by the number of seconds that the user has had each balance for
     * @param yieldAccrued Total amount of yield that has ever been accrued to the user
     * @param yieldWithdrawn Total amount of yield that has ever been withdrawn by the user
     * @param lastBalanceTimestamp Timestamp of the most recent balance update for the user
     * @param lastDepositAmountSeconds AmountSeconds of the user at the time of the
     *   most recent deposit that was successfully processed by calling accrueYield
     */
    struct UserState {
        uint256 amount;
        uint256 amountSeconds;
        uint256 yieldAccrued;
        uint256 yieldWithdrawn;
        uint256 lastBalanceTimestamp;
        uint256 lastDepositAmountSeconds;
    }

    /**
     * @notice Amount of yield deposited into the YieldDistributionToken at one point in time
     * @param currencyTokenAmount Amount of CurrencyToken deposited as yield
     * @param totalAmountSeconds Sum of amountSeconds for all users at that time
     * @param previousTimestamp Timestamp of the previous deposit
     */
    struct Deposit {
        uint256 currencyTokenAmount;
        uint256 totalAmountSeconds;
        uint256 previousTimestamp;
    }

    /**
     * @notice Linked list of deposits into the YieldDistributionToken
     * @dev Invariant: the YieldDistributionToken has at most one deposit at each timestamp
     *   i.e. depositHistory[timestamp].previousTimestamp < timestamp
     * @param lastTimestamp Timestamp of the most recent deposit
     * @param deposits Mapping of timestamps to deposits
     */
    struct DepositHistory {
        uint256 lastTimestamp;
        mapping(uint256 timestamp => Deposit deposit) deposits;
    }

    // Storage

    /// @custom:storage-location erc7201:plume.storage.YieldDistributionToken
    struct YieldDistributionTokenStorage {
        /// @dev CurrencyToken in which the yield is deposited and denominated
        IERC20 currencyToken;
        /// @dev Number of decimals of the YieldDistributionToken
        uint8 decimals;
        /// @dev URI for the YieldDistributionToken metadata
        string tokenURI;
        /// @dev History of deposits into the YieldDistributionToken
        DepositHistory depositHistory;
        /// @dev Current sum of all amountSeconds for all users
        uint256 totalAmountSeconds;
        /// @dev Timestamp of the last change in totalSupply()
        uint256 lastSupplyTimestamp;
        /// @dev State for each user
        mapping(address user => UserState userState) userStates;
        /// @dev Mapping to track registered DEX addresses
        mapping(address dex => bool) isDEX;
        /// @dev Mapping to associate DEX addresses with maker addresses
        mapping(address dex => address maker) dexToMakerAddress;
        /// @dev Mapping to track tokens held on DEXs for each user
        mapping(address maker => uint256 tokensHeldOnDEX) tokensHeldOnDEXs;
    }

    // keccak256(abi.encode(uint256(keccak256("plume.storage.YieldDistributionToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YIELD_DISTRIBUTION_TOKEN_STORAGE_LOCATION =
        0x3d2d7d9da47f1055055838ecd982d8a93d7044b5f93759fc6e1ef3269bbc7000;

    function _getYieldDistributionTokenStorage() internal pure returns (YieldDistributionTokenStorage storage $) {
        assembly {
            $.slot := YIELD_DISTRIBUTION_TOKEN_STORAGE_LOCATION
        }
    }

    // Constants

    // Base that is used to divide all price inputs in order to represent e.g. 1.000001 as 1000001e12
    uint256 private constant _BASE = 1e18;

    // Scale that is used to multiply yield deposits for increased precision
    uint256 private constant SCALE = 1e36;

    // Events

    /**
     * @notice Emitted when yield is deposited into the YieldDistributionToken
     * @param user Address of the user who deposited the yield
     * @param timestamp Timestamp of the deposit
     * @param currencyTokenAmount Amount of CurrencyToken deposited as yield
     */
    event Deposited(address indexed user, uint256 timestamp, uint256 currencyTokenAmount);

    /**
     * @notice Emitted when yield is claimed by a user
     * @param user Address of the user who claimed the yield
     * @param currencyTokenAmount Amount of CurrencyToken claimed as yield
     */
    event YieldClaimed(address indexed user, uint256 currencyTokenAmount);

    /**
     * @notice Emitted when yield is accrued to a user
     * @param user Address of the user who accrued the yield
     * @param currencyTokenAmount Amount of CurrencyToken accrued as yield
     */
    event YieldAccrued(address indexed user, uint256 currencyTokenAmount);

    // Errors

    /**
     * @notice Indicates a failure because the transfer of CurrencyToken failed
     * @param user Address of the user who tried to transfer CurrencyToken
     * @param currencyTokenAmount Amount of CurrencyToken that failed to transfer
     */
    error TransferFailed(address user, uint256 currencyTokenAmount);

    /// @notice Indicates a failure because a yield deposit is made in the same block as the last one
    error DepositSameBlock();

    // Constructor

    /**
     * @notice Construct the YieldDistributionToken
     * @param owner Address of the owner of the YieldDistributionToken
     * @param name Name of the YieldDistributionToken
     * @param symbol Symbol of the YieldDistributionToken
     * @param currencyToken Token in which the yield is deposited and denominated
     * @param decimals_ Number of decimals of the YieldDistributionToken
     * @param tokenURI URI of the YieldDistributionToken metadata
     */
    constructor(
        address owner,
        string memory name,
        string memory symbol,
        IERC20 currencyToken,
        uint8 decimals_,
        string memory tokenURI
    ) ERC20(name, symbol) Ownable(owner) {
        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        $.currencyToken = currencyToken;
        $.decimals = decimals_;
        $.tokenURI = tokenURI;
        $.depositHistory.lastTimestamp = block.timestamp;
        _updateSupply();
    }

    // Virtual Functions

    /// @notice Request to receive yield from the given SmartWallet
    function requestYield(address from) external virtual override(IYieldDistributionToken);

    // Override Functions

    /// @notice Number of decimals of the YieldDistributionToken
    function decimals() public view override returns (uint8) {
        return _getYieldDistributionTokenStorage().decimals;
    }

    /**
     * @notice Update the balance of `from` and `to` after token transfer and accrue yield
     * @param from Address to transfer tokens from
     * @param to Address to transfer tokens to
     * @param value Amount of tokens to transfer
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        uint256 timestamp = block.timestamp;
        super._update(from, to, value);

        _updateSupply();

        if (from != address(0)) {
            accrueYield(from);
            UserState memory fromState = $.userStates[from];
            fromState.amountSeconds += fromState.amount * (timestamp - fromState.lastBalanceTimestamp);
            fromState.amount = balanceOf(from);
            fromState.lastBalanceTimestamp = timestamp;
            $.userStates[from] = fromState;

            // Adjust balances if transferring to a DEX
            if ($.isDEX[to]) {
                $.dexToMakerAddress[to] = from;
                _adjustMakerBalance(from, value, true);
            }
        }

        if (to != address(0)) {
            accrueYield(to);
            UserState memory toState = $.userStates[to];
            toState.amountSeconds += toState.amount * (timestamp - toState.lastBalanceTimestamp);
            toState.amount = balanceOf(to);
            toState.lastBalanceTimestamp = timestamp;
            $.userStates[to] = toState;

            // Adjust balances if transferring from a DEX
            if ($.isDEX[from]) {
                address maker = $.dexToMakerAddress[from];
                _adjustMakerBalance(maker, value, false);
            }
        }
    }

    // Internal Functions

    /**
     * @notice Deposit yield into the YieldDistributionToken
     * @dev The sender must have approved the CurrencyToken to spend the given amount
     * @param currencyTokenAmount Amount of CurrencyToken to deposit as yield
     */
    function _depositYield(uint256 currencyTokenAmount) internal {
        if (currencyTokenAmount == 0) {
            return;
        }

        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        uint256 lastTimestamp = $.depositHistory.lastTimestamp;
        uint256 timestamp = block.timestamp;

        _updateSupply();

        // If the deposit is in the same block as the last one, add to the previous deposit
        //  Otherwise, append a new deposit to the token deposit history
        Deposit memory deposit = $.depositHistory.deposits[timestamp];
        deposit.currencyTokenAmount += currencyTokenAmount;
        deposit.totalAmountSeconds = $.totalAmountSeconds;
        if (timestamp != lastTimestamp) {
            deposit.previousTimestamp = lastTimestamp;
            $.depositHistory.lastTimestamp = timestamp;
        }
        $.depositHistory.deposits[timestamp] = deposit;

        if (!$.currencyToken.transferFrom(msg.sender, address(this), currencyTokenAmount)) {
            revert TransferFailed(msg.sender, currencyTokenAmount);
        }
        emit Deposited(msg.sender, timestamp, currencyTokenAmount);
    }

    // Internal Functions

    /// @notice Update the totalAmountSeconds and lastSupplyTimestamp when supply or time changes
    function _updateSupply() internal {
        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        uint256 timestamp = block.timestamp;
        if (timestamp > $.lastSupplyTimestamp) {
            $.totalAmountSeconds += totalSupply() * (timestamp - $.lastSupplyTimestamp);
            $.lastSupplyTimestamp = timestamp;
        }
    }

    // Admin Setter Functions

    /**
     * @notice Set the URI for the YieldDistributionToken metadata
     * @dev Only the owner can call this setter
     * @param tokenURI New token URI
     */
    function setTokenURI(string memory tokenURI) external onlyOwner {
        _getYieldDistributionTokenStorage().tokenURI = tokenURI;
    }

    // Getter View Functions

    /// @notice CurrencyToken in which the yield is deposited and denominated
    function getCurrencyToken() external view returns (IERC20) {
        return _getYieldDistributionTokenStorage().currencyToken;
    }

    /// @notice URI for the YieldDistributionToken metadata
    function getTokenURI() external view returns (string memory) {
        return _getYieldDistributionTokenStorage().tokenURI;
    }

    // Permissionless Functions

    //TODO: why are we returning currencyToken?
    /**
     * @notice Claim all the remaining yield that has been accrued to a user
     * @dev Anyone can call this function to claim yield for any user
     * @param user Address of the user to claim yield for
     * @return currencyToken CurrencyToken in which the yield is deposited and denominated
     * @return currencyTokenAmount Amount of CurrencyToken claimed as yield
     */
    function claimYield(address user) public returns (IERC20 currencyToken, uint256 currencyTokenAmount) {
        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        currencyToken = $.currencyToken;

        accrueYield(user);

        UserState storage userState = $.userStates[user];
        uint256 amountAccrued = userState.yieldAccrued;
        currencyTokenAmount = amountAccrued - userState.yieldWithdrawn;
        if (currencyTokenAmount != 0) {
            userState.yieldWithdrawn = amountAccrued;
            if (!currencyToken.transfer(user, currencyTokenAmount)) {
                revert TransferFailed(user, currencyTokenAmount);
            }
            emit YieldClaimed(user, currencyTokenAmount);
        }
    }

    /**
     * @notice Accrue yield to a user, which can later be claimed
     * @dev Anyone can call this function to accrue yield to any user.
     *   The function does not do anything if it is called in the same block that a deposit is made.
     *   This function accrues all the yield up until the most recent deposit and updates the user state.
     * @param user Address of the user to accrue yield to
     */
    function accrueYield(address user) public {
        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        DepositHistory storage depositHistory = $.depositHistory;
        UserState memory userState = $.userStates[user];
        uint256 depositTimestamp = depositHistory.lastTimestamp;
        uint256 lastBalanceTimestamp = userState.lastBalanceTimestamp;

        /**
         * There is a race condition in the current implementation that occurs when
         * we deposit yield, then accrue yield for some users, then deposit more yield
         * in the same block. The users whose yield was accrued in this block would
         * not receive the yield from the second deposit. Therefore, we do not accrue
         * anything when the deposit timestamp is the same as the current block timestamp.
         * Users can call `accrueYield` again on the next block.
         */
        if (
            depositTimestamp == block.timestamp
            // If the user has never had any balances, then there is no yield to accrue
            || lastBalanceTimestamp == 0
            // If this deposit is before the user's last balance update, then they already accrued yield
            || depositTimestamp < lastBalanceTimestamp
        ) {
            return;
        }

        // Iterate through depositHistory and accrue yield for the user at each deposit timestamp
        Deposit storage deposit = depositHistory.deposits[depositTimestamp];
        uint256 yieldAccrued = 0;
        uint256 amountSeconds = userState.amountSeconds;
        uint256 depositAmount = deposit.currencyTokenAmount;
        while (depositAmount > 0 && depositTimestamp > lastBalanceTimestamp) {
            uint256 previousDepositTimestamp = deposit.previousTimestamp;
            uint256 intervalTotalAmountSeconds =
                deposit.totalAmountSeconds - depositHistory.deposits[previousDepositTimestamp].totalAmountSeconds;
            if (previousDepositTimestamp > lastBalanceTimestamp) {
                /**
                 * There can be a sequence of deposits made while the user balance remains the same throughout.
                 * Subtract the amountSeconds in this interval to get the total amountSeconds at the previous deposit.
                 */
                uint256 intervalAmountSeconds = userState.amount * (depositTimestamp - previousDepositTimestamp);
                amountSeconds -= intervalAmountSeconds;
                yieldAccrued += _BASE * depositAmount * intervalAmountSeconds / intervalTotalAmountSeconds;
            } else {
                /**
                 * At the very end, there can be a sequence of balance updates made right after
                 * the most recent previously processed deposit and before any other deposits.
                 */
                yieldAccrued += _BASE * depositAmount * (amountSeconds - userState.lastDepositAmountSeconds)
                    / intervalTotalAmountSeconds;
            }
            depositTimestamp = previousDepositTimestamp;
            deposit = depositHistory.deposits[depositTimestamp];
            depositAmount = deposit.currencyTokenAmount;
        }

        userState.lastDepositAmountSeconds = userState.amountSeconds;
        userState.amountSeconds += userState.amount * (depositHistory.lastTimestamp - lastBalanceTimestamp);
        userState.lastBalanceTimestamp = depositHistory.lastTimestamp;
        userState.yieldAccrued += yieldAccrued / _BASE;
        $.userStates[user] = userState;

        if ($.isDEX[user]) {
            // Redirect yield to the maker
            address maker = $.dexToMakerAddress[user];
            $.userStates[maker].yieldAccrued += userState.yieldAccrued;
            emit YieldAccrued(maker, yieldAccrued / _BASE);
        } else {
            // Regular yield accrual
            emit YieldAccrued(user, yieldAccrued / _BASE);
        }

        //emit YieldAccrued(user, yieldAccrued / _BASE);
    }

    /**
     * @notice Register a DEX address
     * @dev Only the owner can call this function
     * @param dexAddress Address of the DEX to register
     */
    function registerDEX(address dexAddress) external onlyOwner {
        _getYieldDistributionTokenStorage().isDEX[dexAddress] = true;
    }

    /**
     * @notice Unregister a DEX address
     * @dev Only the owner can call this function
     * @param dexAddress Address of the DEX to unregister
     */
    function unregisterDEX(address dexAddress) external onlyOwner {
        _getYieldDistributionTokenStorage().isDEX[dexAddress] = false;
    }

    /**
     * @notice Register a maker's pending order on a DEX
     * @dev Only registered DEXs can call this function
     * @param maker Address of the maker
     * @param amount Amount of tokens in the order
     */
    function registerMakerOrder(address maker, uint256 amount) external {
        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        require($.isDEX[msg.sender], "Caller is not a registered DEX");
        $.dexToMakerAddress[msg.sender] = maker;
        $.tokensHeldOnDEXs[maker] += amount;
    }

    /**
     * @notice Unregister a maker's completed or cancelled order on a DEX
     * @dev Only registered DEXs can call this function
     * @param maker Address of the maker
     * @param amount Amount of tokens to return (if any)
     */
    function unregisterMakerOrder(address maker, uint256 amount) external {
        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        require($.isDEX[msg.sender], "Caller is not a registered DEX");
        require($.tokensHeldOnDEXs[maker] >= amount, "Insufficient tokens held on DEX");
        $.tokensHeldOnDEXs[maker] -= amount;
        if ($.tokensHeldOnDEXs[maker] == 0) {
            $.dexToMakerAddress[msg.sender] = address(0);
        }
    }

    /**
     * @notice Check if an address is a registered DEX
     * @param addr Address to check
     * @return bool True if the address is a registered DEX, false otherwise
     */
    function isDexAddressWhitelisted(address addr) public view returns (bool) {
        return _getYieldDistributionTokenStorage().isDEX[addr];
    }

    /**
     * @notice Get the amount of tokens held on DEXs for a user
     * @param user Address of the user
     * @return amount of tokens held on DEXs on behalf of the user
     */
    function tokensHeldOnDEXs(address user) public view returns (uint256) {
        return _getYieldDistributionTokenStorage().tokensHeldOnDEXs[user];
    }

    function _adjustMakerBalance(address maker, uint256 amount, bool increase) internal {
        YieldDistributionTokenStorage storage $ = _getYieldDistributionTokenStorage();
        if (increase) {
            $.tokensHeldOnDEXs[maker] += amount;
        } else {
            require($.tokensHeldOnDEXs[maker] >= amount, "Insufficient tokens held on DEXs");
            $.tokensHeldOnDEXs[maker] -= amount;
        }
    }

}
