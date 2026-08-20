// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Minimal surface of the Everlong PermissionlessPSM: 1:1 swaps (with decimal
/// scaling and bp fees) between whitelisted stablecoins and the protocol debt token.
/// Deposits pull the stable with transferFrom; redeems burn the debt token straight
/// from the caller (the PSM holds burn rights), needing no approval.
interface IPermissionlessPSM {
  function deposit(address stable, uint256 stableAmount, address receiver, uint16 maxFeePercentage)
    external
    returns (uint256 mintedDebtToken);

  function redeem(
    address stable,
    uint256 debtTokenAmount,
    address receiver,
    uint16 maxFeePercentage
  ) external returns (uint256 stableAmount);

  function debtToken() external view returns (address);
  function stables(address stable) external view returns (uint64 wadOffset);

  /// @notice Debt still mintable against `stable`, after BOTH the structural mintCap and
  /// the cap hook. `mintCap` alone sits above the real ceiling whenever a hook binds.
  function availableMint(address stable) external view returns (uint256);

  /// @notice Stable the PSM could pay out right now: idle balance plus recallable float.
  /// The exit path re-reads this and reverts rather than trusting the yield hook.
  function availableReserve(address stable) external view returns (uint256);

  /// @notice Optional capacity policy. Zero when unset; `availableMint` already folds its
  /// mint ceiling, but the exit ceiling has to be read directly.
  function capHook() external view returns (address);

  function debtTokenMinted(address stable) external view returns (uint256);
}
