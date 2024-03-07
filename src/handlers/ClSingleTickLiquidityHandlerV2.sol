// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

// Interfaces
import {IClPool} from "../ramses-v3/v3-core/contracts/interfaces/IClPool.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "v3-periphery/SwapRouter.sol";
import {IHandler} from "../interfaces/IHandler.sol";
import {IHook} from "../interfaces/IHook.sol";

// Libraries
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";

// Contracts
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {ERC6909} from "../libraries/tokens/ERC6909.sol";
import {LiquidityManager} from "../ramses-v3/LiquidityManager.sol";

/**
 * @title ClSingleTickLiquidityHandlerV2
 * @author 0xcarrot
 * @dev This is a handler contract for providing liquidity
 * for Cl V3 Style AMMs. The V2 version supports reserved liquidity and hooks.
 * Do NOT deploy on zkSync, verifyCallback code needs to be updated for zkSync.
 */
contract ClSingleTickLiquidityHandlerV2 is ERC6909, IHandler, Pausable, AccessControl, LiquidityManager {
    using Math for uint128;
    using TickMath for int24;
    using SafeERC20 for IERC20;

    struct TokenIdInfo {
        uint128 totalLiquidity;
        uint128 totalSupply;
        uint128 liquidityUsed;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint64 lastDonation;
        uint128 donatedLiquidity;
        address token0;
        address token1;
        uint24 fee;
        uint128 reservedLiquidity;
    }

    struct MintPositionParams {
        IClPool pool;
        address hook;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct BurnPositionParams {
        IClPool pool;
        address hook;
        int24 tickLower;
        int24 tickUpper;
        uint128 shares;
    }

    struct ReserveLiquidityData {
        uint128 liquidity;
        uint64 lastReserve;
    }

    struct UsePositionParams {
        IClPool pool;
        address hook;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidityToUse;
    }

    struct UnusePositionParams {
        IClPool pool;
        address hook;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidityToUnuse;
    }

    struct DonateParams {
        IClPool pool;
        address hook;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidityToDonate;
    }

    struct MintPositionCache {
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtRatioTickLower;
        uint160 sqrtRatioTickUpper;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    struct BurnPositionCache {
        uint128 liquidityToBurn;
        uint256 amount0;
        uint256 amount1;
    }

    // events
    event LogMintedPosition(
        uint256 tokenId,
        uint128 liquidityMinted,
        address pool,
        address hook,
        address user,
        int24 tickLower,
        int24 tickUpper
    );
    event LogBurnedPosition(
        uint256 tokenId,
        uint128 liquidityBurned,
        address pool,
        address hook,
        address user,
        int24 tickLower,
        int24 tickUpper
    );

    event LogFeeCompound(
        address handler, IClPool pool, uint256 tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity
    );
    event LogUsePosition(uint256 tokenId, uint128 liquidityUsed);
    event LogUnusePosition(uint256 tokenId, uint128 liquidityUnused);
    event LogDonation(uint256 tokenId, uint128 liquidityDonated);
    event LogUpdateWhitelistedApp(address _app, bool _status);
    event LogUpdatedLockBlockAndReserveCooldownDuration(uint64 _newLockedBlockDuration, uint64 _newReserveCooldown);
    event LogReservedLiquidity(uint256 tokenId, uint128 liquidityReserved, address user);
    event LogWithdrawReservedLiquidity(uint256 tokenId, uint128 liquidityWithdrawn, address user);

    // errors
    error ClSingleTickLiquidityHandlerV2__NotWhitelisted();
    error ClSingleTickLiquidityHandlerV2__InRangeLP();
    error ClSingleTickLiquidityHandlerV2__InsufficientLiquidity();
    error ClSingleTickLiquidityHandlerV2__BeforeReserveCooldown();

    mapping(uint256 => TokenIdInfo) public tokenIds;
    mapping(address => bool) public whitelistedApps;
    mapping(uint256 => mapping(address => ReserveLiquidityData)) public reservedLiquidityPerUser;

    ISwapRouter swapRouter;

    uint64 public reserveCooldown = 6 hours;
    uint64 public lockedBlockDuration = 100;
    uint64 public newLockedBlockDuration;

    bytes32 constant PAUSER_ROLE = keccak256("P");
    bytes32 constant SOS_ROLE = keccak256("SOS");

    constructor(address _factory, bytes32 _pool_init_code_hash, address _swapRouter)
        LiquidityManager(_factory, _pool_init_code_hash)
    {
        swapRouter = ISwapRouter(_swapRouter);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Mints a new position for the user.
     * @param context The address of the user minting the position.
     * @param _mintPositionData The data required to mint the position.
     * @dev Only whitelisted DopexV2PositionManager can call it. It auto-compounds
     * the fees on mint. You cannot mint in range liquidity. Recommended to add liquidity
     * on a single ticks only.
     * @return sharesMinted The number of shares minted.
     */
    function mintPositionHandler(address context, bytes calldata _mintPositionData)
        external
        whenNotPaused
        returns (uint256 sharesMinted)
    {
        onlyWhitelisted();

        MintPositionParams memory _params = abi.decode(_mintPositionData, (MintPositionParams));

        uint256 tokenId = uint256(
            keccak256(abi.encode(address(this), _params.pool, _params.hook, _params.tickLower, _params.tickUpper))
        );

        TokenIdInfo storage tki = tokenIds[tokenId];

        if (tki.token0 == address(0)) {
            tki.token0 = _params.pool.token0();
            tki.token1 = _params.pool.token1();
            tki.fee = _params.pool.fee();
        }

        MintPositionCache memory posCache = MintPositionCache({
            tickLower: _params.tickLower,
            tickUpper: _params.tickUpper,
            sqrtRatioTickLower: _params.tickLower.getSqrtRatioAtTick(),
            sqrtRatioTickUpper: _params.tickUpper.getSqrtRatioAtTick(),
            liquidity: 0,
            amount0: 0,
            amount1: 0
        });

        (posCache.amount0, posCache.amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _getCurrentSqrtPriceX96(_params.pool),
            posCache.sqrtRatioTickLower,
            posCache.sqrtRatioTickUpper,
            uint128(_params.liquidity)
        );

        if (posCache.amount0 > 0 && posCache.amount1 > 0) {
            revert ClSingleTickLiquidityHandlerV2__InRangeLP();
        }

        (posCache.liquidity,,,) = addLiquidity(
            LiquidityManager.AddLiquidityParams({
                token0: tki.token0,
                token1: tki.token1,
                fee: tki.fee,
                recipient: address(this),
                tickLower: posCache.tickLower,
                tickUpper: posCache.tickUpper,
                amount0Desired: posCache.amount0,
                amount1Desired: posCache.amount1,
                amount0Min: posCache.amount0,
                amount1Min: posCache.amount1
            })
        );

        _feeCalculation(tki, _params.pool, posCache.tickLower, posCache.tickUpper);

        if (tki.totalSupply > 0) {
            // compound fees
            if (tki.tokensOwed0 > 1_000 || tki.tokensOwed1 > 1_000) {
                uint256 expectedAmountForLiquidity0 =
                    LiquidityAmounts.getAmount0ForLiquidity(posCache.sqrtRatioTickLower, posCache.sqrtRatioTickUpper, 2);

                uint256 expectedAmountForLiquidity1 =
                    LiquidityAmounts.getAmount1ForLiquidity(posCache.sqrtRatioTickLower, posCache.sqrtRatioTickUpper, 2);

                if (expectedAmountForLiquidity0 > tki.tokensOwed0 || expectedAmountForLiquidity1 > tki.tokensOwed1) {
                    bool isAmount0 = posCache.amount0 > 0;
                    (uint256 a0, uint256 a1) = _params.pool.collect(
                        address(this),
                        _params.tickLower,
                        _params.tickUpper,
                        uint128(tki.tokensOwed0),
                        uint128(tki.tokensOwed1)
                    );

                    (tki.tokensOwed0, tki.tokensOwed1) = (0, 0);

                    uint256 amountOut;
                    if (isAmount0 ? a1 > 0 : a0 > 0) {
                        IERC20(isAmount0 ? tki.token1 : tki.token0).safeIncreaseAllowance(
                            address(swapRouter), isAmount0 ? a1 : a0
                        );

                        amountOut = swapRouter.exactInputSingle(
                            ISwapRouter.ExactInputSingleParams({
                                tokenIn: isAmount0 ? tki.token1 : tki.token0,
                                tokenOut: isAmount0 ? tki.token0 : tki.token1,
                                fee: tki.fee,
                                recipient: address(this),
                                deadline: block.timestamp,
                                amountIn: isAmount0 ? a1 : a0,
                                amountOutMinimum: 0,
                                sqrtPriceLimitX96: 0
                            })
                        );
                    }

                    (uint128 liquidityFee,,,) = ClSingleTickLiquidityHandlerV2(address(this)).addLiquidity(
                        LiquidityManager.AddLiquidityParams({
                            token0: tki.token0,
                            token1: tki.token1,
                            fee: tki.fee,
                            recipient: address(this),
                            tickLower: _params.tickLower,
                            tickUpper: _params.tickUpper,
                            amount0Desired: a0 + (isAmount0 ? amountOut : 0),
                            amount1Desired: a1 + (isAmount0 ? 0 : amountOut),
                            amount0Min: a0 + (isAmount0 ? amountOut : 0),
                            amount1Min: a1 + (isAmount0 ? 0 : amountOut)
                        })
                    );
                    tki.totalLiquidity += liquidityFee;

                    emit LogFeeCompound(
                        address(this), _params.pool, tokenId, posCache.tickLower, posCache.tickUpper, liquidityFee
                    );
                }
            }

            uint128 shares = _convertToShares(posCache.liquidity, tokenId);

            tki.totalLiquidity += posCache.liquidity;
            tki.totalSupply += shares;

            sharesMinted = shares;
        } else {
            tki.totalLiquidity += posCache.liquidity;
            tki.totalSupply += posCache.liquidity;

            sharesMinted = posCache.liquidity;
        }

        _mint(context, tokenId, sharesMinted);

        emit LogMintedPosition(
            tokenId,
            posCache.liquidity,
            address(_params.pool),
            _params.hook,
            context,
            posCache.tickLower,
            posCache.tickUpper
        );
    }

    /**
     * @notice Burn an existing position.
     * @param context The address of the user burning the position.
     * @param _burnPositionData The data required to burn the position.
     * @dev Only whitelisted DopexV2PositionManager can call it. Users will receive the fees
     * in either token0 or token1 or both based on the fee collection.
     * @return The number of shares burned.
     */
    function burnPositionHandler(address context, bytes calldata _burnPositionData)
        external
        whenNotPaused
        returns (uint256)
    {
        onlyWhitelisted();

        BurnPositionParams memory _params = abi.decode(_burnPositionData, (BurnPositionParams));

        uint256 tokenId = uint256(
            keccak256(abi.encode(address(this), _params.pool, _params.hook, _params.tickLower, _params.tickUpper))
        );

        TokenIdInfo storage tki = tokenIds[tokenId];

        BurnPositionCache memory posCache = BurnPositionCache({liquidityToBurn: 0, amount0: 0, amount1: 0});

        posCache.liquidityToBurn = _convertToAssets(_params.shares, tokenId);

        if ((tki.totalLiquidity - tki.liquidityUsed) < posCache.liquidityToBurn) {
            revert ClSingleTickLiquidityHandlerV2__InsufficientLiquidity();
        }

        (posCache.amount0, posCache.amount1) =
            _params.pool.burn(_params.tickLower, _params.tickUpper, posCache.liquidityToBurn);

        _feeCalculation(tki, _params.pool, _params.tickLower, _params.tickUpper);

        (uint128 feesOwedToken0, uint128 feesOwedToken1) = _feesTokenOwed(
            _params.tickLower,
            _params.tickUpper,
            posCache.liquidityToBurn,
            tki.totalLiquidity,
            tki.tokensOwed0,
            tki.tokensOwed1
        );

        tki.tokensOwed0 -= feesOwedToken0;
        tki.tokensOwed1 -= feesOwedToken1;

        _params.pool.collect(
            context,
            _params.tickLower,
            _params.tickUpper,
            uint128(posCache.amount0 + feesOwedToken0),
            uint128(posCache.amount1 + feesOwedToken1)
        );

        tki.totalLiquidity -= posCache.liquidityToBurn;
        tki.totalSupply -= _params.shares;

        _burn(context, tokenId, _params.shares);

        emit LogBurnedPosition(
            tokenId,
            posCache.liquidityToBurn,
            address(_params.pool),
            _params.hook,
            context,
            _params.tickLower,
            _params.tickUpper
        );

        return (_params.shares);
    }

    /**
     * @notice Reserve Liquidity from future
     * @param _reserveLiquidityParam The data required for reserving liquidity.
     * @dev This can be called by the user directly, it uses msg.sender context. Users share would
     * be burned and they will receive Cl V3 fees upto this point.
     * @return The number of shares burned.
     */
    function reserveLiquidity(bytes calldata _reserveLiquidityParam) external whenNotPaused returns (uint256) {
        BurnPositionParams memory _params = abi.decode(_reserveLiquidityParam, (BurnPositionParams));

        uint256 tokenId = uint256(
            keccak256(abi.encode(address(this), _params.pool, _params.hook, _params.tickLower, _params.tickUpper))
        );

        TokenIdInfo storage tki = tokenIds[tokenId];

        uint128 liquidityToBurn = _convertToAssets(_params.shares, tokenId);

        _params.pool.burn(_params.tickLower, _params.tickUpper, 0);

        _feeCalculation(tki, _params.pool, _params.tickLower, _params.tickUpper);

        (uint128 feesOwedToken0, uint128 feesOwedToken1) = _feesTokenOwed(
            _params.tickLower, _params.tickUpper, liquidityToBurn, tki.totalLiquidity, tki.tokensOwed0, tki.tokensOwed1
        );

        tki.tokensOwed0 -= feesOwedToken0;
        tki.tokensOwed1 -= feesOwedToken1;

        _params.pool.collect(
            msg.sender, _params.tickLower, _params.tickUpper, uint128(feesOwedToken0), uint128(feesOwedToken1)
        );

        ReserveLiquidityData storage rld = reservedLiquidityPerUser[tokenId][msg.sender];

        rld.liquidity += liquidityToBurn;
        rld.lastReserve = uint64(block.timestamp);

        tki.totalLiquidity -= liquidityToBurn;
        tki.totalSupply -= _params.shares;

        tki.reservedLiquidity += liquidityToBurn;

        _burn(msg.sender, tokenId, _params.shares);

        emit LogBurnedPosition(
            tokenId,
            liquidityToBurn,
            address(_params.pool),
            _params.hook,
            msg.sender,
            _params.tickLower,
            _params.tickUpper
        );

        emit LogReservedLiquidity(tokenId, liquidityToBurn, msg.sender);

        return (_params.shares);
    }

    function _feesTokenOwed(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityToBurn,
        uint128 totalLiquidity,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) private view returns (uint128 feesOwedToken0, uint128 feesOwedToken1) {
        uint256 userLiquidity0 = LiquidityAmounts.getAmount0ForLiquidity(
            tickLower.getSqrtRatioAtTick(), tickUpper.getSqrtRatioAtTick(), liquidityToBurn
        );

        uint256 userLiquidity1 = LiquidityAmounts.getAmount1ForLiquidity(
            tickLower.getSqrtRatioAtTick(), tickUpper.getSqrtRatioAtTick(), liquidityToBurn
        );

        uint256 totalLiquidity0 = LiquidityAmounts.getAmount0ForLiquidity(
            tickLower.getSqrtRatioAtTick(), tickUpper.getSqrtRatioAtTick(), totalLiquidity
        );

        uint256 totalLiquidity1 = LiquidityAmounts.getAmount1ForLiquidity(
            tickLower.getSqrtRatioAtTick(), tickUpper.getSqrtRatioAtTick(), totalLiquidity
        );

        if (totalLiquidity0 > 0) {
            feesOwedToken0 = uint128((tokensOwed0 * userLiquidity0) / totalLiquidity0);
        }
        if (totalLiquidity1 > 0) {
            feesOwedToken1 = uint128((tokensOwed1 * userLiquidity1) / totalLiquidity1);
        }
    }

    /**
     * @notice Withdraw reserved liquidity
     * @param _reserveLiquidityParam The data required for withdraw reserved liquidity.
     * @dev This can be called by the user directly, it uses msg.sender context. Users can withdraw
     * liquidity if it is available and their cooldown is over.
     */
    function withdrawReserveLiquidity(bytes calldata _reserveLiquidityParam) external whenNotPaused {
        BurnPositionParams memory _params = abi.decode(_reserveLiquidityParam, (BurnPositionParams));

        uint256 tokenId = uint256(
            keccak256(abi.encode(address(this), _params.pool, _params.hook, _params.tickLower, _params.tickUpper))
        );

        TokenIdInfo storage tki = tokenIds[tokenId];
        ReserveLiquidityData storage rld = reservedLiquidityPerUser[tokenId][msg.sender];

        if (rld.lastReserve + reserveCooldown > block.timestamp) {
            revert ClSingleTickLiquidityHandlerV2__BeforeReserveCooldown();
        }

        if (((tki.totalLiquidity + tki.reservedLiquidity) - tki.liquidityUsed) < _params.shares) {
            revert ClSingleTickLiquidityHandlerV2__InsufficientLiquidity();
        }

        (uint256 amount0, uint256 amount1) = _params.pool.burn(_params.tickLower, _params.tickUpper, _params.shares);

        _params.pool.collect(msg.sender, _params.tickLower, _params.tickUpper, uint128(amount0), uint128(amount1));

        _feeCalculation(tki, _params.pool, _params.tickLower, _params.tickUpper);

        tki.reservedLiquidity -= _params.shares;
        rld.liquidity -= _params.shares;

        emit LogWithdrawReservedLiquidity(tokenId, _params.shares, msg.sender);
    }

    /**
     * @notice Use an existing position.
     * @param _usePositionHandler The data required to use the position.
     * @dev Only whitelisted DopexV2PositionManager can call it.
     * @return tokens The addresses of the tokens that were unwrapped.
     * @return amounts The amounts of the tokens that were unwrapped.
     * @return liquidityUsed The amount of liquidity that was used.
     */
    function usePositionHandler(bytes calldata _usePositionHandler)
        external
        whenNotPaused
        returns (address[] memory, uint256[] memory, uint256)
    {
        onlyWhitelisted();

        (UsePositionParams memory _params, bytes memory hookData) =
            abi.decode(_usePositionHandler, (UsePositionParams, bytes));

        uint256 tokenId = uint256(
            keccak256(abi.encode(address(this), _params.pool, _params.hook, _params.tickLower, _params.tickUpper))
        );

        TokenIdInfo storage tki = tokenIds[tokenId];

        if (_params.hook != address(0)) {
            IHook(_params.hook).onPositionUse(hookData);
        }

        if ((tki.totalLiquidity - tki.liquidityUsed) < _params.liquidityToUse) {
            revert ClSingleTickLiquidityHandlerV2__InsufficientLiquidity();
        }

        (uint256 amount0, uint256 amount1) =
            _params.pool.burn(_params.tickLower, _params.tickUpper, uint128(_params.liquidityToUse));

        _params.pool.collect(msg.sender, _params.tickLower, _params.tickUpper, uint128(amount0), uint128(amount1));

        _feeCalculation(tki, _params.pool, _params.tickLower, _params.tickUpper);

        tki.liquidityUsed += _params.liquidityToUse;

        address[] memory tokens = new address[](2);
        tokens[0] = tki.token0;
        tokens[1] = tki.token1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        emit LogUsePosition(tokenId, _params.liquidityToUse);
        return (tokens, amounts, _params.liquidityToUse);
    }

    /**
     * @notice Unuse a portion of an existing position.
     * @param _unusePositionData The data required to unuse the position.
     * @dev Only whitelisted DopexV2PositionManager can call it.
     * @return amounts The amounts of the tokens that were wrapped.
     * @return liquidityUnused The amount of liquidity that was unused.
     */
    function unusePositionHandler(bytes calldata _unusePositionData)
        external
        whenNotPaused
        returns (uint256[] memory, uint256)
    {
        onlyWhitelisted();

        (UnusePositionParams memory _params, bytes memory hookData) =
            abi.decode(_unusePositionData, (UnusePositionParams, bytes));

        uint256 tokenId = uint256(
            keccak256(abi.encode(address(this), _params.pool, _params.hook, _params.tickLower, _params.tickUpper))
        );

        TokenIdInfo storage tki = tokenIds[tokenId];

        if (_params.hook != address(0)) {
            IHook(_params.hook).onPositionUnUse(hookData);
        }

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _getCurrentSqrtPriceX96(_params.pool),
            _params.tickLower.getSqrtRatioAtTick(),
            _params.tickUpper.getSqrtRatioAtTick(),
            uint128(_params.liquidityToUnuse)
        );

        (uint128 liquidity,,,) = addLiquidity(
            LiquidityManager.AddLiquidityParams({
                token0: tki.token0,
                token1: tki.token1,
                fee: tki.fee,
                recipient: address(this),
                tickLower: _params.tickLower,
                tickUpper: _params.tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0,
                amount1Min: amount1
            })
        );

        _feeCalculation(tki, _params.pool, _params.tickLower, _params.tickUpper);

        if (tki.liquidityUsed >= liquidity) {
            tki.liquidityUsed -= liquidity;
        } else {
            tki.totalLiquidity += (liquidity - tki.liquidityUsed);
            tki.liquidityUsed = 0;
        }

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        emit LogUnusePosition(tokenId, liquidity);
        return (amounts, uint256(liquidity));
    }

    /**
     * @notice Donate liquidity to an existing position.
     * @param _donateData The data required to donate liquidity to the position.
     * @dev Only whitelisted DopexV2PositionManager can call it.
     * @return amounts The amounts of the tokens that were donated.
     * @return liquidityDonated The amount of liquidity that was donated.
     */
    function donateToPosition(bytes calldata _donateData) external whenNotPaused returns (uint256[] memory, uint256) {
        onlyWhitelisted();

        DonateParams memory _params = abi.decode(_donateData, (DonateParams));

        uint256 tokenId = uint256(
            keccak256(abi.encode(address(this), _params.pool, _params.hook, _params.tickLower, _params.tickUpper))
        );

        TokenIdInfo storage tki = tokenIds[tokenId];

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _getCurrentSqrtPriceX96(_params.pool),
            _params.tickLower.getSqrtRatioAtTick(),
            _params.tickUpper.getSqrtRatioAtTick(),
            uint128(_params.liquidityToDonate)
        );

        (uint128 liquidity,,,) = addLiquidity(
            LiquidityManager.AddLiquidityParams({
                token0: tki.token0,
                token1: tki.token1,
                fee: tki.fee,
                recipient: address(this),
                tickLower: _params.tickLower,
                tickUpper: _params.tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0,
                amount1Min: amount1
            })
        );

        _feeCalculation(tki, _params.pool, _params.tickLower, _params.tickUpper);

        tki.totalLiquidity += liquidity;

        tki.donatedLiquidity = _donationLocked(tokenId) + liquidity;

        tki.lastDonation = uint64(block.number);

        if (newLockedBlockDuration != 0) {
            lockedBlockDuration = newLockedBlockDuration;
            newLockedBlockDuration = 0;
        }

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        emit LogDonation(tokenId, liquidity);
        return (amounts, liquidity);
    }

    /**
     * @notice Calculates the fees owed to the position.
     * @param _tki The TokenIdInfo struct for the position.
     * @param _pool The ClPool contract.
     * @param _tickLower The lower tick of the position.
     * @param _tickUpper The upper tick of the position.
     */
    function _feeCalculation(TokenIdInfo storage _tki, IClPool _pool, int24 _tickLower, int24 _tickUpper)
        internal
    {
        bytes32 positionKey = _computePositionKey(address(this), _tickLower, _tickUpper);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,,) = _pool.positions(positionKey);
        unchecked {
            _tki.tokensOwed0 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - _tki.feeGrowthInside0LastX128,
                    _tki.totalLiquidity + _tki.reservedLiquidity - _tki.liquidityUsed,
                    FixedPoint128.Q128
                )
            );
            _tki.tokensOwed1 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - _tki.feeGrowthInside1LastX128,
                    _tki.totalLiquidity + _tki.reservedLiquidity - _tki.liquidityUsed,
                    FixedPoint128.Q128
                )
            );

            _tki.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
            _tki.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        }
    }

    /**
     * @notice Calculates the handler identifier for a position.
     * @param _data The encoded position data.
     * @return handlerIdentifierId The handler identifier for the position.
     */
    function getHandlerIdentifier(bytes calldata _data) external view returns (uint256 handlerIdentifierId) {
        (IClPool pool, address hook, int24 tickLower, int24 tickUpper) =
            abi.decode(_data, (IClPool, address, int24, int24));

        return uint256(keccak256(abi.encode(address(this), pool, hook, tickLower, tickUpper)));
    }

    /**
     * @notice Calculates the amount of tokens that need to be pulled for a mint position.
     * @param _mintPositionData The encoded mint position data.
     * @return tokens The tokens that need to be pulled.
     * @return amounts The amount of each token that needs to be pulled.
     */
    function tokensToPullForMint(bytes calldata _mintPositionData)
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        return _tokensToPull(_mintPositionData);
    }

    /**
     * @notice Calculates the amount of tokens that need to be pulled for an unuse position.
     * @param _unusePositionData The encoded unuse position data.
     * @return tokens The tokens that need to be pulled.
     * @return amounts The amount of each token that needs to be pulled.
     */
    function tokensToPullForUnUse(bytes calldata _unusePositionData)
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        return _tokensToPull(_unusePositionData);
    }

    /**
     * @notice Calculates the amount of tokens that need to be pulled for a donate position.
     * @param _donatePosition The encoded donate position data.
     * @return tokens The tokens that need *
     */
    function tokensToPullForDonate(bytes calldata _donatePosition)
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        return _tokensToPull(_donatePosition);
    }

    function _tokensToPull(bytes calldata _positionData) private view returns (address[] memory, uint256[] memory) {
        MintPositionParams memory _params = abi.decode(_positionData, (MintPositionParams));

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _getCurrentSqrtPriceX96(_params.pool),
            _params.tickLower.getSqrtRatioAtTick(),
            _params.tickUpper.getSqrtRatioAtTick(),
            uint128(_params.liquidity)
        );

        address[] memory tokens = new address[](2);
        tokens[0] = _params.pool.token0();
        tokens[1] = _params.pool.token1();

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        return (tokens, amounts);
    }

    /**
     * @notice Calculates the amount of donated liquidity that is locked.
     * @param tokenId The tokenId of the position.
     * @return donationLocked The amount of donated liquidity that is locked.
     */
    function _donationLocked(uint256 tokenId) internal view returns (uint128) {
        TokenIdInfo memory tki = tokenIds[tokenId];

        if (block.number >= tki.lastDonation + lockedBlockDuration) return 0;

        uint128 donationLocked = tki.donatedLiquidity
            - (tki.donatedLiquidity * (uint64(block.number) - tki.lastDonation)) / lockedBlockDuration;

        return donationLocked;
    }

    /**
     * @notice Converts an amount of assets to shares.
     * @param assets The amount of assets.
     * @param tokenId The tokenId of the position.
     * @return shares The number of shares.
     */
    function convertToShares(uint128 assets, uint256 tokenId) external view returns (uint128) {
        return _convertToShares(assets, tokenId);
    }

    /**
     * @notice Converts an amount of shares to assets.
     * @param shares The number of shares.
     * @param tokenId The tokenId of the position.
     * @return assets The amount of assets.
     */
    function convertToAssets(uint128 shares, uint256 tokenId) external view returns (uint128) {
        return _convertToAssets(shares, tokenId);
    }

    /**
     * @notice Converts an amount of assets to shares.
     * @param assets The amount of assets.
     * @param tokenId The tokenId of the position.
     * @return shares The number of shares.
     */
    function _convertToShares(uint128 assets, uint256 tokenId) internal view returns (uint128) {
        return uint128(
            assets.mulDiv(
                tokenIds[tokenId].totalSupply,
                (tokenIds[tokenId].totalLiquidity + 1) - _donationLocked(tokenId),
                Math.Rounding.Down
            )
        );
    }

    /**
     * @notice Converts an amount of shares to assets.
     * @param shares The number of shares.
     * @param tokenId The tokenId of the position.
     * @return assets The amount of assets.
     */
    function _convertToAssets(uint128 shares, uint256 tokenId) internal view returns (uint128) {
        return uint128(
            shares.mulDiv(
                (tokenIds[tokenId].totalLiquidity + 1) - _donationLocked(tokenId),
                tokenIds[tokenId].totalSupply,
                Math.Rounding.Up
            )
        );
    }

    /**
     * @notice Gets the current sqrtPriceX96 of the given ClPool.
     * @param pool The ClPool to get the sqrtPriceX96 from.
     * @return sqrtPriceX96 The current sqrtPriceX96 of the given ClPool.
     */
    function _getCurrentSqrtPriceX96(IClPool pool) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = pool.slot0();
    }

    /**
     * @notice Computes the position key for the given owner, tickLower, and tickUpper.
     * @param owner The owner of the position.
     * @param tickLower The lower tick of the position.
     * @param tickUpper The upper tick of the position.
     * @return positionKey The position key for the given owner, tickLower, and tickUpper.
     */
    function _computePositionKey(address owner, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    function getTokenIdData(uint256 tokenId) external view returns (TokenIdInfo memory) {
        return tokenIds[tokenId];
    }

    function onlyWhitelisted() private {
        if (!whitelistedApps[msg.sender]) {
            revert ClSingleTickLiquidityHandlerV2__NotWhitelisted();
        }
    }

    // admin functions

    /**
     * @notice Updates the whitelist status of the given app.
     * @param _app The app to update the whitelist status of.
     * @param _status The new whitelist status of the app.
     */
    function updateWhitelistedApps(address _app, bool _status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelistedApps[_app] = _status;
        emit LogUpdateWhitelistedApp(_app, _status);
    }

    /**
     * @notice Updates the locked block duration and reserve cooldown.
     * @param _newLockedBlockDuration The new lock block duration.
     * @param _newReserveCooldown The new reserve cooldown.
     */
    function updateLockedBlockDurationAndReserveCooldown(uint64 _newLockedBlockDuration, uint64 _newReserveCooldown)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        newLockedBlockDuration = _newLockedBlockDuration;
        reserveCooldown = _newReserveCooldown;
        emit LogUpdatedLockBlockAndReserveCooldownDuration(_newLockedBlockDuration, _newReserveCooldown);
    }

    // SOS admin functions

    /**
     * @notice Forcefully withdraws Cl liquidity from the given position.
     * @param pool The ClPool to withdraw liquidity from.
     * @param tickLower The lower tick of the position to withdraw liquidity from.
     * @param tickUpper The upper tick of the position to withdraw liquidity from.
     * @param liquidity The amount of liquidity to withdraw.
     * @param token The token to recover from this pool
     */
    function forceWithdrawClLiquidityAndToken(
        IClPool pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address token
    ) external onlyRole(SOS_ROLE) {
        if (token != address(0)) {
            IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
            return;
        }
        pool.burn(tickLower, tickUpper, liquidity);
        (,,, uint128 t0, uint128 t1) = pool.positions(_computePositionKey(address(this), tickLower, tickUpper));
        pool.collect(msg.sender, tickLower, tickUpper, t0, t1);
    }

    /**
     * @notice Emergency pauses the contract.
     */
    function emergencyPause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Emergency unpauses the contract.
     */
    function emergencyUnpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Interface Support
     * @param interfaceId The Id of the interface
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC6909, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
