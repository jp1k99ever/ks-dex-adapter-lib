// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './ICollateralRebalancer.sol';
import './ICollateralRebalancerSwapper.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @notice Adapter for the Everlong CollateralRebalancer settlement venue (`everlong-rebalancer`),
/// built on the CollateralRebalancerSwapper — a two-token venue between the CDP stable
/// (e.g. NECT) and the volatile leg (e.g. WBTC) priced by the CollateralRebalancer's CR
/// bonding curve rather than an AMM invariant.
///
///   - volatile -> stable is LEVERAGE (swapVolatileForStable): the volatile leg mints
///     CollVault shares, the position draws debt, the caller receives net stable.
///   - stable -> volatile is DELEVERAGE (swapStableForVolatile): the caller fronts net
///     stable to repay debt, shares burn and the freed volatile leg pays out.
///
/// The swapper's arguments are share/gross-debt denominated while the adapter receives a
/// runtime token `amountIn`, so each direction re-derives its argument on-chain:
///
///   - leverage posts the quote-time share hint as soon as its volatile leg still fits
///     (one preview call), since the quote already sized the lot to the rebalancer's
///     physical-CR floor, which only increaseLeverage itself evaluates — a larger count
///     would size the call into a revert rather than a refund. A hint that no longer fits
///     bisects the swapper's own monotone `previewTokenAmounts` strictly inside
///     [0, hint]; only a hint-free call brackets upward from 1;
///   - deleverage uses the quote-time GROSS debt hint when the runtime amount covers the
///     quoted net, and otherwise re-derives it against the venue's own deleverageQuote.
///     Both directions pull their cap up front and refund the unused part within the same
///     call, which maps directly onto `amountUnused`.
///
/// Either way the quote is the cap: beyond it the venue's acceptance predicate (physical
/// CR, ICR, the CDP's minimum net debt) can refuse a lot the raw math still prices, and
/// only the quoting simulator evaluates that. A router funds the quoted lot and carries
/// the rest as RemainingTokenAmountIn.
///
/// Deleverage is sized to leave ONE WEI of the budget unspent. The swapper previews the
/// released legs off the ALM's combined totals, but the ALM's withdraw floors the
/// accounted and idle parts separately, so the stable it physically releases can land a
/// wei under the preview — and the swapper's flash repayment, sized off the preview,
/// then reverts Slippage on an exactly-funded call. The wei of headroom absorbs it.
///
/// `data` layout (all hints optional — zero falls back to on-chain derivation):
///   word 0: swapper address
///   word 1: stable token address (the CDP debt token)
///   word 2: leverage: quoted CollVault shares (posted as-is when they still fit, and
///           the ceiling of the search when they do not);
///           deleverage: quoted gross stableDebtIn
///   word 3: deleverage: quoted net stable in (the budget reference); leverage: unused
///   word 4: deleverage: CollRebalancerMath address (exact re-derivation); leverage: unused
///   word 5: deleverage: the leverage ratio that math validates against (zero = the
///           library constant); leverage: unused
contract EverlongRebalancerAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error EverlongRebalancerAdapter_NothingToFill();
  error EverlongRebalancerAdapter_TokenMismatch();

  /// @dev Shares live at the CollVault's own scale; the venue's book is far below this.
  uint256 private constant MAX_SHARES = type(uint128).max;

  /// @dev CollRebalancerMath.LEVERAGE_RATIO_WAD, the ratio the deployed math validates
  /// against (floor(4e18 / 9)). Data word 5 may override it; zero falls back here, so a
  /// quote that omits it cannot silently disable the exact re-derivation.
  uint256 private constant DEFAULT_LEVERAGE_RATIO_WAD = 444_444_444_444_444_444;

  /// @dev Cap on exact net evaluations when re-deriving the deleverage gross. A seeded
  /// step converges in one or two; the hint-free path starts at `budget` — low by the
  /// whole recycled leg — and small lots need the most, since each ratio step moves them
  /// proportionally less.
  uint256 private constant NET_STEPS = 10;

  /// @dev Cap on the halvings that walk a candidate back into the venue's quotable range
  /// (past the position's debt, the curve wall or the CDP's minimum net debt the math
  /// answers zero). Each is a single pure staticcall; 64 covers any budget that fits a
  /// token balance.
  uint256 private constant MAX_SHRINKS = 64;

  /// @dev Stop once the budget left unspent is within this fraction of it (0.01 bps).
  /// Measuring the SHORTFALL rather than the step size is what makes the exit an accuracy
  /// guarantee instead of a guess: a step can move very little and still be far from the
  /// boundary, which left small lots several bps short.
  uint256 private constant NET_ACCURACY = 1e6;

  /// @dev Largest gross debt whose NET stable spend stays strictly under `budget`. The
  /// seed is `budget` (or the rescaled hint); it is feasible whenever the venue quotes it
  /// (net < gross), but a budget past what the position can retire quotes nothing, so an
  /// unquotable candidate is halved until one answers and the loop only ever improves on
  /// a candidate it has actually seen — the call is never sized into a revert, nor does
  /// it return an untested gross. Each step evaluates the venue's own deleverageQuote
  /// composed with previewTokenAmounts, then takes the exact ratio step; `net` is
  /// monotone in `gross`, the same property the leverage bisection relies on.
  function _grossForNet(
    ICollateralRebalancerSwapper swapper,
    uint256 budget,
    uint256 grossHint,
    uint256 netHint,
    ICollRebalancerMath math,
    uint256 leverageRatioWad
  ) private view returns (uint256) {
    ICollateralRebalancer.ExchangeState memory st =
      ICollateralRebalancer(swapper.core()).exchangeState();

    if (budget < 2) return 0; // nothing fits once the wei of headroom is kept
    uint256 target = budget - 1;
    uint256 best;
    // No gross can exceed the position's debt, so the seed is capped there: it bounds the
    // walk-back for a budget past the book and keeps an absurd hint from overflowing.
    uint256 cand;
    if (netHint == 0 || grossHint == 0 || grossHint >= st.debt) {
      cand = budget;
    } else {
      cand = grossHint * target / netHint;
    }
    if (cand > st.debt) cand = st.debt;

    uint256 steps;
    uint256 shrinks;
    while (steps < NET_STEPS && cand != 0) {
      uint256 net = _netFor(swapper, st, cand, math, leverageRatioWad);
      if (net == 0) {
        // unquotable at this size: walk back toward the last feasible point; these
        // draw on MAX_SHRINKS, not on the ratio steps
        if (++shrinks > MAX_SHRINKS) break;
        cand = best == 0 ? cand >> 1 : (cand + best) >> 1;
        continue;
      }
      steps++;
      if (net <= target) {
        if (cand > best) best = cand;
        if (target - net <= budget / NET_ACCURACY) break; // within the accuracy target
      }
      uint256 next = cand * target / net;
      if (next == cand) break;
      cand = next;
    }
    return best;
  }

  /// @dev Net stable the caller spends for `gross` debt retired: the gross minus the
  /// stable leg the released shares recycle.
  function _netFor(
    ICollateralRebalancerSwapper swapper,
    ICollateralRebalancer.ExchangeState memory st,
    uint256 gross,
    ICollRebalancerMath math,
    uint256 leverageRatioWad
  ) private view returns (uint256) {
    (uint256 shares,,) = math.deleverageQuote(
      st.collVaultShares, st.debt, st.reservationValueWad, leverageRatioWad, st.spreadPpm, gross
    );
    if (shares == 0) return 0;
    (uint256 stableLeg,) = swapper.previewTokenAmounts(shares, false);
    return gross > stableLeg ? gross - stableLeg : 0;
  }

  function executeEverlongRebalancer(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    ICollateralRebalancerSwapper swapper = ICollateralRebalancerSwapper(data.decodeAddress(0));

    // The pair comes from the SWAPPER, not from `data`: word 1 is kept as the direction
    // the router intended and must agree, but the venue's own getters decide which leg is
    // which. Trusting the calldata address would let a wrong-token route settle as the
    // opposite direction.
    address stable = swapper.debtToken();
    address volatileToken = swapper.volatile();
    if (data.decodeAddress(1) != stable) revert EverlongRebalancerAdapter_TokenMismatch();
    bool stableIn = tokenIn == stable && tokenOut == volatileToken;
    if (!stableIn && !(tokenIn == volatileToken && tokenOut == stable)) {
      revert EverlongRebalancerAdapter_TokenMismatch();
    }

    tokenIn.forceApprove(address(swapper), amountIn);

    if (stableIn) {
      (amountUnused, amountOut) = _deleverage(swapper, amountIn, data, recipient);
    } else {
      (amountUnused, amountOut) = _leverage(swapper, amountIn, data.decodeUint256(2), recipient);
    }
    // Clear UNCONDITIONALLY: what the swapper pulled is its own report, and `data` chose
    // the swapper. Nothing may outlive the call.
    tokenIn.forceApprove(address(swapper), 0);
  }

  /// @dev volatile -> stable. The swapper posts EXACT CollVault shares; the largest
  /// share count whose mint-side volatile leg fits within `amountIn` is recovered by
  /// bisection (`previewTokenAmounts(shares, true)` is monotone nondecreasing). The
  /// flash-financing cap is the previewed stable leg — the swapper flash-mints exactly
  /// this and the unused part repays the loan.
  function _leverage(
    ICollateralRebalancerSwapper swapper,
    uint256 amountIn,
    uint256 sharesHint,
    address recipient
  ) private returns (uint256 amountUnused, uint256 amountOut) {
    uint256 shares = _sharesForVolatileIn(swapper, amountIn, sharesHint);
    if (shares == 0) revert EverlongRebalancerAdapter_NothingToFill();

    (uint256 stableRequired,) = swapper.previewTokenAmounts(shares, true);

    ICollateralRebalancerSwapper.VolatileForStableResult memory result =
      swapper.swapVolatileForStable(shares, stableRequired, amountIn, 1, recipient);

    amountOut = result.netStableOut;
    amountUnused = result.volatileRefund;
  }

  /// @dev stable -> volatile. `grossHint`/`netHint` are the quote-time gross debt and net
  /// stable spend, so when the runtime amount covers the quoted net the quote holds
  /// exactly. Below it the gross is re-derived against the venue's own math rather than
  /// rescaled: gross<->net bends with the bonding curve and the recycled stable leg, so a
  /// linear step both underfills and can overshoot into a revert.
  function _deleverage(
    ICollateralRebalancerSwapper swapper,
    uint256 amountIn,
    bytes calldata data,
    address recipient
  ) private returns (uint256 amountUnused, uint256 amountOut) {
    uint256 grossHint = data.decodeUint256(2);
    uint256 netHint = data.decodeUint256(3);
    uint256 leverageRatioWad = data.decodeUint256(5);
    if (leverageRatioWad == 0) leverageRatioWad = DEFAULT_LEVERAGE_RATIO_WAD;
    uint256 gross;
    if (grossHint != 0 && netHint != 0 && amountIn >= netHint) {
      // The quote holds only if the position has not moved since. It is keeper-managed,
      // so verify the hint still fits the budget rather than assuming: a hint whose net
      // has drifted up to `amountIn` reverts inside the swapper, killing the route, and
      // exact-net funding — what a router actually sends — has no headroom to absorb it
      // (strict: the wei of headroom from the contract notice must survive).
      gross = grossHint;
      uint256 hintNet = _netFor(
        swapper,
        ICollateralRebalancer(swapper.core()).exchangeState(),
        gross,
        ICollRebalancerMath(data.decodeAddress(4)),
        leverageRatioWad
      );
      // Zero means the venue no longer quotes the hint at all (past the debt or the
      // curve); that must re-derive too rather than be handed to the swapper.
      if (hintNet == 0 || hintNet >= amountIn) {
        gross = 0; // fall through to the exact re-derivation below
      }
    }
    if (gross == 0) {
      gross = _grossForNet(
        swapper,
        amountIn,
        grossHint,
        netHint,
        ICollRebalancerMath(data.decodeAddress(4)),
        leverageRatioWad
      );
    }
    if (gross == 0) revert EverlongRebalancerAdapter_NothingToFill();

    ICollateralRebalancerSwapper.StableForVolatileResult memory result =
      swapper.swapStableForVolatile(gross, amountIn, 1, recipient);

    amountOut = result.volatileOut;
    amountUnused = amountIn - result.netStableIn;
  }

  /// @dev Largest `shares` with previewTokenAmounts(shares, true).volatile <= amountIn,
  /// never above `sharesHint` when one is supplied.
  ///
  /// The hint is the EXACT share count the quote sized, and the quote is the cap: the
  /// rebalancer's physical-CR floor is evaluated only inside increaseLeverage, so a
  /// larger count can revert the fill rather than refund. So a hint that still fits is
  /// the answer — one preview call, no search — and a hint that no longer fits (the book
  /// moved since the quote) bisects strictly inside [0, hint]. Only a hint-free call
  /// brackets upward, doubling from 1.
  function _sharesForVolatileIn(
    ICollateralRebalancerSwapper swapper,
    uint256 amountIn,
    uint256 sharesHint
  ) private view returns (uint256) {
    uint256 lo;
    uint256 hi;
    // A hint past what the venue could ever post carries no information; it degrades to
    // the hint-free bracket rather than killing the fill.
    if (sharesHint != 0 && sharesHint <= MAX_SHARES) {
      if (_volatileFor(swapper, sharesHint) <= amountIn) return sharesHint;
      hi = sharesHint; // the answer is strictly below the hint
    } else {
      hi = 1;
      while (_volatileFor(swapper, hi) <= amountIn) {
        lo = hi;
        hi <<= 1;
        if (hi > MAX_SHARES) {
          hi = MAX_SHARES;
          break;
        }
      }
    }
    // invariant: volatileFor(lo) <= amountIn < volatileFor(hi) (or hi capped)
    while (hi - lo > 1) {
      uint256 mid = (lo + hi) >> 1;
      if (_volatileFor(swapper, mid) <= amountIn) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  function _volatileFor(ICollateralRebalancerSwapper swapper, uint256 shares)
    private
    view
    returns (uint256 volatileAmount)
  {
    (, volatileAmount) = swapper.previewTokenAmounts(shares, true);
  }
}
