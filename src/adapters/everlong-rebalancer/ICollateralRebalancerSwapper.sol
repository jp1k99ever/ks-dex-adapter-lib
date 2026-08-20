// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Minimal surface of the Everlong CollateralRebalancerSwapper: permissionless
/// physical settlement for the CollateralRebalancer's share-priced exchange. Both
/// directions pull their input cap up front and refund the unused part to the caller
/// within the same call.
interface ICollateralRebalancerSwapper {
  struct StableForVolatileResult {
    uint256 netStableIn;
    uint256 stableRefund;
    uint256 volatileOut;
    uint256 collVaultSharesRedeemed;
    uint256 almSharesRedeemed;
    uint256 physicalStableOut;
    uint256 flashStable;
  }

  struct VolatileForStableResult {
    uint256 volatileIn;
    uint256 volatileRefund;
    uint256 netStableOut;
    uint256 grossStableOut;
    uint256 collVaultSharesMinted;
    uint256 almSharesUsed;
    uint256 physicalStableIn;
    uint256 flashStable;
  }

  /// @notice Repay position debt and receive the released ALM volatile reserve leg.
  /// @param stableDebtIn Stable debt retired by the core exchange (GROSS).
  /// @param maxNetStableIn Maximum stable the caller spends after recycling the released
  ///        stable leg; pulled up front, the excess refunds within the same call.
  /// @param minVolatileOut Minimum physical volatile tokens sent to `receiver`.
  /// @param receiver Recipient of the physical volatile tokens.
  function swapStableForVolatile(
    uint256 stableDebtIn,
    uint256 maxNetStableIn,
    uint256 minVolatileOut,
    address receiver
  ) external returns (StableForVolatileResult memory result);

  /// @notice Supply the physical ALM reserve legs and receive stable borrowed by the
  ///         core exchange.
  /// @param collVaultSharesIn Exact CollVault shares posted to the managed position.
  /// @param maxStableIn Maximum temporary stable financing flash-minted by the swapper.
  /// @param maxVolatileIn Maximum physical volatile pulled from the caller (pulled in
  ///        full up front; the unused part refunds within the same call).
  /// @param minNetStableOut Minimum stable output after repaying the flash financing.
  /// @param receiver Recipient of the net stable output.
  function swapVolatileForStable(
    uint256 collVaultSharesIn,
    uint256 maxStableIn,
    uint256 maxVolatileIn,
    uint256 minNetStableOut,
    address receiver
  ) external returns (VolatileForStableResult memory result);

  /// @notice The CollateralRebalancer this swapper settles against.
  function core() external view returns (address);

  /// @notice The CDP debt token (the stable leg) this swapper flash-mints and settles in.
  function debtToken() external view returns (address);

  /// @notice The volatile leg this swapper pulls and pays out.
  function volatile() external view returns (address);

  /// @notice Pro-rata reserve legs represented by CollVault shares at current state.
  /// @param collVaultShares CollVault shares to mint or redeem.
  /// @param mint True for the mint preview (rounds up), false for redeem (rounds down).
  function previewTokenAmounts(uint256 collVaultShares, bool mint)
    external
    view
    returns (uint256 stableAmount, uint256 volatileAmount);
}
