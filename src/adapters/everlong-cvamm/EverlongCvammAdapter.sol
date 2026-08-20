// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './ICvammALM.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @notice Adapter for the Everlong CVAMM venue (`everlong-cvamm`): exact-input swaps
/// directly against the CvammALM. The venue treats `amountIn` as a maximum — dust below
/// the curve's normalized resolution and anything beyond the solvency clamp is left
/// unspent — so partial fills surface naturally through `amountUnused`.
contract EverlongCvammAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error EverlongCvammAdapter_TokenMismatch();

  function executeEverlongCvamm(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address alm = data.decodeAddress(0);

    // Bind BOTH legs to the venue's own getters. `data` is caller-supplied, so inferring
    // the direction from token0 alone would let a wrong-token route settle as the
    // opposite leg instead of failing.
    address token0 = ICvammALM(alm).token0();
    address token1 = ICvammALM(alm).token1();
    bool stableIn = tokenIn == token0 && tokenOut == token1;
    if (!stableIn && !(tokenIn == token1 && tokenOut == token0)) {
      revert EverlongCvammAdapter_TokenMismatch();
    }

    // The ALM pulls the input with transferFrom and takes only what the fill uses.
    tokenIn.forceApprove(alm, amountIn);

    uint256 amountInUsed;
    (amountInUsed, amountOut) =
      ICvammALM(alm).swap(stableIn, amountIn, 1, 0, recipient, block.timestamp);

    amountUnused = amountIn - amountInUsed;
    // Clear UNCONDITIONALLY. Partial fills are the normal case here and the ALM only
    // pulls what it used, so a full fill by the venue's own report is the only case that
    // consumes the allowance — and that report comes from an address `data` chose. A
    // target that claims full consumption without pulling would otherwise leave a
    // standing allowance against whatever this adapter holds next.
    tokenIn.forceApprove(alm, 0);
  }
}
