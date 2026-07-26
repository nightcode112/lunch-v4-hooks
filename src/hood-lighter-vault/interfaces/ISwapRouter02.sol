// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal interface for Uniswap's SwapRouter02 as deployed on Robinhood Chain
/// (`0xCaf681a6…`, per the app's lib/chain.js — verified there to share factory()==v3Factory and
/// WETH9()==weth). NOTE: SwapRouter02 has NO per-call `deadline` field on exactInputSingle (that was
/// removed vs the original SwapRouter) — do not add one. `exactInputSingle` is `payable`: sending
/// native ETH as `msg.value` with `tokenIn == WETH` makes the router auto-wrap it, which is exactly
/// how the ETH→USDG deposit path works (confirmed by the app's own pairTrade.js live routing).
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice The WETH bits we need: withdraw() to unwrap to native ETH on the redeem-to-ETH path, and
/// deposit() to re-wrap on the send-failure fallback (credit claimable WETH instead of bricking).
interface IWETH {
    function withdraw(uint256 amount) external;
    function deposit() external payable;
}
