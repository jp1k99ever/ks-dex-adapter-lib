// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/everlong-cvamm/EverlongCvammAdapter.sol';
import 'src/adapters/everlong-psm/EverlongPsmAdapter.sol';
import 'src/adapters/everlong-rebalancer/EverlongRebalancerAdapter.sol';

/// @dev A venue that reenters the adapter from inside the swap. The adapters are
/// stateless, so a reentrant call is just a second, independent fill attempt.
contract ReentrantVenue {
  address public token0;
  address public token1;
  EverlongCvammAdapter public target;
  bytes public payload;
  uint256 public reentered;

  constructor(address t0, address t1) {
    token0 = t0;
    token1 = t1;
  }

  function arm(EverlongCvammAdapter t, bytes memory p) external {
    target = t;
    payload = p;
  }

  function swap(bool, uint256 amountIn, uint256, uint160, address, uint256)
    external
    returns (uint256, uint256)
  {
    if (reentered++ == 0) {
      (bool ok,) = address(target).call(payload);
      ok; // the reentrant attempt may succeed or revert; what matters is the accounting below
    }
    // take everything it can — a malicious venue does exactly this
    uint256 take = IERC20(token0).balanceOf(msg.sender);
    uint256 allowed = IERC20(token0).allowance(msg.sender, address(this));
    if (allowed < take) take = allowed;
    if (take != 0) IERC20(token0).transferFrom(msg.sender, address(this), take);
    return (amountIn, 0);
  }
}

/// @dev A venue that reports a FULL fill while pulling nothing. Under an allowance
/// cleared only on a reported remainder, this would leave a standing approval against
/// whatever the adapter holds next.
contract LyingVenue {
  address public token0;
  address public token1;

  constructor(address t0, address t1) {
    token0 = t0;
    token1 = t1;
  }

  function swap(bool, uint256 amountIn, uint256, uint160, address, uint256)
    external
    pure
    returns (uint256, uint256)
  {
    return (amountIn, 0); // "I used everything" — but nothing was transferred
  }
}

/// @dev A recipient with no receive/fallback: plain ERC-20 output must still land.
contract DeafRecipient {}

/// @notice Adversarial cases: the adapters hold no standing funds and take every
/// address from `data`, so the exposure is (a) a crafted call stealing what the adapter
/// holds DURING that call — which is the caller's own input — and (b) misrouting on bad
/// arguments. Everything here must either fill correctly or revert; never misroute.
contract EverlongAdaptersAdversarialTest is Test {
  address constant ALM = 0xF5124F5605ce1e91A7429B837b7daC8f9E5378dd;
  address constant SWAPPER = 0x27775EC38E2b394738B73C0D25f63e20063DF054;
  address constant PSM = 0x0999417c0f9ded4356B099bcC83A16437B841323;
  address constant MATH = 0x4eBD7A6543Ace6076F089082931c380a3675bC5c;
  address constant NECT = 0x1cE0a25D13CE4d52071aE7e02Cf1F6606F4C79d3;
  address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
  address constant HONEY = 0xFCBD14DC51f0A4d49d5E53C2E0950e0bC26d0Dce;
  uint256 constant RATIO = 444_444_444_444_444_444;

  string RPC_URL = vm.envOr('RPC_80094', string('https://berachain.drpc.org'));
  uint256 constant PINNED_BLOCK = 25_107_939;
  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
  }

  /// @dev A malicious venue address in `data` can take at most this call's input, and no
  /// allowance survives the call — there is nothing to come back for.
  function test_maliciousVenueTakesOnlyThisCallsInput() public {
    ReentrantVenue venue = new ReentrantVenue(NECT, WBTC);
    EverlongCvammAdapter adapter = new EverlongCvammAdapter();
    uint256 amountIn = 10e18;
    deal(NECT, address(adapter), amountIn);
    venue.arm(
      adapter,
      abi.encodeCall(
        adapter.executeEverlongCvamm, (abi.encode(address(venue)), amountIn, NECT, WBTC, recipient)
      )
    );

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongCvamm(abi.encode(address(venue)), amountIn, NECT, WBTC, recipient);

    assertEq(venue.reentered(), 2, 'the reentrant attempt ran');
    assertEq(amountOut, 0);
    assertEq(amountUnused, 0);
    assertEq(
      IERC20(NECT).balanceOf(address(venue)), amountIn, 'took exactly the input, nothing more'
    );
    assertEq(IERC20(NECT).allowance(address(adapter), address(venue)), 0, 'no standing allowance');
  }

  /// @dev No allowance may outlive the call even when the venue reports a full fill.
  function test_allowanceClearedEvenWhenTheVenueClaimsFullConsumption() public {
    LyingVenue venue = new LyingVenue(NECT, WBTC);
    EverlongCvammAdapter adapter = new EverlongCvammAdapter();
    uint256 amountIn = 10e18;
    deal(NECT, address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongCvamm(abi.encode(address(venue)), amountIn, NECT, WBTC, recipient);

    assertEq(amountUnused, 0, 'the venue reported a full fill');
    assertEq(amountOut, 0);
    assertEq(
      IERC20(NECT).allowance(address(adapter), address(venue)),
      0,
      'no allowance may outlive the call, whatever the venue claims'
    );
    assertEq(IERC20(NECT).balanceOf(address(adapter)), amountIn, 'nothing was actually pulled');
  }

  /// @dev The pair is bound to the venue's own getters, so a mismatched tokenOut is
  /// refused by name rather than settled as the opposite leg.
  function test_mismatchedTokenOutIsRefusedByName() public {
    EverlongCvammAdapter cvamm = new EverlongCvammAdapter();
    deal(NECT, address(cvamm), 1e18);
    vm.expectRevert(EverlongCvammAdapter.EverlongCvammAdapter_TokenMismatch.selector);
    cvamm.executeEverlongCvamm(abi.encode(ALM), 1e18, NECT, HONEY, recipient);

    EverlongRebalancerAdapter reb = new EverlongRebalancerAdapter();
    deal(NECT, address(reb), 1e18);
    vm.expectRevert(EverlongRebalancerAdapter.EverlongRebalancerAdapter_TokenMismatch.selector);
    reb.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, RATIO), 1e18, NECT, HONEY, recipient
    );

    // and a `data` stable that is not the swapper's debt token is refused too
    EverlongRebalancerAdapter reb2 = new EverlongRebalancerAdapter();
    deal(NECT, address(reb2), 1e18);
    vm.expectRevert(EverlongRebalancerAdapter.EverlongRebalancerAdapter_TokenMismatch.selector);
    reb2.executeEverlongRebalancer(
      abi.encode(SWAPPER, HONEY, uint256(0), uint256(0), MATH, RATIO), 1e18, NECT, WBTC, recipient
    );
  }

  /// @dev A token the venue does not trade is never misrouted: the cvamm adapter treats
  /// anything but token0 as the volatile leg and the ALM pulls the real token, which
  /// fails closed.
  function test_cvammWrongTokenInRevertsNotMisroutes() public {
    EverlongCvammAdapter adapter = new EverlongCvammAdapter();
    deal(HONEY, address(adapter), 10e18);
    uint256 nectBefore = IERC20(NECT).balanceOf(recipient);
    vm.expectRevert();
    adapter.executeEverlongCvamm(abi.encode(ALM), 10e18, HONEY, NECT, recipient);
    assertEq(IERC20(NECT).balanceOf(recipient), nectBefore);
  }

  /// @dev The rebalancer adapter routes on `tokenIn == stable`; anything else is the
  /// volatile leg and the swapper pulls WBTC, for which there is no allowance.
  function test_rebalancerWrongTokenInRevertsNotMisroutes() public {
    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    deal(HONEY, address(adapter), 10e18);
    vm.expectRevert();
    adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, RATIO), 10e18, HONEY, NECT, recipient
    );
  }

  /// @dev A stable the PSM has not whitelisted is refused by name.
  function test_psmUnlistedStableReverts() public {
    EverlongPsmAdapter adapter = new EverlongPsmAdapter();
    deal(WBTC, address(adapter), 1e8);
    vm.expectRevert(EverlongPsmAdapter.EverlongPsmAdapter_NothingToFill.selector);
    adapter.executeEverlongPsm(abi.encode(PSM, NECT), 1e8, WBTC, NECT, recipient);
    deal(NECT, address(adapter), 1e18);
    vm.expectRevert(EverlongPsmAdapter.EverlongPsmAdapter_NothingToFill.selector);
    adapter.executeEverlongPsm(abi.encode(PSM, NECT), 1e18, NECT, WBTC, recipient);
  }

  /// @dev Garbage hints cannot steer the fill: a share hint past the book is ignored as
  /// a seed and, as a cap, can only shrink the lot; a gross hint past the debt (the
  /// venue answers zero for it) must re-derive rather than reach the swapper.
  function test_garbageHintsCannotSteerTheFill() public {
    // leverage: an absurd share hint is neither a seed nor a cap that breaks anything
    EverlongRebalancerAdapter lev = new EverlongRebalancerAdapter();
    deal(WBTC, address(lev), 20_000);
    (uint256 unusedHint, uint256 outHint) = lev.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, type(uint256).max, uint256(0), MATH, RATIO),
      20_000,
      WBTC,
      NECT,
      recipient
    );
    assertGt(outHint, 0);

    // deleverage: gross hint past the debt with a tiny net hint
    EverlongRebalancerAdapter dlv = new EverlongRebalancerAdapter();
    uint256 amountIn = 5e18;
    deal(NECT, address(dlv), amountIn);
    (uint256 unusedDlv, uint256 outDlv) = dlv.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(1e30), uint256(1), MATH, RATIO),
      amountIn,
      NECT,
      WBTC,
      recipient
    );
    assertGt(outDlv, 0, 'an unquotable hint must re-derive, not revert');
    assertLt(unusedDlv, amountIn);
    unusedHint;
  }

  /// @dev Absurd inputs revert cleanly (checked arithmetic / the venue's own guards),
  /// they never produce a wrong fill.
  function test_absurdAmountsRevertOrClamp() public {
    EverlongRebalancerAdapter dlv = new EverlongRebalancerAdapter();
    deal(NECT, address(dlv), 1e30);
    vm.expectRevert();
    dlv.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, RATIO),
      type(uint256).max,
      NECT,
      WBTC,
      recipient
    );

    EverlongPsmAdapter psm = new EverlongPsmAdapter();
    vm.expectRevert(EverlongPsmAdapter.EverlongPsmAdapter_NothingToFill.selector);
    psm.executeEverlongPsm(abi.encode(PSM, NECT), 0, HONEY, NECT, recipient);
  }

  /// @dev Output to a contract recipient with no receive hook lands like any ERC-20.
  function test_contractRecipientReceivesOutput() public {
    DeafRecipient deaf = new DeafRecipient();
    EverlongCvammAdapter adapter = new EverlongCvammAdapter();
    deal(NECT, address(adapter), 1e18);
    (, uint256 amountOut) =
      adapter.executeEverlongCvamm(abi.encode(ALM), 1e18, NECT, WBTC, address(deaf));
    assertGt(amountOut, 0);
    assertEq(IERC20(WBTC).balanceOf(address(deaf)), amountOut);
  }
}
