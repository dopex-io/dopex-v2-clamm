// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import {IDopexV2PositionManager} from "./interfaces/IDopexV2PositionManager.sol";

import {IOptionPricing} from "./pricing/IOptionPricing.sol";
import {IHandler} from "./interfaces/IHandler.sol";
import {IDopexFee} from "./interfaces/IDopexFee.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {ITokenURIFetcher} from "./interfaces/ITokenURIFetcher.sol";

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {Multicall} from "openzeppelin-contracts/contracts/utils/Multicall.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

/**
 * @title DopexV2OptionPools
 * @author 0xcarrot
 * @dev Allow traders to buy CALL and PUT options using CLAMM liquidity, which can be
 * exercised at any time ITM.
 */
contract DopexV2OptionPools is
    Ownable,
    ReentrancyGuard,
    Multicall,
    ERC721("Dopex V2 Options Pools", "DV2OP")
{
    using TickMath for int24;

    struct OptionData {
        uint256 opTickArrayLen;
        int24 tickLower;
        int24 tickUpper;
        uint256 expiry;
        bool isCall;
    }

    struct OptionTicks {
        IHandler _handler;
        IUniswapV3Pool pool;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidityToUse;
    }

    struct OptionParams {
        OptionTicks[] optionTicks;
        int24 tickLower;
        int24 tickUpper;
        uint256 ttl;
        bool isCall;
        uint256 maxFeeAllowed;
    }

    struct ExerciseOptionParams {
        uint256 optionId;
        ISwapper swapper;
        bytes swapData;
        uint256[] liquidityToExercise;
    }

    struct SettleOptionParams {
        uint256 optionId;
        ISwapper swapper;
        bytes swapData;
        uint256[] liquidityToSettle;
    }

    struct PositionSplitterParams {
        uint256 optionId;
        address to;
        uint256[] liquidityToSplit;
    }

    // events
    event LogMintOption(
        address user,
        uint256 tokenId,
        bool isCall,
        uint256 premiumAmount,
        uint256 totalAssetWithdrawn
    );
    event LogExerciseOption(
        address user,
        uint256 tokenId,
        uint256 totalProfit,
        uint256 totalAssetRelocked
    );
    event LogSettleOption(address user, uint256 tokenId);
    event LogSplitOption(
        address user,
        uint256 tokenId,
        uint256 newTokenId,
        address to
    );
    event LogIVUpdate(uint256[] ttl, uint256[] iv);
    event LogOptionsPoolInitialized(
        address optionPricing,
        address dpFee,
        address callAsset,
        address putAsset
    );
    event LogUpdateAddress(
        address tokeURIFetcher,
        address dpFee,
        address optionPricing
    );

    // errors
    error DopexV2OptionPools__IVNotSet();
    error DopexV2OptionPools__NotValidStrikeTick();
    error DopexV2OptionPools__PoolNotApproved();
    error DopexV2OptionPools__MaxFeeAllowanceExceeded();
    error DopexV2OptionPools__NotOwnerOrDelegator();
    error DopexV2OptionPools__ArrayLenMismatch();
    error DopexV2OptionPools__OptionExpired();
    error DopexV2OptionPools__OptionNotExpired();
    error DopexV2OptionPools__NotEnoughAfterSwap();
    error DopexV2OptionPools__NotApprovedSettler();

    IDopexFee public dpFee;
    IOptionPricing public optionPricing;
    IDopexV2PositionManager public immutable positionManager;
    IUniswapV3Pool public immutable primePool;

    address public immutable callAsset;
    address public immutable putAsset;
    address public feeTo;
    address public tokenURIFetcher;

    mapping(uint256 => uint256) public ttlToVEID;
    mapping(uint256 => OptionData) public opData;
    mapping(uint256 => OptionTicks[]) public opTickMap;
    mapping(address => mapping(address => bool)) public exerciseDelegator;
    mapping(address => bool) public approvedPools;
    mapping(address => bool) public settlers;

    uint256 public optionIds = 1;

    constructor(
        address _pm,
        address _optionPricing,
        address _dpFee,
        address _callAsset,
        address _putAsset,
        address _primePool
    ) {
        positionManager = IDopexV2PositionManager(_pm);
        callAsset = _callAsset;
        putAsset = _putAsset;

        dpFee = IDopexFee(_dpFee);

        optionPricing = IOptionPricing(_optionPricing);

        primePool = IUniswapV3Pool(_primePool);

        emit LogOptionsPoolInitialized(
            _optionPricing,
            _dpFee,
            _callAsset,
            _putAsset
        );
    }

    /**
     * @notice Provides the tokenURI for each token
     * @param id The token Id.
     * @return The tokenURI string data
     */
    function tokenURI(uint256 id) public view override returns (string memory) {
        return ITokenURIFetcher(tokenURIFetcher).onFetchTokenURIData(id);
    }

    /**
     * @notice Mints an option for the given strike and expiry.
     * @param _params The option  parameters.
     */
    function mintOption(OptionParams calldata _params) external nonReentrant {
        optionIds += 1;

        uint256[] memory amountsPerOptionTicks = new uint256[](
            _params.optionTicks.length
        );
        uint256 totalAssetWithdrawn;

        bool isAmount0;

        address assetToUse = _params.isCall ? callAsset : putAsset;

        if (ttlToVEID[_params.ttl] == 0) revert DopexV2OptionPools__IVNotSet();

        for (uint256 i; i < _params.optionTicks.length; i++) {
            if (
                _params.isCall
                    ? _params.tickUpper != _params.optionTicks[i].tickUpper
                    : _params.tickLower != _params.optionTicks[i].tickLower
            ) revert DopexV2OptionPools__NotValidStrikeTick();

            opTickMap[optionIds].push(
                OptionTicks({
                    _handler: _params.optionTicks[i]._handler,
                    pool: _params.optionTicks[i].pool,
                    tickLower: _params.optionTicks[i].tickLower,
                    tickUpper: _params.optionTicks[i].tickUpper,
                    liquidityToUse: _params.optionTicks[i].liquidityToUse
                })
            );

            if (!approvedPools[address(_params.optionTicks[i].pool)])
                revert DopexV2OptionPools__PoolNotApproved();

            bytes memory usePositionData = abi.encode(
                _params.optionTicks[i].pool,
                _params.optionTicks[i].tickLower,
                _params.optionTicks[i].tickUpper,
                _params.optionTicks[i].liquidityToUse
            );

            (, uint256[] memory amounts, ) = positionManager.usePosition(
                _params.optionTicks[i]._handler,
                usePositionData
            );

            if (_params.optionTicks[i].pool.token0() == assetToUse) {
                require(amounts[0] > 0 && amounts[1] == 0);
                amountsPerOptionTicks[i] = (amounts[0]);
                totalAssetWithdrawn += amounts[0];
                isAmount0 = true;
            } else {
                require(amounts[1] > 0 && amounts[0] == 0);
                amountsPerOptionTicks[i] = (amounts[1]);
                totalAssetWithdrawn += amounts[1];
                isAmount0 = false;
            }
        }

        uint256 strike = getPricePerCallAssetViaTick(
            primePool,
            _params.isCall ? _params.tickUpper : _params.tickLower
        );

        uint256 premiumAmount = _getPremiumAmount(
            _params.isCall ? false : true, // isPut
            block.timestamp + _params.ttl, // expiry
            strike, // Strike
            getCurrentPricePerCallAsset(primePool), // Current price
            ttlToVEID[_params.ttl], // IV, strike and expiry param is 0 since we are using flat volatility
            _params.isCall
                ? totalAssetWithdrawn
                : (totalAssetWithdrawn * (10 ** ERC20(putAsset).decimals())) /
                    strike
        );
        uint256 protocolFees;
        if (feeTo != address(0)) {
            protocolFees = dpFee.onFeeReqReceive();
            ERC20(assetToUse).transferFrom(msg.sender, feeTo, protocolFees);
        }

        if (premiumAmount + protocolFees > _params.maxFeeAllowed)
            revert DopexV2OptionPools__MaxFeeAllowanceExceeded();

        ERC20(assetToUse).transferFrom(
            msg.sender,
            address(this),
            premiumAmount
        );
        ERC20(assetToUse).approve(address(positionManager), premiumAmount);

        for (uint i; i < _params.optionTicks.length; i++) {
            uint256 premiumAmountEarned = (amountsPerOptionTicks[i] *
                premiumAmount) / totalAssetWithdrawn;

            uint128 liquidityToDonate = LiquidityAmounts.getLiquidityForAmounts(
                _getCurrentSqrtPriceX96(_params.optionTicks[i].pool),
                _params.optionTicks[i].tickLower.getSqrtRatioAtTick(),
                _params.optionTicks[i].tickUpper.getSqrtRatioAtTick(),
                isAmount0 ? premiumAmountEarned : 0,
                isAmount0 ? 0 : premiumAmountEarned
            );

            bytes memory donatePositionData = abi.encode(
                _params.optionTicks[i].pool,
                _params.optionTicks[i].tickLower,
                _params.optionTicks[i].tickUpper,
                liquidityToDonate
            );
            positionManager.donateToPosition(
                _params.optionTicks[i]._handler,
                donatePositionData
            );
        }

        opData[optionIds] = OptionData({
            opTickArrayLen: _params.optionTicks.length,
            tickLower: _params.tickLower,
            tickUpper: _params.tickUpper,
            expiry: block.timestamp + _params.ttl,
            isCall: _params.isCall
        });

        _safeMint(msg.sender, optionIds);

        emit LogMintOption(
            msg.sender,
            optionIds,
            _params.isCall,
            premiumAmount,
            totalAssetWithdrawn
        );
    }

    /**
     * @notice Exercises the given option .
     * @param _params The exercise option  parameters.
     */
    function exerciseOption(
        ExerciseOptionParams calldata _params
    ) external nonReentrant {
        if (
            ownerOf(_params.optionId) != msg.sender &&
            exerciseDelegator[ownerOf(_params.optionId)][msg.sender] == false
        ) revert DopexV2OptionPools__NotOwnerOrDelegator();

        OptionData memory oData = opData[_params.optionId];

        if (oData.opTickArrayLen != _params.liquidityToExercise.length)
            revert DopexV2OptionPools__ArrayLenMismatch();

        if (oData.expiry < block.timestamp)
            revert DopexV2OptionPools__OptionExpired();

        uint256 totalProfit;
        uint256 totalAssetRelocked;
        for (uint256 i; i < oData.opTickArrayLen; i++) {
            OptionTicks storage opTick = opTickMap[_params.optionId][i];

            bool isAmount0 = oData.isCall
                ? primePool.token0() == callAsset
                : primePool.token0() == putAsset;

            uint256 amountToSwap = isAmount0
                ? LiquidityAmounts.getAmount0ForLiquidity(
                    opTick.tickLower.getSqrtRatioAtTick(),
                    opTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(_params.liquidityToExercise[i])
                )
                : LiquidityAmounts.getAmount1ForLiquidity(
                    opTick.tickLower.getSqrtRatioAtTick(),
                    opTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(_params.liquidityToExercise[i])
                );

            totalAssetRelocked += amountToSwap;

            uint256 prevBalance = ERC20(oData.isCall ? putAsset : callAsset)
                .balanceOf(address(this));

            ERC20(oData.isCall ? callAsset : putAsset).transfer(
                address(_params.swapper),
                amountToSwap
            );

            _params.swapper.onSwapReceived(
                oData.isCall ? callAsset : putAsset,
                oData.isCall ? putAsset : callAsset,
                amountToSwap,
                _params.swapData
            );

            uint256 amountReq = isAmount0
                ? LiquidityAmounts.getAmount1ForLiquidity(
                    opTick.tickLower.getSqrtRatioAtTick(),
                    opTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(_params.liquidityToExercise[i])
                )
                : LiquidityAmounts.getAmount0ForLiquidity(
                    opTick.tickLower.getSqrtRatioAtTick(),
                    opTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(_params.liquidityToExercise[i])
                );

            uint256 currentBalance = ERC20(oData.isCall ? putAsset : callAsset)
                .balanceOf(address(this));

            if (currentBalance < prevBalance + amountReq)
                revert DopexV2OptionPools__NotEnoughAfterSwap();

            ERC20(oData.isCall ? putAsset : callAsset).approve(
                address(positionManager),
                amountReq
            );

            bytes memory unusePositionData = abi.encode(
                opTick.pool,
                opTick.tickLower,
                opTick.tickUpper,
                _params.liquidityToExercise[i]
            );

            positionManager.unusePosition(opTick._handler, unusePositionData);

            opTick.liquidityToUse -= _params.liquidityToExercise[i];

            totalProfit += currentBalance - (prevBalance + amountReq);
        }

        ERC20(oData.isCall ? putAsset : callAsset).transfer(
            msg.sender,
            totalProfit
        );

        emit LogExerciseOption(
            ownerOf(_params.optionId),
            _params.optionId,
            totalProfit,
            totalAssetRelocked
        );
    }

    /**
     * @notice Settles the given option .
     * @param _params The settle option  parameters.
     */
    function settleOption(
        SettleOptionParams calldata _params
    ) external nonReentrant {
        if (!settlers[msg.sender])
            revert DopexV2OptionPools__NotApprovedSettler();
        OptionData memory oData = opData[_params.optionId];

        if (oData.opTickArrayLen != _params.liquidityToSettle.length)
            revert DopexV2OptionPools__ArrayLenMismatch();

        if (block.timestamp <= oData.expiry)
            revert DopexV2OptionPools__OptionNotExpired();

        for (uint256 i; i < oData.opTickArrayLen; i++) {
            OptionTicks storage opTick = opTickMap[_params.optionId][i];
            uint256 liquidityToSettle = _params.liquidityToSettle[i] != 0
                ? _params.liquidityToSettle[i]
                : opTick.liquidityToUse;

            (uint256 amount0, uint256 amount1) = LiquidityAmounts
                .getAmountsForLiquidity(
                    _getCurrentSqrtPriceX96(opTick.pool),
                    opTick.tickLower.getSqrtRatioAtTick(),
                    opTick.tickUpper.getSqrtRatioAtTick(),
                    uint128(liquidityToSettle)
                );

            bool isAmount0 = oData.isCall
                ? primePool.token0() == callAsset
                : primePool.token0() == putAsset;

            if (
                (amount0 > 0 && amount1 == 0) || (amount1 > 0 && amount0 == 0)
            ) {
                if (isAmount0 && amount0 > 0) {
                    ERC20(oData.isCall ? callAsset : putAsset).approve(
                        address(positionManager),
                        amount0
                    );

                    bytes memory unusePositionData = abi.encode(
                        opTick.pool,
                        opTick.tickLower,
                        opTick.tickUpper,
                        liquidityToSettle
                    );

                    positionManager.unusePosition(
                        opTick._handler,
                        unusePositionData
                    );

                    opTick.liquidityToUse -= liquidityToSettle;
                } else if (!isAmount0 && amount1 > 0) {
                    ERC20(oData.isCall ? callAsset : putAsset).approve(
                        address(positionManager),
                        amount1
                    );

                    bytes memory unusePositionData = abi.encode(
                        opTick.pool,
                        opTick.tickLower,
                        opTick.tickUpper,
                        liquidityToSettle
                    );

                    positionManager.unusePosition(
                        opTick._handler,
                        unusePositionData
                    );
                    opTick.liquidityToUse -= liquidityToSettle;
                } else {
                    uint256 amountToSwap = isAmount0
                        ? LiquidityAmounts.getAmount0ForLiquidity(
                            opTick.tickLower.getSqrtRatioAtTick(),
                            opTick.tickUpper.getSqrtRatioAtTick(),
                            uint128(liquidityToSettle)
                        )
                        : LiquidityAmounts.getAmount1ForLiquidity(
                            opTick.tickLower.getSqrtRatioAtTick(),
                            opTick.tickUpper.getSqrtRatioAtTick(),
                            uint128(liquidityToSettle)
                        );

                    uint256 prevBalance = ERC20(
                        oData.isCall ? putAsset : callAsset
                    ).balanceOf(address(this));

                    ERC20(oData.isCall ? callAsset : putAsset).transfer(
                        address(_params.swapper),
                        amountToSwap
                    );

                    _params.swapper.onSwapReceived(
                        oData.isCall ? callAsset : putAsset,
                        oData.isCall ? putAsset : callAsset,
                        amountToSwap,
                        _params.swapData
                    );

                    uint256 amountReq = isAmount0
                        ? LiquidityAmounts.getAmount1ForLiquidity(
                            opTick.tickLower.getSqrtRatioAtTick(),
                            opTick.tickUpper.getSqrtRatioAtTick(),
                            uint128(liquidityToSettle)
                        )
                        : LiquidityAmounts.getAmount0ForLiquidity(
                            opTick.tickLower.getSqrtRatioAtTick(),
                            opTick.tickUpper.getSqrtRatioAtTick(),
                            uint128(liquidityToSettle)
                        );

                    uint256 currentBalance = ERC20(
                        oData.isCall ? putAsset : callAsset
                    ).balanceOf(address(this));

                    if (currentBalance < prevBalance + amountReq)
                        revert DopexV2OptionPools__NotEnoughAfterSwap();

                    ERC20(oData.isCall ? putAsset : callAsset).approve(
                        address(positionManager),
                        amountReq
                    );

                    bytes memory unusePositionData = abi.encode(
                        opTick.pool,
                        opTick.tickLower,
                        opTick.tickUpper,
                        liquidityToSettle
                    );

                    positionManager.unusePosition(
                        opTick._handler,
                        unusePositionData
                    );

                    opTick.liquidityToUse -= liquidityToSettle;

                    ERC20(oData.isCall ? putAsset : callAsset).transfer(
                        msg.sender,
                        currentBalance - (prevBalance + amountReq)
                    );
                }
            } else {}
        }

        emit LogSettleOption(ownerOf(_params.optionId), _params.optionId);
    }

    /**
     * @notice Splits the given option  into two new option.
     * @param _params The position splitter parameters.
     */
    function positionSplitter(
        PositionSplitterParams calldata _params
    ) external nonReentrant {
        optionIds += 1;

        if (ownerOf(_params.optionId) != msg.sender)
            revert DopexV2OptionPools__NotOwnerOrDelegator();
        OptionData memory oData = opData[_params.optionId];

        if (oData.opTickArrayLen != _params.liquidityToSplit.length)
            revert DopexV2OptionPools__ArrayLenMismatch();

        for (uint256 i; i < _params.liquidityToSplit.length; i++) {
            OptionTicks storage opTick = opTickMap[_params.optionId][i];
            opTick.liquidityToUse -= _params.liquidityToSplit[i];

            opTickMap[optionIds].push(
                OptionTicks({
                    _handler: opTick._handler,
                    pool: opTick.pool,
                    tickLower: opTick.tickLower,
                    tickUpper: opTick.tickUpper,
                    liquidityToUse: _params.liquidityToSplit[i]
                })
            );
        }

        opData[optionIds] = OptionData({
            opTickArrayLen: _params.liquidityToSplit.length,
            tickLower: oData.tickLower,
            tickUpper: oData.tickUpper,
            expiry: oData.expiry,
            isCall: oData.isCall
        });

        _safeMint(_params.to, optionIds);

        emit LogSplitOption(
            ownerOf(_params.optionId),
            _params.optionId,
            optionIds,
            _params.to
        );
    }

    /**
     * @notice Updates the exercise delegate for the caller's option.
     * @param _delegateTo The address of the new exercise delegate.
     * @param _status The status of the exercise delegate (true to enable, false to disable).
     */
    function updateExerciseDelegate(
        address _delegateTo,
        bool _status
    ) external {
        exerciseDelegator[msg.sender][_delegateTo] = _status;
    }

    // internal
    /**
     * @notice Calculates the price per call asset for the given tick.
     * @param _pool The UniswapV3 pool.
     * @param _tick The tick.
     * @return The price per call asset.
     */
    function getPricePerCallAssetViaTick(
        IUniswapV3Pool _pool,
        int24 _tick
    ) public view returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
        return _getPrice(_pool, sqrtPriceX96);
    }

    /**
     * @notice Calculates the current price per call asset.
     * @param _pool The UniswapV3 pool.
     * @return The current price per call asset.
     */
    function getCurrentPricePerCallAsset(
        IUniswapV3Pool _pool
    ) public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = _pool.slot0();
        return _getPrice(_pool, sqrtPriceX96);
    }

    /**
     * @notice Calculates the premium amount for the given option parameters.
     * @param isPut Whether the option is a put or call.
     * @param expiry The expiry of the option.
     * @param strike The strike price of the option.
     * @param lastPrice The last price of the underlying asset.
     * @param baseIv The base implied volatility of the underlying asset.
     * @param amount The amount of the underlying asset.
     * @return The premium amount.
     */
    function getPremiumAmount(
        bool isPut,
        uint expiry,
        uint strike,
        uint lastPrice,
        uint baseIv,
        uint amount
    ) external view returns (uint256) {
        return
            _getPremiumAmount(isPut, expiry, strike, lastPrice, baseIv, amount);
    }

    /**
     * @notice Gets the current sqrt price.
     * @param pool The UniswapV3 pool.
     * @return sqrtPriceX96 The current sqrt price.
     */
    function _getCurrentSqrtPriceX96(
        IUniswapV3Pool pool
    ) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96, , , , , , ) = pool.slot0();
    }

    /**
     * @notice Calculates the premium amount for the given option parameters.
     * @param isPut Whether the option is a put or call.
     * @param expiry The expiry of the option.
     * @param strike The strike price of the option.
     * @param lastPrice The last price of the underlying asset.
     * @param baseIv The base implied volatility of the underlying asset.
     * @param amount The amount of the underlying asset.
     * @return premiumAmount The premium amount.
     */
    function _getPremiumAmount(
        bool isPut,
        uint expiry,
        uint strike,
        uint lastPrice,
        uint baseIv,
        uint amount
    ) internal view returns (uint256 premiumAmount) {
        uint premiumInQuote = (amount *
            optionPricing.getOptionPrice(
                isPut,
                expiry,
                strike,
                lastPrice,
                baseIv
            )) /
            (
                isPut
                    ? 10 ** ERC20(putAsset).decimals()
                    : 10 ** ERC20(callAsset).decimals()
            );

        if (isPut) {
            return premiumInQuote;
        }
        return
            (premiumInQuote * (10 ** ERC20(callAsset).decimals())) / lastPrice;
    }

    /**
     * @notice Gets the price per call asset in quote asset units.
     * @param _pool The UniswapV3 pool instance.
     * @param sqrtPriceX96 The sqrt price of the pool.
     * @return price The price per call asset in quote asset units.
     */
    function _getPrice(
        IUniswapV3Pool _pool,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 price) {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 priceX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            price = callAsset == _pool.token0()
                ? FullMath.mulDiv(
                    priceX192,
                    10 ** ERC20(callAsset).decimals(),
                    1 << 192
                )
                : FullMath.mulDiv(
                    1 << 192,
                    10 ** ERC20(callAsset).decimals(),
                    priceX192
                );
        } else {
            uint256 priceX192 = FullMath.mulDiv(
                sqrtPriceX96,
                sqrtPriceX96,
                1 << 64
            );

            price = callAsset == _pool.token0()
                ? FullMath.mulDiv(
                    priceX192,
                    10 ** ERC20(callAsset).decimals(),
                    1 << 128
                )
                : FullMath.mulDiv(
                    1 << 128,
                    10 ** ERC20(callAsset).decimals(),
                    priceX192
                );
        }
    }

    // admin
    /**
     * @notice Updates the implied volatility (IV) for the given time to expirations (TTLs).
     * @param _ttls The TTLs to update the IV for.
     * @param _ttlIV The new IVs for the given TTLs.
     * @dev Only the owner can call this function.
     */
    function updateIVs(
        uint256[] calldata _ttls,
        uint256[] calldata _ttlIV
    ) external onlyOwner {
        for (uint256 i; i < _ttls.length; i++) {
            ttlToVEID[_ttls[i]] = _ttlIV[i];
        }
        emit LogIVUpdate(_ttls, _ttlIV);
    }

    /**
     * @notice Updates the addresses of the various components of the contract.
     * @param _feeTo The address of the fee recipient.
     * @param _tokeURIFetcher The address of the token URI fetcher.
     * @param _dpFee The address of the Dopex fee contract.
     * @param _optionPricing The address of the option pricing contract.
     * @param _settler The address of the settler.
     * @param _statusSettler Whether the settler is enabled.
     * @param _pool The address of the UniswapV3 pool.
     * @param _statusPools Whether the UniswapV3 pool is enabled.
     * @dev Only the owner can call this function.
     */
    function updateAddress(
        address _feeTo,
        address _tokeURIFetcher,
        address _dpFee,
        address _optionPricing,
        address _settler,
        bool _statusSettler,
        address _pool,
        bool _statusPools
    ) external onlyOwner {
        feeTo = _feeTo;
        tokenURIFetcher = _tokeURIFetcher;
        dpFee = IDopexFee(_dpFee);
        optionPricing = IOptionPricing(_optionPricing);
        settlers[_settler] = _statusSettler;
        approvedPools[_pool] = _statusPools;

        emit LogUpdateAddress(_tokeURIFetcher, _dpFee, _optionPricing);
    }

    // SOS admin functions
    /**
     * @notice Performs an emergency withdraw of all tokens from the contract.
     * @param token The address of the token to withdraw.
     * @dev Only the owner can call this function.
     */
    function emergencyWithdraw(address token) external onlyOwner {
        ERC20(token).transfer(
            msg.sender,
            ERC20(token).balanceOf(address(this))
        );
    }
}
