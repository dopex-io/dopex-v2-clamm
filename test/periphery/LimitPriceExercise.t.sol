// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {UniswapV3TestLib} from "../uniswap-v3-utils/UniswapV3TestLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";

import {DopexV2PositionManager} from "../../src/DopexV2PositionManager.sol";
import {PositionManagerHandler} from "../handlers/PositionManager.handler.sol";
import {UniswapV3SingleTickLiquidityHandler} from "../../src/handlers/UniswapV3SingleTickLiquidityHandler.sol";
import {DopexV2OptionMarket} from "../../src/DopexV2OptionMarket.sol";

import {OptionPricing} from "../pricing/OptionPricing.sol";
import {DopexV2ClammFeeStrategy} from "../../src/pricing/fees/DopexV2ClammFeeStrategy.sol";
import {SwapRouterSwapper} from "../../src/swapper/SwapRouterSwapper.sol";
import {LimitExercise} from "../../src/periphery/LimitExercise.sol";

import {IOptionPricing} from "../../src/pricing/IOptionPricing.sol";
import {IHandler} from "../../src/interfaces/IHandler.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";
import {IOptionMarket} from "../../src/interfaces/IOptionMarket.sol";

contract LimitExerciseTest is Test {
    using TickMath for int24;

    address ETH; // token1
    address LUSD; // token0

    ERC20Mock token0;
    ERC20Mock token1;

    UniswapV3TestLib uniswapV3TestLib;
    IUniswapV3Pool pool;

    OptionPricing op;
    SwapRouterSwapper srs;

    uint24 fee = 500;

    uint160 initSqrtPriceX96 = 1771845812700903892492222464; // 1 ETH = 2000 LUSD

    int24 tickLowerCalls = -76260; // ~2050
    int24 tickUpperCalls = -76250; // ~2048

    int24 tickLowerPuts = -75770; // ~1950
    int24 tickUpperPuts = -75760; // ~1952

    uint256 premiumAmountCalls = 100;
    uint256 premiumAmountPuts = 100;

    uint256 optionIdCalls;
    uint256 optionIdPuts;

    address alice = makeAddr("alice"); // main LP
    address bob = makeAddr("bob"); // protocol LP
    address jason = makeAddr("jason"); // protocol LP
    address trader = makeAddr("trader"); // option buyer
    address garbage = makeAddr("garbage"); // garbage address
    address bot = makeAddr("bot"); // bot address

    DopexV2PositionManager positionManager;
    PositionManagerHandler positionManagerHandler;
    DopexV2OptionMarket optionMarket;
    UniswapV3SingleTickLiquidityHandler uniV3Handler;
    DopexV2ClammFeeStrategy feeStrategy;
    LimitExercise limitExercise;

    function setUp() public {
        vm.warp(1693352493);

        ETH = address(new ERC20Mock());
        LUSD = address(new ERC20Mock());

        uniswapV3TestLib = new UniswapV3TestLib();
        pool = IUniswapV3Pool(
            uniswapV3TestLib.deployUniswapV3PoolAndInitializePrice(
                ETH,
                LUSD,
                fee,
                initSqrtPriceX96
            )
        );

        token0 = ERC20Mock(pool.token0());
        token1 = ERC20Mock(pool.token1());

        positionManager = new DopexV2PositionManager();

        limitExercise = new LimitExercise();

        uniV3Handler = new UniswapV3SingleTickLiquidityHandler(
            address(uniswapV3TestLib.factory()),
            0xa598dd2fba360510c5a8f02f44423a4468e902df5857dbce3ca162a43a3a31ff,
            address(uniswapV3TestLib.swapRouter())
        );

        positionManagerHandler = new PositionManagerHandler(
            uniswapV3TestLib,
            positionManager,
            uniV3Handler
        );

        op = new OptionPricing(500, 1e8);
        srs = new SwapRouterSwapper(address(uniswapV3TestLib.swapRouter()));

        feeStrategy = new DopexV2ClammFeeStrategy();

        optionMarket = new DopexV2OptionMarket(
            address(positionManager),
            address(op),
            address(feeStrategy),
            ETH,
            LUSD,
            address(pool)
        );

        // Add 0.15% fee to the market
        feeStrategy.registerOptionMarket(address(optionMarket), 350000);

        uint256[] memory ttls = new uint256[](1);
        ttls[0] = 20 minutes;

        uint256[] memory IVs = new uint256[](1);
        IVs[0] = 100;

        address feeCollector = makeAddr("feeCollector");

        optionMarket.updateIVs(ttls, IVs);
        optionMarket.updateAddress(
            feeCollector,
            address(0),
            address(feeStrategy),
            address(op),
            address(this),
            true,
            address(pool),
            true
        );
        uniswapV3TestLib.addLiquidity(
            UniswapV3TestLib.AddLiquidityStruct({
                user: alice,
                pool: pool,
                desiredTickLower: -78245, // 2500
                desiredTickUpper: -73136, // 1500
                desiredAmount0: 5_000_000e18,
                desiredAmount1: 0,
                requireMint: true
            })
        );

        positionManager.updateWhitelistHandlerWithApp(
            address(uniV3Handler),
            address(optionMarket),
            true
        );

        positionManager.updateWhitelistHandler(address(uniV3Handler), true);

        uniV3Handler.updateWhitelistedApps(address(positionManager), true);

        // for calls
        positionManagerHandler.mintPosition(
            token0,
            token1,
            0,
            5e18,
            -76260, // ~2050,
            -76250, // ~2048,
            pool,
            bob
        );

        positionManagerHandler.mintPosition(
            token0,
            token1,
            0,
            5e18,
            -76260, // ~2050,
            -76250, // ~2048,
            pool,
            jason
        );

        // for puts
        positionManagerHandler.mintPosition(
            token0,
            token1,
            10_000e18,
            0,
            -75770, // ~1950,
            -75760, // ~1952,
            pool,
            bob
        );

        positionManagerHandler.mintPosition(
            token0,
            token1,
            10_000e18,
            0,
            -75770, // ~1950,
            -75760, // ~1952,
            pool,
            jason
        );
    }

    function testFailKeeperAccessControl() public {
        vm.startPrank(trader);

        LimitExercise.Order memory _order;
        IOptionMarket.ExerciseOptionParams memory _params;
        LimitExercise.SignatureMeta memory _sigMeta;

        limitExercise.limitExercise(_order, _sigMeta, _params);
        vm.stopPrank();
    }

    function testVerifySignature() public {
        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), trader);

        vm.startPrank(trader);

        (, uint256 privateKey0) = makeAddrAndKey("alice");
        (, uint256 privateKey1) = makeAddrAndKey("trader");

        bytes32 digest0 = limitExercise.computeDigest(
            LimitExercise.Order(1, 2, 3, address(0), address(1), address(1))
        );
        bytes32 digest1 = limitExercise.computeDigest(
            LimitExercise.Order(2, 3, 4, address(0), address(2), address(1))
        );

        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(privateKey0, digest0);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(privateKey1, digest1);

        assertEq(
            limitExercise.verify(
                alice,
                LimitExercise.Order(
                    1,
                    2,
                    3,
                    address(0),
                    address(1),
                    address(1)
                ),
                LimitExercise.SignatureMeta(v0, r0, s0)
            ),
            true
        );

        assertEq(
            limitExercise.verify(
                alice,
                LimitExercise.Order(
                    1,
                    2,
                    3,
                    address(1),
                    address(1),
                    address(1)
                ),
                LimitExercise.SignatureMeta(v0, r1, s0)
            ),
            false
        );

        assertEq(
            limitExercise.verify(
                alice,
                LimitExercise.Order(
                    1,
                    2,
                    3,
                    address(1),
                    address(1),
                    address(1)
                ),
                LimitExercise.SignatureMeta(v0, r1, s1)
            ),
            false
        );

        assertEq(
            limitExercise.verify(
                alice,
                LimitExercise.Order(
                    1,
                    2,
                    3,
                    address(1),
                    address(1),
                    address(1)
                ),
                LimitExercise.SignatureMeta(v0, r0, s1)
            ),
            false
        );

        assertEq(
            limitExercise.verify(
                alice,
                LimitExercise.Order(
                    1,
                    2,
                    3,
                    address(1),
                    address(1),
                    address(1)
                ),
                LimitExercise.SignatureMeta(v0, r0, s1)
            ),
            false
        );

        assertEq(
            limitExercise.verify(
                trader,
                LimitExercise.Order(
                    1,
                    2,
                    3,
                    address(1),
                    address(1),
                    address(1)
                ),
                LimitExercise.SignatureMeta(v0, r0, s0)
            ),
            false
        );

        assertEq(
            limitExercise.verify(
                trader,
                LimitExercise.Order(
                    1,
                    2,
                    3,
                    address(1),
                    address(1),
                    address(1)
                ),
                LimitExercise.SignatureMeta(v1, r1, s1)
            ),
            false
        );

        assertEq(
            limitExercise.verify(
                trader,
                LimitExercise.Order(
                    2,
                    3,
                    4,
                    address(0),
                    address(2),
                    address(1)
                ),
                LimitExercise.SignatureMeta(v1, r1, s1)
            ),
            true
        );

        vm.stopPrank();
    }

    function testFailOptionIdsMisMatch() public {
        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), trader);

        vm.startPrank(trader);

        (, uint256 privateKey) = makeAddrAndKey("trader");

        bytes32 digest = limitExercise.computeDigest(
            LimitExercise.Order(3, 0, 0, address(1), address(0), address(0))
        );

        IOptionMarket.ExerciseOptionParams memory _params;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        limitExercise.limitExercise(
            LimitExercise.Order(1, 0, 0, address(1), address(0), address(0)),
            LimitExercise.SignatureMeta(v, r, s),
            _params
        );

        vm.stopPrank();
    }

    function testLimitExerciseCall() public {
        vm.startPrank(trader);
        uint256 l = LiquidityAmounts.getLiquidityForAmount1(
            tickLowerCalls.getSqrtRatioAtTick(),
            tickUpperCalls.getSqrtRatioAtTick(),
            5e18
        );
        uint256 _premiumAmount = optionMarket.getPremiumAmount(
            false,
            block.timestamp + 20 minutes,
            optionMarket.getPricePerCallAssetViaTick(pool, tickUpperCalls),
            optionMarket.getCurrentPricePerCallAsset(pool),
            optionMarket.ttlToVol(20 minutes),
            5e18
        );
        uint256 _fee = optionMarket.getFee(0, 0, _premiumAmount);
        uint256 cost = _premiumAmount + _fee;
        token1.mint(trader, cost);
        token1.approve(address(optionMarket), cost);
        DopexV2OptionMarket.OptionTicks[]
            memory opTicks = new DopexV2OptionMarket.OptionTicks[](1);
        opTicks[0] = DopexV2OptionMarket.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            tickLower: tickLowerCalls,
            tickUpper: tickUpperCalls,
            liquidityToUse: l
        });
        optionMarket.mintOption(
            DopexV2OptionMarket.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerCalls,
                tickUpper: tickUpperCalls,
                ttl: 20 minutes,
                isCall: true,
                maxCostAllowance: cost
            })
        );
        vm.stopPrank();

        (, uint256 privateKey) = makeAddrAndKey("trader");

        uint256 optionId = 1;

        uint256 totalProfit = 137046592384897080728;
        uint256 minProfit = 5e18;
        LimitExercise.Order memory order = LimitExercise.Order(
            1,
            5e18,
            block.timestamp + 20 minutes,
            address(token0),
            address(optionMarket),
            trader
        );

        LimitExercise.SignatureMeta memory sigMeta;

        bytes32 digest = limitExercise.computeDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        sigMeta.v = v;
        sigMeta.r = r;
        sigMeta.s = s;

        assertEq(
            limitExercise.verify(
                trader,
                order,
                LimitExercise.SignatureMeta(v, r, s)
            ),
            true
        );

        vm.startPrank(trader);
        optionMarket.updateExerciseDelegate(address(limitExercise), true);
        vm.stopPrank();

        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), bot);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 400000e18, // pushes to 2078
                zeroForOne: true,
                requireMint: true
            })
        );

        assertEqUint(token0.balanceOf(trader), 0);
        assertEqUint(token0.balanceOf(bot), 0);

        vm.startPrank(bot);
        limitExercise.limitExercise(
            order,
            sigMeta,
            _getExerciseParams(optionId)
        );

        assertEqUint(token0.balanceOf(trader), minProfit);
        assertEqUint(token0.balanceOf(bot), totalProfit - minProfit);
    }

    function testFuzzMinProfit(uint256 _minProfit) public {
        console.log(_minProfit);
        if (_minProfit == 0) return;
        vm.startPrank(trader);

        uint256 l = LiquidityAmounts.getLiquidityForAmount0(
            tickLowerPuts.getSqrtRatioAtTick(),
            tickUpperPuts.getSqrtRatioAtTick(),
            10_000e18
        );

        uint256 _premiumAmountPuts = optionMarket.getPremiumAmount(
            true,
            block.timestamp + 20 minutes,
            optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts),
            optionMarket.getCurrentPricePerCallAsset(pool),
            optionMarket.ttlToVol(20 minutes),
            (10_000e18 * 1e18) /
                optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts)
        );

        uint256 _fee = optionMarket.getFee(0, 0, _premiumAmountPuts);
        uint256 cost = _premiumAmountPuts + _fee;
        token0.mint(trader, cost);
        token0.approve(address(optionMarket), cost);

        DopexV2OptionMarket.OptionTicks[]
            memory opTicks = new DopexV2OptionMarket.OptionTicks[](1);

        opTicks[0] = DopexV2OptionMarket.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            tickLower: tickLowerPuts,
            tickUpper: tickUpperPuts,
            liquidityToUse: l
        });

        optionMarket.mintOption(
            DopexV2OptionMarket.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerPuts,
                tickUpper: tickUpperPuts,
                ttl: 20 minutes,
                isCall: false,
                maxCostAllowance: cost
            })
        );
        vm.stopPrank();

        (, uint256 privateKey) = makeAddrAndKey("trader");

        uint256 optionId = 1;

        uint256 totalProfit = 119820039967268616;

        if (_minProfit > totalProfit) return;

        LimitExercise.Order memory order = LimitExercise.Order(
            1,
            _minProfit,
            block.timestamp + 20 minutes,
            address(token1),
            address(optionMarket),
            trader
        );

        LimitExercise.SignatureMeta memory sigMeta;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            limitExercise.computeDigest(order)
        );

        sigMeta.v = v;
        sigMeta.r = r;
        sigMeta.s = s;

        vm.startPrank(trader);
        optionMarket.updateExerciseDelegate(address(limitExercise), true);
        vm.stopPrank();

        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), bot);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 250e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        vm.startPrank(bot);
        limitExercise.limitExercise(
            order,
            sigMeta,
            _getExerciseParams(optionId)
        );

        assertEqUint(token1.balanceOf(trader), _minProfit);
        assertEqUint(token1.balanceOf(bot), totalProfit - _minProfit);
    }

    function testLimitExercisePut() public {
        vm.startPrank(trader);

        uint256 l = LiquidityAmounts.getLiquidityForAmount0(
            tickLowerPuts.getSqrtRatioAtTick(),
            tickUpperPuts.getSqrtRatioAtTick(),
            10_000e18
        );

        uint256 _premiumAmountPuts = optionMarket.getPremiumAmount(
            true,
            block.timestamp + 20 minutes,
            optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts),
            optionMarket.getCurrentPricePerCallAsset(pool),
            optionMarket.ttlToVol(20 minutes),
            (10_000e18 * 1e18) /
                optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts)
        );

        uint256 _fee = optionMarket.getFee(0, 0, _premiumAmountPuts);
        uint256 cost = _premiumAmountPuts + _fee;
        token0.mint(trader, cost);
        token0.approve(address(optionMarket), cost);

        DopexV2OptionMarket.OptionTicks[]
            memory opTicks = new DopexV2OptionMarket.OptionTicks[](1);

        opTicks[0] = DopexV2OptionMarket.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            tickLower: tickLowerPuts,
            tickUpper: tickUpperPuts,
            liquidityToUse: l
        });

        optionMarket.mintOption(
            DopexV2OptionMarket.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerPuts,
                tickUpper: tickUpperPuts,
                ttl: 20 minutes,
                isCall: false,
                maxCostAllowance: cost
            })
        );
        vm.stopPrank();

        (, uint256 privateKey) = makeAddrAndKey("trader");

        uint256 optionId = 1;

        uint256 totalProfit = 119820039967268616;
        uint256 minProfit = 0.05 ether;
        LimitExercise.Order memory order = LimitExercise.Order(
            1,
            minProfit,
            block.timestamp + 20 minutes,
            address(token1),
            address(optionMarket),
            trader
        );

        LimitExercise.SignatureMeta memory sigMeta;

        bytes32 digest = limitExercise.computeDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        sigMeta.v = v;
        sigMeta.r = r;
        sigMeta.s = s;

        vm.startPrank(trader);
        optionMarket.updateExerciseDelegate(address(limitExercise), true);
        vm.stopPrank();

        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), bot);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 250e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        vm.startPrank(bot);
        limitExercise.limitExercise(
            order,
            sigMeta,
            _getExerciseParams(optionId)
        );

        assertEqUint(token1.balanceOf(trader), minProfit);
        assertEqUint(token1.balanceOf(bot), totalProfit - minProfit);
    }

    function testCancelLimitExerciseOrder() public {
        vm.startPrank(trader);

        uint256 l = LiquidityAmounts.getLiquidityForAmount0(
            tickLowerPuts.getSqrtRatioAtTick(),
            tickUpperPuts.getSqrtRatioAtTick(),
            10_000e18
        );

        uint256 _premiumAmountPuts = optionMarket.getPremiumAmount(
            true,
            block.timestamp + 20 minutes,
            optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts),
            optionMarket.getCurrentPricePerCallAsset(pool),
            optionMarket.ttlToVol(20 minutes),
            (10_000e18 * 1e18) /
                optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts)
        );

        uint256 _fee = optionMarket.getFee(0, 0, _premiumAmountPuts);
        uint256 cost = _premiumAmountPuts + _fee;
        token0.mint(trader, cost);
        token0.approve(address(optionMarket), cost);

        DopexV2OptionMarket.OptionTicks[]
            memory opTicks = new DopexV2OptionMarket.OptionTicks[](1);

        opTicks[0] = DopexV2OptionMarket.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            tickLower: tickLowerPuts,
            tickUpper: tickUpperPuts,
            liquidityToUse: l
        });

        optionMarket.mintOption(
            DopexV2OptionMarket.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerPuts,
                tickUpper: tickUpperPuts,
                ttl: 20 minutes,
                isCall: false,
                maxCostAllowance: cost
            })
        );
        vm.stopPrank();

        (, uint256 privateKey) = makeAddrAndKey("trader");

        LimitExercise.Order memory order = LimitExercise.Order(
            1,
            0.05 ether,
            block.timestamp + 20 minutes,
            address(token1),
            address(optionMarket),
            trader
        );

        LimitExercise.SignatureMeta memory sigMeta;

        bytes32 digest = limitExercise.computeDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        sigMeta.v = v;
        sigMeta.r = r;
        sigMeta.s = s;

        vm.startPrank(trader);
        optionMarket.updateExerciseDelegate(address(limitExercise), true);
        vm.stopPrank();

        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), bot);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 250e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        bytes32 orderSigHash = limitExercise.getOrderSigHash(order, sigMeta);
        assertEq(limitExercise.cancelledOrders(orderSigHash), false);

        vm.startPrank(trader);
        limitExercise.cancelOrder(order, sigMeta);
        vm.stopPrank();

        assertEq(limitExercise.cancelledOrders(orderSigHash), true);
    }

    function testFailCancelLimitOrderFromNotSigner() public {
        vm.startPrank(trader);

        uint256 l = LiquidityAmounts.getLiquidityForAmount0(
            tickLowerPuts.getSqrtRatioAtTick(),
            tickUpperPuts.getSqrtRatioAtTick(),
            10_000e18
        );

        uint256 _premiumAmountPuts = optionMarket.getPremiumAmount(
            true,
            block.timestamp + 20 minutes,
            optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts),
            optionMarket.getCurrentPricePerCallAsset(pool),
            optionMarket.ttlToVol(20 minutes),
            (10_000e18 * 1e18) /
                optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts)
        );

        uint256 _fee = optionMarket.getFee(0, 0, _premiumAmountPuts);
        uint256 cost = _premiumAmountPuts + _fee;
        token0.mint(trader, cost);
        token0.approve(address(optionMarket), cost);

        DopexV2OptionMarket.OptionTicks[]
            memory opTicks = new DopexV2OptionMarket.OptionTicks[](1);

        opTicks[0] = DopexV2OptionMarket.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            tickLower: tickLowerPuts,
            tickUpper: tickUpperPuts,
            liquidityToUse: l
        });

        optionMarket.mintOption(
            DopexV2OptionMarket.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerPuts,
                tickUpper: tickUpperPuts,
                ttl: 20 minutes,
                isCall: false,
                maxCostAllowance: cost
            })
        );
        vm.stopPrank();

        (, uint256 privateKey) = makeAddrAndKey("trader");

        LimitExercise.Order memory order = LimitExercise.Order(
            1,
            0.05 ether,
            block.timestamp + 20 minutes,
            address(token1),
            address(optionMarket),
            trader
        );

        LimitExercise.SignatureMeta memory sigMeta;

        bytes32 digest = limitExercise.computeDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        sigMeta.v = v;
        sigMeta.r = r;
        sigMeta.s = s;

        vm.startPrank(trader);
        optionMarket.updateExerciseDelegate(address(limitExercise), true);
        vm.stopPrank();

        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), bot);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 250e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        vm.startPrank(bot);
        limitExercise.cancelOrder(order, sigMeta);
    }

    function testFailExecuteCancelledLimitOrder() public {
        vm.startPrank(trader);

        uint256 l = LiquidityAmounts.getLiquidityForAmount0(
            tickLowerPuts.getSqrtRatioAtTick(),
            tickUpperPuts.getSqrtRatioAtTick(),
            10_000e18
        );

        uint256 _premiumAmountPuts = optionMarket.getPremiumAmount(
            true,
            block.timestamp + 20 minutes,
            optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts),
            optionMarket.getCurrentPricePerCallAsset(pool),
            optionMarket.ttlToVol(20 minutes),
            (10_000e18 * 1e18) /
                optionMarket.getPricePerCallAssetViaTick(pool, tickLowerPuts)
        );

        uint256 _fee = optionMarket.getFee(0, 0, _premiumAmountPuts);
        uint256 cost = _premiumAmountPuts + _fee;
        token0.mint(trader, cost);
        token0.approve(address(optionMarket), cost);

        DopexV2OptionMarket.OptionTicks[]
            memory opTicks = new DopexV2OptionMarket.OptionTicks[](1);

        opTicks[0] = DopexV2OptionMarket.OptionTicks({
            _handler: uniV3Handler,
            pool: pool,
            tickLower: tickLowerPuts,
            tickUpper: tickUpperPuts,
            liquidityToUse: l
        });

        optionMarket.mintOption(
            DopexV2OptionMarket.OptionParams({
                optionTicks: opTicks,
                tickLower: tickLowerPuts,
                tickUpper: tickUpperPuts,
                ttl: 20 minutes,
                isCall: false,
                maxCostAllowance: cost
            })
        );
        vm.stopPrank();

        (, uint256 privateKey) = makeAddrAndKey("trader");

        uint256 optionId = 1;

        uint256 minProfit = 0.05 ether;
        LimitExercise.Order memory order = LimitExercise.Order(
            1,
            minProfit,
            block.timestamp + 20 minutes,
            address(token1),
            address(optionMarket),
            trader
        );

        LimitExercise.SignatureMeta memory sigMeta;

        bytes32 digest = limitExercise.computeDigest(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        sigMeta.v = v;
        sigMeta.r = r;
        sigMeta.s = s;

        vm.startPrank(trader);
        limitExercise.cancelOrder(order, sigMeta);
        optionMarket.updateExerciseDelegate(address(limitExercise), true);
        vm.stopPrank();

        limitExercise.grantRole(limitExercise.KEEPER_ROLE(), bot);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 250e18,
                zeroForOne: false,
                requireMint: true
            })
        );

        vm.startPrank(bot);
        limitExercise.limitExercise(
            order,
            sigMeta,
            _getExerciseParams(optionId)
        );
        vm.stopPrank();
    }

    function _getExerciseParams(
        uint256 optionId
    ) private view returns (IOptionMarket.ExerciseOptionParams memory) {
        (, , , , uint256 liquidityToUse) = optionMarket.opTickMap(1, 0);
        uint256[] memory liquidityToExercise = new uint256[](1);
        liquidityToExercise[0] = liquidityToUse;
        bytes[] memory swapDatas = new bytes[](1);
        swapDatas[0] = abi.encode(pool.fee(), 0);
        ISwapper[] memory swappers = new ISwapper[](1);
        swappers[0] = srs;

        return
            IOptionMarket.ExerciseOptionParams({
                optionId: optionId,
                swapper: swappers,
                swapData: swapDatas,
                liquidityToExercise: liquidityToExercise
            });
    }
}
