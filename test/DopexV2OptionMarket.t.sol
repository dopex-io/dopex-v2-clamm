// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {UniswapV3TestLib} from "./uniswap-v3-utils/UniswapV3TestLib.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";

import {DopexV2PositionManager} from "../src/DopexV2PositionManager.sol";
import {PositionManagerHandler} from "./handlers/PositionManager.handler.sol";
import {UniswapV3SingleTickLiquidityHandler} from "../src/handlers/UniswapV3SingleTickLiquidityHandler.sol";
import {DopexV2OptionMarket} from "../src/DopexV2OptionMarket.sol";

import {OptionPricing} from "./pricing/OptionPricing.sol";
import {DopexV2ClammFeeStrategy} from "../src/pricing/fees/DopexV2ClammFeeStrategy.sol";
import {SwapRouterSwapper} from "../src/swapper/SwapRouterSwapper.sol";
import {AutoExerciseTimeBased} from "../src/periphery/AutoExerciseTimeBased.sol";

import {IOptionPricing} from "../src/pricing/IOptionPricing.sol";
import {IHandler} from "../src/interfaces/IHandler.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {IOptionMarket} from "../src/interfaces/IOptionMarket.sol";

import {OptionPricingLinear} from "../src/pricing/OptionPricingLinear.sol";

contract optionMarketTest is Test {
    using TickMath for int24;

    address ETH; // token1
    address LUSD; // token0

    ERC20Mock token0;
    ERC20Mock token1;

    UniswapV3TestLib uniswapV3TestLib;
    IUniswapV3Pool pool;

    OptionPricing op;
    OptionPricingLinear opl;
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
    address feeToAutoExercise = makeAddr("feeToAutoExercise"); // auto exercise fee to
    address autoExercisoor = makeAddr("autoExercisoor"); // auto exciseroor role

    DopexV2PositionManager positionManager;
    PositionManagerHandler positionManagerHandler;
    DopexV2OptionMarket optionMarket;
    UniswapV3SingleTickLiquidityHandler uniV3Handler;
    DopexV2ClammFeeStrategy feeStrategy;
    AutoExerciseTimeBased autoExercise;

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
        opl = new OptionPricingLinear(1e4, 1e3, 1e8);
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

        autoExercise = new AutoExerciseTimeBased();

        autoExercise.updateFeeTo(feeToAutoExercise);

        autoExercise.grantRole(keccak256("EXECUTOR"), autoExercisoor);

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

    function testOptionPricingLinear() public {
        uint256 vol = opl.getVolatility(2000e18, 2300e18, 45);
        assertEq(vol, 103);
        vol = opl.getVolatility(2300e18, 2000e18, 45);
        assertEq(vol, 112);
        vol = opl.getVolatility(2000e18, 2000e18, 45);
        assertEq(vol, 45);

        // modify volatility multiplier
        opl.updateVolatilityMultiplier(2e3);
        vol = opl.getVolatility(2000e18, 2300e18, 45);
        assertEq(vol, 162);

        // modify volatility offset
        opl.updateVolatilityOffset(2e4);
        vol = opl.getVolatility(2300e18, 2000e18, 45);
        assertEq(vol, 225);

        // check the option price calculation

        uint256 oplPrice = opl.getOptionPrice(
            false,
            block.timestamp + 3600 minutes,
            2000e18,
            2300e18,
            45
        );

        uint256 opPrice = op.getOptionPrice(
            false,
            block.timestamp + 3600 minutes,
            2000e18,
            2300e18,
            45
        );

        assertGt(oplPrice, opPrice);
    }

    function testBuyCallOption() public {
        vm.startPrank(trader);
        uint256 l = LiquidityAmounts.getLiquidityForAmount1(
            tickLowerCalls.getSqrtRatioAtTick(),
            tickUpperCalls.getSqrtRatioAtTick(),
            5e18
        );

        uint256 _premiumAmountCalls = optionMarket.getPremiumAmount(
            false,
            block.timestamp + 20 minutes,
            optionMarket.getPricePerCallAssetViaTick(pool, tickUpperCalls),
            optionMarket.getCurrentPricePerCallAsset(pool),
            optionMarket.ttlToVol(20 minutes),
            5e18
        );

        uint256 _fee = optionMarket.getFee(0, 0, _premiumAmountCalls);
        uint256 cost = _premiumAmountCalls + _fee;
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

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        vm.stopPrank();
    }

    function testBuyPutOption() public {
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

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        vm.stopPrank();
    }

    function testExerciseCallOption() public {
        testBuyCallOption();

        uint256 optionId = 1;

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 400000e18, // pushes to 2078
                zeroForOne: true,
                requireMint: true
            })
        );
        vm.startPrank(trader);

        (uint256 len, , , , ) = optionMarket.opData(optionId);

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        uint256[] memory liquidityToExercise = new uint256[](len);

        liquidityToExercise[0] = liquidityToUse;

        bytes[] memory swapDatas = new bytes[](len);
        swapDatas[0] = abi.encode(pool.fee(), 0);

        ISwapper[] memory swappers = new ISwapper[](len);
        swappers[0] = srs;

        optionMarket.exerciseOption(
            DopexV2OptionMarket.ExerciseOptionParams({
                optionId: optionId,
                swapper: swappers,
                swapData: swapDatas,
                liquidityToExercise: liquidityToExercise
            })
        );

        console.log("Profit", token0.balanceOf(trader));

        vm.stopPrank();
    }

    function testExercisePutOption() public {
        testBuyPutOption();

        uint256 optionId = 1;

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 250e18,
                zeroForOne: false,
                requireMint: true
            })
        );
        vm.startPrank(trader);
        (uint256 len, , , , ) = optionMarket.opData(optionId);

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        uint256[] memory liquidityToExercise = new uint256[](len);

        liquidityToExercise[0] = liquidityToUse;

        bytes[] memory swapDatas = new bytes[](len);
        swapDatas[0] = abi.encode(pool.fee(), 0);

        ISwapper[] memory swappers = new ISwapper[](len);
        swappers[0] = srs;

        optionMarket.exerciseOption(
            DopexV2OptionMarket.ExerciseOptionParams({
                optionId: optionId,
                swapper: swappers,
                swapData: swapDatas,
                liquidityToExercise: liquidityToExercise
            })
        );

        console.log("Profit", token1.balanceOf(trader));

        vm.stopPrank();
    }

    function testSettleOptionCallOTM() public {
        testBuyCallOption();
        uint256 prevTime = block.timestamp + 20 minutes;
        vm.warp(block.timestamp + 1201 seconds);
        uint256 optionId = 1;
        (uint256 len, , , , ) = optionMarket.opData(optionId);

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        uint256[] memory liquidityToSettle = new uint256[](len);

        liquidityToSettle[0] = liquidityToUse;

        bytes[] memory swapDatas = new bytes[](len);
        swapDatas[0] = abi.encode(pool.fee(), 0);

        ISwapper[] memory swappers = new ISwapper[](len);
        swappers[0] = srs;

        optionMarket.settleOption(
            DopexV2OptionMarket.SettleOptionParams({
                optionId: optionId,
                swapper: swappers,
                swapData: swapDatas,
                liquidityToSettle: liquidityToSettle
            })
        );
    }

    function testSettleOptionPutOTM() public {
        testBuyPutOption();
        uint256 prevTime = block.timestamp + 20 minutes;

        vm.warp(block.timestamp + 1201 seconds);

        uint256 optionId = 1;
        (uint256 len, , , , ) = optionMarket.opData(optionId);

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        uint256[] memory liquidityToSettle = new uint256[](len);

        liquidityToSettle[0] = liquidityToUse;

        bytes[] memory swapDatas = new bytes[](len);
        swapDatas[0] = abi.encode(pool.fee(), 0);

        ISwapper[] memory swappers = new ISwapper[](len);
        swappers[0] = srs;

        optionMarket.settleOption(
            DopexV2OptionMarket.SettleOptionParams({
                optionId: optionId,
                swapper: swappers,
                swapData: swapDatas,
                liquidityToSettle: liquidityToSettle
            })
        );
    }

    function testSettleOptionCallITM() public {
        testBuyCallOption();
        uint256 prevTime = block.timestamp + 20 minutes;
        vm.warp(block.timestamp + 1201 seconds);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 400000e18, // pushes to 2078
                zeroForOne: true,
                requireMint: true
            })
        );

        uint256 optionId = 1;
        (uint256 len, , , , ) = optionMarket.opData(optionId);

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        uint256[] memory liquidityToSettle = new uint256[](len);

        liquidityToSettle[0] = liquidityToUse;

        bytes[] memory swapDatas = new bytes[](len);
        swapDatas[0] = abi.encode(pool.fee(), 0);

        ISwapper[] memory swappers = new ISwapper[](len);
        swappers[0] = srs;

        optionMarket.settleOption(
            DopexV2OptionMarket.SettleOptionParams({
                optionId: optionId,
                swapper: swappers,
                swapData: swapDatas,
                liquidityToSettle: liquidityToSettle
            })
        );

        console.log(
            "Balance after settlement",
            token0.balanceOf(address(this))
        );
    }

    function testSettleOptionPutITM() public {
        testBuyPutOption();
        uint256 prevTime = block.timestamp + 20 minutes;

        vm.warp(block.timestamp + 1201 seconds);

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 250e18, // pushes to 1921
                zeroForOne: false,
                requireMint: true
            })
        );
        uint256 optionId = 1;
        (uint256 len, , , , ) = optionMarket.opData(optionId);

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        uint256[] memory liquidityToSettle = new uint256[](len);

        liquidityToSettle[0] = liquidityToUse;

        bytes[] memory swapDatas = new bytes[](len);
        swapDatas[0] = abi.encode(pool.fee(), 0);

        ISwapper[] memory swappers = new ISwapper[](len);
        swappers[0] = srs;

        optionMarket.settleOption(
            DopexV2OptionMarket.SettleOptionParams({
                optionId: optionId,
                swapper: swappers,
                swapData: swapDatas,
                liquidityToSettle: liquidityToSettle
            })
        );

        console.log(
            "Balance after settlement",
            token1.balanceOf(address(this))
        );
    }

    function testSplitPosition() public {
        testBuyCallOption();

        uint256 optionId = 1;
        (uint256 len, , , , ) = optionMarket.opData(optionId);

        (
            IHandler _handler,
            IUniswapV3Pool _pool,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityToUse
        ) = optionMarket.opTickMap(1, 0);

        uint256[] memory l = new uint256[](len);

        l[0] = liquidityToUse / 4;

        vm.prank(optionMarket.ownerOf(1));
        optionMarket.positionSplitter(
            DopexV2OptionMarket.PositionSplitterParams({
                optionId: optionId,
                to: garbage,
                liquidityToSplit: l
            })
        );

        (
            IHandler p_handler,
            IUniswapV3Pool p_pool,
            int24 ptickLower,
            int24 ptickUpper,
            uint256 pliquidityToUse
        ) = optionMarket.opTickMap(1, 0);
        console.log("Previous liquidity", pliquidityToUse);

        (
            IHandler n_handler,
            IUniswapV3Pool n_pool,
            int24 ntickLower,
            int24 ntickUpper,
            uint256 nliquidityToUse
        ) = optionMarket.opTickMap(2, 0);
        console.log("New liquidity", nliquidityToUse);
    }

    function testAutoExercise() public {
        testBuyCallOption();

        uint256 optionId = 1;

        uniswapV3TestLib.performSwap(
            UniswapV3TestLib.SwapParamsStruct({
                user: garbage,
                pool: pool,
                amountIn: 400000e18, // pushes to 2078
                zeroForOne: true,
                requireMint: true
            })
        );
        vm.startPrank(trader);
        vm.warp(block.timestamp + 901);

        optionMarket.updateExerciseDelegate(address(autoExercise), true);

        vm.stopPrank();

        vm.startPrank(autoExercisoor);

        (uint256 len, , , , ) = optionMarket.opData(optionId);

        (, , , , uint256 liquidityToUse) = optionMarket.opTickMap(1, 0);

        uint256[] memory liquidityToExercise = new uint256[](len);

        liquidityToExercise[0] = liquidityToUse;

        bytes[] memory swapDatas = new bytes[](len);
        swapDatas[0] = abi.encode(pool.fee(), 0);

        ISwapper[] memory swappers = new ISwapper[](len);
        swappers[0] = srs;

        autoExercise.autoExercise(
            IOptionMarket(address(optionMarket)),
            optionId,
            1e4, // 1%
            IOptionMarket.ExerciseOptionParams({
                optionId: optionId,
                swapper: swappers,
                swapData: swapDatas,
                liquidityToExercise: liquidityToExercise
            })
        );

        console.log("Profit", token0.balanceOf(trader));
        console.log(
            "AutoExerciser Profit",
            token0.balanceOf(feeToAutoExercise)
        );

        vm.stopPrank();
    }
}
