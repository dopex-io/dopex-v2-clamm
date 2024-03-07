// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IClPoolFactory} from "../src/ramses-v3/v3-core/contracts/interfaces/IClPoolFactory.sol";
import {IClPool} from "../src/ramses-v3/v3-core/contracts/interfaces/IClPool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {SwapRouter, ISwapRouter} from "v3-periphery/SwapRouter.sol";
import {SqrtPriceMath} from "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {SwapMath} from "@uniswap/v3-core/contracts/libraries/SwapMath.sol";

import {ClLiquidityManagement} from "./ramses-v3-utils/ClLiquidityManagement.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract ClTest is Test {
    ERC20Mock token0; // LUSD
    ERC20Mock token1; // ETH

    IClPoolFactory factory;
    IClPool pool;
    uint24 fee;

    ClLiquidityManagement ramsesV2LiquidityManagement;

    ISwapRouter swapRouter;

    address public user = address(0x6969);

    /**
     * price = 2000 LUSD
     *     invPrice = 1 / 2000
     *     sqrtPriceX96 = sqrt(invPrice) * 2**96
     */
    // uint160 initSqrtPriceX96 = 1771595571142957112070504448; // 1 ETH = 2000 LUSD
    uint160 initSqrtPriceX96 = 1771845812700903892492222464; // 1 ETH = 2000 LUSD

    function setUp() public {
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();
        if (address(token0) >= address(token1)) {
            (token0, token1) = (token1, token0);
        }
        factory = IClPoolFactory(0xAAA32926fcE6bE95ea2c51cB4Fcb60836D320C42);
        fee = 500;
        pool = IClPool(factory.createPool(address(token0), address(token1), fee, 0));

        pool.initialize(initSqrtPriceX96);

        ramsesV2LiquidityManagement = new ClLiquidityManagement(address(factory));

        swapRouter = ISwapRouter(0xAAAE99091Fbb28D400029052821653C1C752483B);
    }

    function testPoolDeployment() public view {
        (uint160 sqrtPriceX96, int24 tick,,,,, bool unlocked) = pool.slot0();

        assert(sqrtPriceX96 == initSqrtPriceX96);
        assert(tick == TickMath.getTickAtSqrtRatio(initSqrtPriceX96));
        assert(unlocked == true);
    }

    function testAddingLiquidity() public {
        int24 tickLower = (-78245 / int24(10)) * 10 + 10;
        int24 tickUpper = (-73136 / int24(10)) * 10;

        uint160 lower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 upper = TickMath.getSqrtRatioAtTick(tickUpper);

        uint256 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(lower, upper, 500000e18);

        uint256 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(lower, upper, 250e18);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            initSqrtPriceX96, lower, upper, uint128(liquidity0 < liquidity1 ? liquidity0 : liquidity1)
        );

        vm.startPrank(user);

        token0.mint(user, 500000e18);
        token1.mint(user, 250e18);

        token0.approve(address(ramsesV2LiquidityManagement), type(uint256).max);
        token1.approve(address(ramsesV2LiquidityManagement), type(uint256).max);

        (uint128 liquidity,,,) = ramsesV2LiquidityManagement.addLiquidity(
            ClLiquidityManagement.AddLiquidityParams({
                token0: pool.token0(),
                token1: pool.token1(),
                fee: fee,
                recipient: user,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        (uint128 selfLiquidity,,,,) =
            pool.positions(keccak256(abi.encodePacked(user, uint256(0), tickLower, tickUpper)));

        assert(selfLiquidity == liquidity);
        vm.stopPrank();
    }

    function testRemoveLiquidity() public {
        testAddingLiquidity();

        int24 tickLower = (-78245 / int24(10)) * 10 + 10;
        int24 tickUpper = (-73136 / int24(10)) * 10;

        (uint128 selfLiquidity,,,,) = pool.positions(keccak256(abi.encodePacked(user, tickLower, tickUpper)));

        vm.startPrank(user);

        (uint256 expectedAmount0, uint256 expectedAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            initSqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            selfLiquidity
        );

        (uint256 amount0, uint256 amount1) = pool.burn(tickLower, tickUpper, selfLiquidity);

        pool.collect(user, tickLower, tickUpper, uint128(amount0), uint128(amount1));

        vm.stopPrank();
        (uint128 selfLiquidityAfter,,,,) = pool.positions(keccak256(abi.encodePacked(user, tickLower, tickUpper)));

        assert(selfLiquidityAfter == 0);
        assert(expectedAmount0 == amount0);
        assert(expectedAmount1 == amount1);
    }

    function testSwapping() public {
        testAddingLiquidity();

        uint256 amountIn = 10000e18;

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        uint128 liquidity = pool.liquidity();

        uint160 sqrtPriceX96Next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, true);

        int24 newTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96Next);

        (uint160 sqrtRatioNextX96A,, uint256 amountOut,) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceX96Next, liquidity, int256(amountIn), fee);

        vm.startPrank(user);
        token1.transfer(address(0xdead), token1.balanceOf(user));

        token0.mint(user, amountIn);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: pool.token0(),
                tokenOut: pool.token1(),
                fee: fee,
                recipient: user,
                deadline: block.timestamp + 5 days,
                amountIn: amountIn,
                amountOutMinimum: amountOut,
                sqrtPriceLimitX96: 0
            })
        );

        (uint160 sqrtPriceX96Latest, int24 tickLatest,,,,,) = pool.slot0();

        assert(sqrtPriceX96Latest == sqrtRatioNextX96A);
        assert(newTick == tickLatest);
        assert(token1.balanceOf(user) == amountOut);

        vm.stopPrank();
    }

    function testReachAParticularPrice() public {
        testAddingLiquidity();

        // assume uniform liquidity at each tick
        uint160 targetSqrtPriceX96 = 1585832424097319824641753088; // 1 ETH = 2200 LUSD
        console.log("Target: ", targetSqrtPriceX96);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();
        console.log("Current: ", sqrtPriceX96);

        // for (int24 i = 73136; i <= 78245; i++) {
        //     (
        //         uint128 liquidityGross,
        //         int128 liquidityNet,
        //         ,
        //         ,
        //         ,
        //         ,
        //         ,
        //         bool initialized
        //     ) = pool.ticks(-(i));
        //     if (initialized == true) {
        //         console.log(liquidityGross);
        //         console.logInt(liquidityNet);
        //         console.log(TickMath.getSqrtRatioAtTick(-(i)));
        //         console.logInt(-(i));
        //     }
        // }
        // uint256 amountIn = 0;
        // int24 tickLower = (tick / int24(10)) * 10 + 10;
        uint128 liquidity = pool.liquidity();

        uint256 amountIn = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, targetSqrtPriceX96, liquidity, true);

        uint160 sqrtPriceX96Next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, true);

        int24 newTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96Next);

        (uint160 sqrtRatioNextX96A,, uint256 amountOut,) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceX96Next, liquidity, int256(amountIn), fee);

        vm.startPrank(user);
        token1.transfer(address(0xdead), token1.balanceOf(user));

        token0.mint(user, amountIn);
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: pool.token0(),
                tokenOut: pool.token1(),
                fee: fee,
                recipient: user,
                deadline: block.timestamp + 5 days,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        (uint160 sqrtPriceX96Latest, int24 tickLatest,,,,,) = pool.slot0();

        console.log(sqrtPriceX96Latest);
        // assert(sqrtPriceX96Latest == sqrtRatioNextX96A);
        // assert(newTick == tickLatest);
        // assert(token1.balanceOf(user) == amountOut);
        (uint128 liquidityGross, int128 liquidityNet,,,,,, bool initialized) = pool.ticks(-78230);
        vm.stopPrank();
    }
}
