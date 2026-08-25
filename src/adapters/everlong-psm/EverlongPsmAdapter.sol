// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IPermissionlessPSM.sol';
import './IPsmCapHook.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @notice Adapter for the Everlong PermissionlessPSM (`everlong-psm`): 1:1 swaps with
/// decimal scaling between a whitelisted stable and the protocol debt token.
///
///   - stable -> debt is `deposit` (PSM pulls the stable, mints debt to the recipient);
///   - debt -> stable is `redeem` (PSM burns the debt straight from this adapter — it
///     holds burn rights on the debt token — and pays the stable to the recipient).
///
/// The PSM reverts on its mint cap / per-stable accounting instead of truncating, so
/// the adapter clamps the input to the live bounds first and reports the remainder as
/// `amountUnused` — mirroring the kyberswap-dex-lib simulator's partial-fill quoting.
/// `MAX_FEE_BP` deliberately delegates price protection to the production route
/// executor's aggregate `minReturn`; direct calls have no meaningful adapter-level
/// minimum output.
///
/// `data` layout: word 0 = PSM address, word 1 = debt token address (verified against
/// `PSM.debtToken()`).
contract EverlongPsmAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error EverlongPsmAdapter_NothingToFill();
  error EverlongPsmAdapter_TokenMismatch();

  uint16 private constant MAX_FEE_BP = type(uint16).max; // route-level minReturn guards slippage

  /// @dev A route chooses the PSM and can therefore expose arbitrary values through its
  /// getters. Capacity products are bounds, so saturation is both fail-safe and avoids
  /// an arithmetic panic before the real venue call applies its own accounting.
  function _saturatingMul(uint256 a, uint256 b) private pure returns (uint256) {
    if (a == 0 || b == 0) return 0;
    return a > type(uint256).max / b ? type(uint256).max : a * b;
  }

  function executeEverlongPsm(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    IPermissionlessPSM psm = IPermissionlessPSM(data.decodeAddress(0));
    address debt = psm.debtToken();
    if (data.decodeAddress(1) != debt) revert EverlongPsmAdapter_TokenMismatch();

    // Exactly one leg must be the PSM's own debt token. The opposite leg is checked
    // against `stables` below, so calldata cannot select the redeem path and make the
    // PSM burn residual debt while claiming some unrelated token as the input.
    bool debtIn = tokenIn == debt && tokenOut != debt;
    bool debtOut = tokenOut == debt && tokenIn != debt;
    if (!debtIn && !debtOut) revert EverlongPsmAdapter_TokenMismatch();

    if (debtIn) {
      // debt -> stable: clamp to the book, to what the PSM can pay out, to the cap
      // hook's single-swap exit ceiling, and to the wadOffset floor (sub-offset dust
      // would burn for zero stable). `_bookBurn` reverts PassedOutflowCap past the hook,
      // so the ceiling has to bind here rather than be discovered on execution.
      uint256 wadOffset = psm.stables(tokenOut);
      // Zero means de-listed: the PSM reverts NotListedToken, so name it here instead
      // of tripping a division-by-zero panic below.
      if (wadOffset == 0) revert EverlongPsmAdapter_NothingToFill();
      uint256 maxIn = psm.debtTokenMinted(tokenOut);
      uint256 payableIn = _saturatingMul(psm.availableReserve(tokenOut), wadOffset);
      if (payableIn < maxIn) maxIn = payableIn;
      address hook = psm.capHook();
      if (hook != address(0)) {
        // Two independent exit ceilings, both reverting PassedOutflowCap: maxRedeem
        // bounds the BURN (debt units) and getMaxPsmOutflow bounds the stable LEAVING
        // (output + fee) for this caller.
        uint256 hookCeiling = IPsmCapHook(hook).maxRedeem(tokenOut);
        if (hookCeiling < maxIn) maxIn = hookCeiling;
        uint256 outflow = IPsmCapHook(hook).getMaxPsmOutflow(address(this), tokenOut, false);
        uint256 outflowIn = _saturatingMul(outflow, wadOffset);
        if (outflowIn < maxIn) maxIn = outflowIn;
      }
      uint256 used = amountIn < maxIn ? amountIn : maxIn;
      used -= used % wadOffset;
      if (used == 0) revert EverlongPsmAdapter_NothingToFill();

      amountOut = psm.redeem(tokenOut, used, recipient, MAX_FEE_BP);
      // A single-unit redeem on a scaled stable can burn for a fee-rounded zero.
      if (amountOut == 0) revert EverlongPsmAdapter_NothingToFill();
      amountUnused = amountIn - used;
    } else {
      // stable -> debt: gross (output + fee) must fit availableMint, which already folds
      // the cap hook's ceiling.
      uint256 wadOffset = psm.stables(tokenIn);
      if (wadOffset == 0) revert EverlongPsmAdapter_NothingToFill();
      uint256 maxIn = psm.availableMint(tokenIn) / wadOffset;
      uint256 used = amountIn < maxIn ? amountIn : maxIn;
      if (used == 0) revert EverlongPsmAdapter_NothingToFill();

      tokenIn.forceApprove(address(psm), used);
      amountOut = psm.deposit(tokenIn, used, recipient, MAX_FEE_BP);
      // Cleared unconditionally: the PSM pulls exactly `used`, but that is its own
      // accounting and the PSM address came from `data`.
      tokenIn.forceApprove(address(psm), 0);
      amountUnused = amountIn - used;
    }
  }
}
