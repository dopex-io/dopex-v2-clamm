// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Libraries
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {BlackScholes} from "../../test/pricing/BlackScholes.sol";
import {ABDKMathQuad} from "../../test/pricing/ABDKMathQuad.sol";

// Contracts
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract OptionPricingLinear is Ownable {
    using SafeMath for uint256;

    // The offset for volatility calculation in 1e4 precision
    uint256 public volatilityOffset;

    // The multiplier for volatility calculation in 1e4 precision
    uint256 public volatilityMultiplier;

    // The % of the price of asset which is the minimum option price possible in 1e8 precision
    uint256 public minOptionPricePercentage;

    // The decimal precision for volatility calculation
    uint256 public constant VOLATILITY_PRECISION = 1e4;

    constructor(
        uint256 _volatilityOffset,
        uint256 _volatilityMultiplier,
        uint256 _minOptionPricePercentage
    ) {
        volatilityOffset = _volatilityOffset;
        volatilityMultiplier = _volatilityMultiplier;
        minOptionPricePercentage = _minOptionPricePercentage;
    }

    /*---- GOVERNANCE FUNCTIONS ----*/

    /// @notice updates the offset for volatility calculation
    /// @param _volatilityOffset the new offset
    /// @return whether offset was updated
    function updateVolatilityOffset(
        uint256 _volatilityOffset
    ) external onlyOwner returns (bool) {
        volatilityOffset = _volatilityOffset;

        return true;
    }

    /// @notice updates the multiplier for volatility calculation
    /// @param _volatilityMultiplier the new multiplier
    /// @return whether multiplier was updated
    function updateVolatilityMultiplier(
        uint256 _volatilityMultiplier
    ) external onlyOwner returns (bool) {
        volatilityMultiplier = _volatilityMultiplier;

        return true;
    }

    /// @notice updates % of the price of asset which is  the minimum option price possible
    /// @param _minOptionPricePercentage the new %
    /// @return whether % was updated
    function updateMinOptionPricePercentage(
        uint256 _minOptionPricePercentage
    ) external onlyOwner returns (bool) {
        minOptionPricePercentage = _minOptionPricePercentage;

        return true;
    }

    /*---- VIEWS ----*/

    /**
     * @notice computes the option price (with liquidity multiplier)
     * @param isPut is put option
     * @param expiry expiry timestamp
     * @param strike strike price
     * @param lastPrice current price
     * @param volatility volatility
     */
    function getOptionPrice(
        bool isPut,
        uint256 expiry,
        uint256 strike,
        uint256 lastPrice,
        uint256 volatility
    ) external view returns (uint256) {
        uint256 timeToExpiry = expiry.sub(block.timestamp).div(864);
        volatility = getVolatility(strike, lastPrice, volatility);

        uint256 optionPrice = BlackScholes
            .calculate(
                isPut ? 1 : 0, // 0 - Put, 1 - Call
                lastPrice,
                strike,
                timeToExpiry, // Number of days to expiry mul by 100
                0,
                volatility
            )
            .div(BlackScholes.DIVISOR);

        uint256 minOptionPrice = lastPrice.mul(minOptionPricePercentage).div(
            1e10
        );

        if (minOptionPrice > optionPrice) {
            return minOptionPrice;
        }

        return optionPrice;
    }

    /**
     * @notice computes the volatility for a strike
     * @param strike strike price
     * @param lastPrice current price
     * @param volatility volatility
     */
    function getVolatility(
        uint256 strike,
        uint256 lastPrice,
        uint256 volatility
    ) public view returns (uint256) {
        uint256 percentageDifference = strike
            .mul(1e2)
            .mul(VOLATILITY_PRECISION)
            .div(lastPrice); // 1e4 in percentage precision (1e6 is 100%)

        if (strike > lastPrice) {
            percentageDifference = percentageDifference.sub(1e6);
        } else {
            percentageDifference = uint256(1e6).sub(percentageDifference);
        }

        uint256 scaleFactor = volatilityOffset +
            (
                percentageDifference.mul(volatilityMultiplier).div(
                    VOLATILITY_PRECISION
                )
            );

        return (volatility.mul(scaleFactor).div(VOLATILITY_PRECISION));
    }
}
