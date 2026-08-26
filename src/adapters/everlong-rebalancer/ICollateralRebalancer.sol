// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice The CollateralRebalancer's live exchange state and the deployed CR-math
/// library the venue prices with. `deleverageQuote` is pure, so the adapter can evaluate
/// the exact gross->shares map the swap itself will use.
interface ICollateralRebalancer {
  struct ExchangeState {
    uint256 collVaultShares;
    uint256 debt;
    uint256 reservationValueWad;
    uint256 spreadPpm;
  }

  function exchangeState() external view returns (ExchangeState memory state);
}

interface ICollRebalancerMath {
  /// @notice Shares released for `stableIn` of debt retired, at the given state.
  function deleverageQuote(
    uint256 collVaultShares,
    uint256 debt,
    uint256 reservationValueWad,
    uint256 leverageRatioWad,
    uint256 spreadPpm,
    uint256 stableIn
  ) external view returns (uint256 collateralOut, uint256 newColl, uint256 newDebt);
}
