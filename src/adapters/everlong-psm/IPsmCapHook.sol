// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice The PSM's capacity policy. Only the exit ceiling is read here — the mint side
/// is already folded into `availableMint`.
interface IPsmCapHook {
  /// @notice Ceiling on debt token burned against `stable` in ONE swap.
  function maxRedeem(address stable) external view returns (uint256);

  /// @notice Per-caller ceiling on the stable leaving, checked against output + fee.
  /// `isWithdraw` is false on the exact-input redeem path.
  function getMaxPsmOutflow(address user, address asset, bool isWithdraw)
    external
    view
    returns (uint256);
}
