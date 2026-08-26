// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Minimal surface of the Everlong CvammALM: a single-LP AMM on a closed-form
/// curve. The venue itself is the sole book, swap entrypoint and approval target — it
/// pulls the input with transferFrom and settles both legs in plain ERC-20.
interface ICvammALM {
  /// @param stableIn True to sell the stable leg (token0).
  /// @param amountIn MAXIMUM input. Only `amountInUsed` is taken from the caller.
  /// @param minAmountOut Slippage floor on the output actually delivered.
  /// @param sqrtPriceLimitX96 Pool-frame bound, or 0 for none. Honoured by CLAMPING the
  ///        fill, not by reverting.
  /// @param to Output recipient.
  /// @param deadline Latest timestamp at which this may execute.
  function swap(
    bool stableIn,
    uint256 amountIn,
    uint256 minAmountOut,
    uint160 sqrtPriceLimitX96,
    address to,
    uint256 deadline
  ) external returns (uint256 amountInUsed, uint256 amountOut);

  function token0() external view returns (address);
  function token1() external view returns (address);
}
