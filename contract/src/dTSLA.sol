//SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract dTSLA is ConfirmedOwner, FunctionsClient, ERC20 {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    error dTSLA__NotEnoughCollateral();
    error dTSLA__DoesntMeetWithdrawalRequirements();
    error sTSLA_TransferFailed();

    address constant SEPOLIA_FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    address constant SEPOLIA_TSLA_PRICE_FEED = 0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c; // this actually Link / Usd pricefeed
    address constant SEPOLIA_USDC_PRICE_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address constant SEPOLIA_USDC = 0xAF0d217854155ea67D583E4CB5724f7caeC3Dc87; // actually it's a self-deployed token
    uint64 immutable s_subId;
    uint32 constant GAS_LIMIT = 300_000;
    bytes32 constant DON_ID = hex"66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000";

    string private s_mintSourceCode;
    string private s_redeemSourceCode;
    uint256 private s_portfolioBalance;
    bytes32 private s_mostRecentRequestId;
    uint256 constant PRECISION = 1e18;
    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;
    //if there is 200$ in dTSLA in the brokerage, we can mint at most 100$ of dTSLA
    uint256 constant COLLATERAL_RATIO = 200; // 200% collateral ratio
    uint256 constant COLLATERAL_PRECISION = 100;
    uint256 constant MINIMUM_WITHDRAWAL_AMOUNT = 100e18;

    mapping(bytes32 requestId => dTslaRequest request) private s_requestIdToRequest;
    mapping(address user => uint256 pendingWithdrawalAmount) private s_userToWithdrawalAmount;
    // mapping(address token => address priceFeed) public s_priceFeeds;
    uint8 donHostedSecretsSlotId = 0;
    uint64 donHostedSecretVersion = 1712769962;

    enum MintOrRedeem {
        Mint,
        Redeem
    }

    struct dTslaRequest {
        uint256 amountOfToken;
        address requestor;
        MintOrRedeem mintOrRedeem;
    }

    constructor(string memory mintSourceCode, string memory redeemSourceCode, uint64 subId)
        FunctionsClient(SEPOLIA_FUNCTIONS_ROUTER)
        ConfirmedOwner(msg.sender)
        ERC20("dTesla", "dTSLA")
    {
        s_mintSourceCode = mintSourceCode;
        s_redeemSourceCode = redeemSourceCode;
        s_subId = subId;
    }

    // Send HTTP request to the dTSLA contract:
    // 1. See how much tokens is bought
    // 2. If enough tokens, send mint request
    function sendMintRequest(uint256 amountTokensToMint) external onlyOwner returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSourceCode);
        req.addDONHostedSecrets(donHostedSecretsSlotId, donHostedSecretVersion);
        bytes32 requestId = _sendRequest(req.encodeCBOR(), s_subId, GAS_LIMIT, DON_ID);
        s_mostRecentRequestId = requestId;
        s_requestIdToRequest[requestId] = dTslaRequest(amountTokensToMint, msg.sender, MintOrRedeem.Mint);
        return requestId;
    }

    // Return amount of TSLA value (in usd) is stored in our broker
    // If we have enough TSLA, we can mint dTSLA
    function _mintFilfillRequest(bytes32 requestId, bytes memory response) internal {
        uint256 amountOfTokensToMint = s_requestIdToRequest[requestId].amountOfToken;
        s_portfolioBalance = uint256(bytes32(response));

        // if TSLA collateral (how much TSLA we bought) > dTSLA to mint -> mint
        // How much TSLA we have in $$$?
        // How much TSLA we gonna mint in $$$?
        if (_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance) {
            revert dTSLA__NotEnoughCollateral();
        }
        if (amountOfTokensToMint != 0) {
            _mint(s_requestIdToRequest[requestId].requestor, amountOfTokensToMint);
        }
    }

    // User send request to sell TSLA for USDC (redemption tokens)
    // Chainlink call our "bank" account Alpaca to do:
    // 1. Sell TSLA on the brokerage
    // 2. Buy USDC on the brokerage
    // 3. Send USDC to the contract for user to withdraw
    function sendRedeemRequest(uint256 amountTokensToRedeem) external {
        uint256 amountTslaInUsdc = getUsdcValueOfUsd(getUsdValueOfTsla(amountTokensToRedeem));
        if (amountTslaInUsdc < MINIMUM_WITHDRAWAL_AMOUNT) {
            revert dTSLA__DoesntMeetWithdrawalRequirements();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSourceCode);

        string[] memory args = new string[](2);
        args[0] = amountTokensToRedeem.toString();
        args[1] = amountTslaInUsdc.toString();
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), s_subId, GAS_LIMIT, DON_ID);
        s_requestIdToRequest[requestId] = dTslaRequest(amountTokensToRedeem, msg.sender, MintOrRedeem.Redeem);
        s_mostRecentRequestId = requestId;
        _burn(msg.sender, amountTokensToRedeem);
    }

    function _redeemFilfillRequest(bytes32 requestId, bytes memory response) internal {
        // assume for now it has 18 decimals
        uint256 usdcAmount = uint256(bytes32(response));
        if (usdcAmount == 0) {
            uint256 amountOfTslaBurned = s_requestIdToRequest[requestId].amountOfToken;
            _mint(s_requestIdToRequest[requestId].requestor, amountOfTslaBurned);
            return;
        }
        s_userToWithdrawalAmount[s_requestIdToRequest[requestId].requestor] += usdcAmount;
    }

    function withdraw() external {
        uint256 amountToWithdraw = s_userToWithdrawalAmount[msg.sender];
        s_userToWithdrawalAmount[msg.sender] = 0;

        bool success = ERC20(0xAF0d217854155ea67D583E4CB5724f7caeC3Dc87).transfer(msg.sender, amountToWithdraw);
        if (!success) {
            revert sTSLA_TransferFailed();
        }
    }

    function fulfillRequest(bytes32 /*requestId*/, bytes memory response, bytes memory /*err*/ ) internal override {
        // if (s_requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.Mint) {
        //     _mintFilfillRequest(requestId, response);
        // } else {
        //     _redeemFilfillRequest(requestId, response);
        // }
        s_portfolioBalance = uint256(bytes32(response));
    }

    function finishMint() external onlyOwner {
        uint256 amountOfTokensToMint = s_requestIdToRequest[s_mostRecentRequestId].amountOfToken;
        if (_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance) {
            revert dTSLA__NotEnoughCollateral();
        }
        _mint(s_requestIdToRequest[s_mostRecentRequestId].requestor, amountOfTokensToMint);
    }

    function _getCollateralRatioAdjustedTotalBalance(uint256 amountOfTokensToMint) internal view returns (uint256) {
        uint256 calculatedTotalValue = getCalculatedNewTotalValue(amountOfTokensToMint);
        return ((calculatedTotalValue * COLLATERAL_RATIO) / COLLATERAL_PRECISION);
    }

    // The new expected total value in USD of all dTSKA tokens combined
    function getCalculatedNewTotalValue(uint256 addedNumberOfTokens) internal view returns (uint256) {
        // 10 dtsla tokesns + 5 dtsla tokens = 15 dtsla tokens * price of tsla(100) = 1500
        return ((totalSupply() + addedNumberOfTokens) * getPrice(SEPOLIA_TSLA_PRICE_FEED)) / PRECISION;
    }

    function getUsdcValueOfUsd(uint256 usdAmount) public view returns (uint256) {
        return ((usdAmount * getPrice(SEPOLIA_USDC_PRICE_FEED)) / PRECISION);
    }

    function getUsdValueOfTsla(uint256 amountOfTsla) public view returns (uint256) {
        return ((amountOfTsla * getPrice(SEPOLIA_TSLA_PRICE_FEED)) / PRECISION);
    }

    function getPrice(address currentPriceFeed) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(currentPriceFeed);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION; // so that we have 18 decimals
    }

    function getRequest(bytes32 requestId) public view returns (dTslaRequest memory) {
        return s_requestIdToRequest[requestId];
    }

    function getPendingWithdrawalAmount(address user) public view returns (uint256) {
        return s_userToWithdrawalAmount[user];
    }

    function getPortfolioBalance() public view returns (uint256) {
        return s_portfolioBalance;
    }

    function getCollateralRatio() public pure returns (uint256) {
        return COLLATERAL_RATIO;
    }

    function getCollateralPrecision() public pure returns (uint256) {
        return COLLATERAL_PRECISION;
    }

    function getMinimumWithdrawalAmount() public pure returns (uint256) {
        return MINIMUM_WITHDRAWAL_AMOUNT;
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() public pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getGasLimit() public pure returns (uint32) {
        return GAS_LIMIT;
    }

    function getSubId() public view returns (uint64) {
        return s_subId;
    }

    function getMintSourceCode() public view returns (string memory) {
        return s_mintSourceCode;
    }

    function getRedeedSourceCode() public view returns (string memory) {
        return s_redeemSourceCode;
    }
}
