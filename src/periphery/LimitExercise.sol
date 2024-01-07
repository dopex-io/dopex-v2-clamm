// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import {Multicall} from "openzeppelin-contracts/contracts/utils/Multicall.sol";

// Libraries
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// Interfaces
import {IOptionMarket} from "../interfaces/IOptionMarket.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract LimitExercise is AccessControl, EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    struct Order {
        uint256 optionId;
        uint256 minProfit;
        uint256 deadline;
        address profitToken;
        address optionMarket;
        address signer;
    }

    struct SignatureMeta {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    error LimitExercise_InvalidSignature();

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(uint256 optionId,uint256 minProfit,uint256 deadline,address profitToken,address optionMarket,address signer)"
        );

    constructor() EIP712("DopexV2_Clamm_Limit_Exercise_Order", "1") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(KEEPER_ROLE, msg.sender);
    }

    function limitExercise(
        Order calldata _order,
        SignatureMeta calldata _signatureMeta,
        IOptionMarket.ExerciseOptionParams calldata _exerciseParams
    ) external onlyRole(KEEPER_ROLE) returns (uint256 executorProfit) {
        IOptionMarket optionMarket = IOptionMarket(_order.optionMarket);

        // Should verify signature in general and should also revert incase the limit order was placed by a signer different than the owner.
        if (
            !verify(
                optionMarket.ownerOf(_exerciseParams.optionId),
                _order,
                _signatureMeta
            )
        ) {
            revert LimitExercise_InvalidSignature();
        }

        optionMarket.exerciseOption(_exerciseParams);

        uint256 tokenBalance = IERC20(_order.profitToken).balanceOf(
            address(this)
        );

        if (tokenBalance >= 0) {
            executorProfit = tokenBalance > _order.minProfit
                ? tokenBalance - _order.minProfit
                : 0;

            uint256 userProfit = executorProfit > 0
                ? _order.minProfit
                : tokenBalance;

            // transfer complete profit if its above min profit or transfer min profit and extra to provided address
            if (executorProfit > 0) {
                IERC20(_order.profitToken).safeTransfer(
                    msg.sender,
                    executorProfit
                );
            }

            if (userProfit > 0) {
                IERC20(_order.profitToken).safeTransfer(
                    optionMarket.ownerOf(_exerciseParams.optionId),
                    userProfit
                );
            }
        }
    }

    function verify(
        address _signer,
        Order calldata _order,
        SignatureMeta calldata _signatureMeta
    ) public view returns (bool) {
        bytes32 digest = computeDigest(_order);

        return
            _signer ==
            digest.recover(
                _signatureMeta.v,
                _signatureMeta.r,
                _signatureMeta.s
            );
    }

    function getStructHash(
        Order calldata _order
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    _order.optionId,
                    _order.minProfit,
                    _order.deadline,
                    _order.profitToken,
                    _order.optionMarket,
                    _order.signer
                )
            );
    }

    function computeDigest(
        Order calldata _order
    ) public view returns (bytes32) {
        return _hashTypedDataV4(getStructHash(_order));
    }
}
