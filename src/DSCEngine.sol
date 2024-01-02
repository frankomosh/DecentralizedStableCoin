// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Frankline Omondi
 *
 * The system is designed to be as minimal as possible. It should have the tokens maintain a 1 token == $1 peg value.
 * The stablecoin has the properties:
 *  - Exogenous Collateral
 *  - Dollar pegged
 *  -Algorithmically stable
 *
 * It is similar to DAI is DAI had no governance, no fees and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be overcollateralized. This means that the value of the collateral should always be greater than the value of the backed DSC.
 *
 * @notice This contract is at the core of the DSC System as it handles all the logic for minting and redeeming the DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    /////////////////////////////
    /////  errors  /////////////
    ////////////////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotSupported();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__NotAllowedToken();

    //////////////////////////////////
    /////  State Variables  //////////
    //////////////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // 10^10
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200 % overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; //
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10 % bonus for liquidators

    // 1 = 100% collateralized

    mapping(address token => address priceFeed) private s_priceFeed;
    // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userToTokenToCollateral
    mapping(address user => uint256 amountDscToMint) private s_DSCMinted; // userToDscToMint
    address[] private s_collateralTokens; // collateralTokens

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////////////
    /////  Events  ///////////////////
    //////////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, uint256 amount, address token);

    ////////////////////////////
    /////  Modifiers  //////////
    ////////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine__TokenNotSupported();
        }
        _;
    }

    ////////////////////////////
    /////  Functions  //////////
    ////////////////////////////

    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeed[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////////////////
    /////  External Functions  //////////
    ////////////////////////////////////
    /**
     * @param tokenCollateralAddress The ERC20 token address of the collateral you are depositing
     * @param amountCollateral The amount of collateral you are depositing
     * @param amountDscToMint The amount of DSC you are minting
     * @notice This function deposits collateral and mints DSC in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollaterallAddress The address of the collateral deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @notice Follows the CEI pattern (Check-Effect-Interaction)
     *
     */
    function depositCollateral(address tokenCollaterallAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollaterallAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollaterallAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollaterallAddress, amountCollateral);
        bool success = IERC20(tokenCollaterallAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice This function burns dsc and redeems the underlying collateral in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks the health factor
    }

    /**
     * @param tokenCollateralAddress The ERC20 token address of the collateral to be redeemed
     * @param amountCollateral The amount of collateral being redeemed
     * @notice The function redeems your collateral
     * @notice If you have DSC minted, you cannot redeem until you burn your DSC first
     */

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        // revertIfHealthFactorIsBroken(msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice The function follows the CEI pattern (Check-Effect-Interaction)
     * @param amountDscToMint The amount of Decentralized Stable Coin to mint
     * @notice They must have more collateral value than the minimum threshold
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If the user mints too much DSC, they will be liquidated($ 150 DSC, $ 100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // If we do start nearing undercollateralization, someone will be needed to liquidate positions

    // If someone is almost undercollateralized, we will pay you to liquidate them

    /**
     * @param collateral The ERC20 collateral address to be liquidated from the user
     * @param user The user who has broken the health factor. Their health factor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the User's health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the user's funds
     * @notice For this function to work, it will assume a roughly 200% overcollateralization
     * @notice A known bug concerning this function is f the protocol is 100% or less collateralized, then we wouldn't be able to actually incentivise the liquidators
     * For example, if the price of the collateral plummetted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor > MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // 1. Burn this user's DSC 'debt'
        // 2. Take the collateral from the user
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10 % bonus
        // Implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        // 3. Burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    /**
     * @dev Low-level internal function, should not be called unless the function calling it
     * intends to check for the health factors which are being broken
     */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getHealthFactor() external view {
        _healthFactor(msg.sender);
    }

    //////////////////////////////////////////////////////
    /////  Private and Internal View Functions  //////////
    //////////////////////////////////////////////////////
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, amountCollateral, tokenCollateralAddress);
        // _calculateHealthFactorAfterwards();
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
     * Returns how close to liquidation a user actually is
     * If a user goes below 1, they can get liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        // 1. Get total DSC minted by user
        // 2. Get total collateral deposited by user

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // 1000 ETH * 50 = 50,000 / 100 = 500
        // 1000 ETH * 200 = 200,000 / 100 = 2000

        return (collateralAdjustedForThreshold * PRECISION / totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor (does the user have enough collateral to mint the DSC?)
        // 2. If health factor is broken, revert
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
    /////////////////////////////////////////////////////
    /////  Public and External View Functions  //////////
    /////////////////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 10^8 USD
        // The returned value from CL will be 1 ETH = 10^18 USD
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 tokenCollateralValueInUsd) {
        // Loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the usd value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            tokenCollateralValueInUsd += getUsdValue(token, amount);
        }
        return tokenCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = 10^8 USD
        // The returned value from CL will be 1 ETH = 10^18 USD
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * 1e18) / totalDscMinted;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
}
