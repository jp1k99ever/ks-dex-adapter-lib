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

/// @dev Getter products exceed uint256 even though each component is ABI-valid.
contract OverflowCapacityPsm {
  address public immutable debtToken;
  address public immutable stable;

  constructor(address debt_, address stable_) {
    debtToken = debt_;
    stable = stable_;
  }

  function stables(address asset) external view returns (uint64) {
    return asset == stable ? type(uint64).max : 0;
  }

  function availableReserve(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function debtTokenMinted(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function capHook() external view returns (address) {
    return address(this);
  }

  function maxRedeem(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function getMaxPsmOutflow(address, address, bool) external pure returns (uint256) {
    return type(uint256).max;
  }

  function redeem(address, uint256, address, uint16) external pure returns (uint256) {
    return 1;
  }
}

/// @dev An arbitrary core cannot force ratio-step arithmetic outside the reviewed
/// library's 1e38 input domain.
contract OversizedRebalancerCore {
  function exchangeState() external pure returns (ICollateralRebalancer.ExchangeState memory st) {
    st.collVaultShares = type(uint256).max;
    st.debt = type(uint256).max;
    st.reservationValueWad = 1e18;
  }
}

contract OversizedRebalancerSwapper {
  address public immutable core;
  address public immutable debtToken;
  address public immutable volatile;

  constructor(address core_, address debt_, address volatile_) {
    core = core_;
    debtToken = debt_;
    volatile = volatile_;
  }
}

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

    // The PSM always mints its own debt token, whatever tokenOut claims.
    EverlongPsmAdapter psm = new EverlongPsmAdapter();
    deal(HONEY, address(psm), 1e18);
    vm.expectRevert(EverlongPsmAdapter.EverlongPsmAdapter_TokenMismatch.selector);
    psm.executeEverlongPsm(abi.encode(PSM, NECT), 1e18, HONEY, WBTC, recipient);

    // An otherwise valid pair cannot override the PSM's debt token through data word 1.
    vm.expectRevert(EverlongPsmAdapter.EverlongPsmAdapter_TokenMismatch.selector);
    psm.executeEverlongPsm(abi.encode(PSM, HONEY), 1e18, HONEY, NECT, recipient);

    // The reverse direction must name the real debt token as input too.
    vm.expectRevert(EverlongPsmAdapter.EverlongPsmAdapter_TokenMismatch.selector);
    psm.executeEverlongPsm(abi.encode(PSM, NECT), 1e18, WBTC, HONEY, recipient);
  }

  /// @dev A forged debt-token word used to select redeem, making the real PSM burn NECT
  /// already held by the adapter while the call claimed HONEY as its input. Binding word
  /// 1 to debtToken() must stop the call before the residual balance can move.
  function test_psmForgedDirectionCannotBurnResidualDebt() public {
    EverlongPsmAdapter adapter = new EverlongPsmAdapter();
    uint256 residualDebt = 10e18;
    deal(NECT, address(adapter), residualDebt);
    uint256 recipientHoneyBefore = IERC20(HONEY).balanceOf(recipient);

    vm.expectRevert(EverlongPsmAdapter.EverlongPsmAdapter_TokenMismatch.selector);
    adapter.executeEverlongPsm(abi.encode(PSM, HONEY), residualDebt, HONEY, HONEY, recipient);

    assertEq(IERC20(NECT).balanceOf(address(adapter)), residualDebt, 'residual debt must not burn');
    assertEq(IERC20(HONEY).balanceOf(recipient), recipientHoneyBefore, 'no stable may pay out');
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

  /// @dev The math address and ratio are reviewed deployment-version tags. Calldata may
  /// attest to that version, but it cannot select another executable math implementation
  /// or change the leverage ratio used to size a real swapper call.
  function test_rebalancerMathVersionTagsFailClosed() public {
    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    uint256 amountIn = 5e18;
    deal(NECT, address(adapter), amountIn);

    vm.expectRevert(
      EverlongRebalancerAdapter.EverlongRebalancerAdapter_MathVersionMismatch.selector
    );
    adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), address(1), RATIO),
      amountIn,
      NECT,
      WBTC,
      recipient
    );

    vm.expectRevert(
      EverlongRebalancerAdapter.EverlongRebalancerAdapter_MathVersionMismatch.selector
    );
    adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, RATIO + 1),
      amountIn,
      NECT,
      WBTC,
      recipient
    );
    assertEq(IERC20(NECT).balanceOf(address(adapter)), amountIn, 'failed tags cannot spend input');
    assertEq(IERC20(NECT).allowance(address(adapter), SWAPPER), 0, 'failed tags leave no approval');
  }

  /// @dev Exact physical net is a chain fact, not a tolerance. Replaying a settled lot
  /// with that exact input must report no synthetic one-wei remainder.
  function test_rebalancerExactPhysicalNetHasZeroUnused() public {
    vm.createSelectFork(RPC_URL, 24_736_814);
    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    uint256 gross = 16_116_652_431_195_149_121;
    uint256 physicalNet = 10_132_227_981_359_897_368;
    deal(NECT, address(adapter), physicalNet);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, gross, physicalNet, MATH, RATIO), physicalNet, NECT, WBTC, recipient
    );

    assertEq(amountUnused, 0, 'exact physical net must be exact end-to-end');
    assertEq(amountOut, 15_707, 'settled volatile output must replay exactly');
    assertEq(IERC20(NECT).allowance(address(adapter), SWAPPER), 0);
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

  /// @dev Route-selected getters may return individually valid values whose capacity
  /// products overflow. Bounds saturate, and oversized rebalancer state fails closed,
  /// instead of either path panicking in adapter arithmetic.
  function test_adversarialGetterProductsCannotOverflowAdapterArithmetic() public {
    OverflowCapacityPsm psmVenue = new OverflowCapacityPsm(NECT, HONEY);
    EverlongPsmAdapter psm = new EverlongPsmAdapter();
    uint256 psmAmountIn = type(uint64).max;
    deal(NECT, address(psm), psmAmountIn);
    (uint256 psmUnused, uint256 psmOut) = psm.executeEverlongPsm(
      abi.encode(address(psmVenue), NECT), psmAmountIn, NECT, HONEY, recipient
    );
    assertEq(psmUnused, 0);
    assertEq(psmOut, 1);

    OversizedRebalancerCore oversizedCore = new OversizedRebalancerCore();
    OversizedRebalancerSwapper oversizedSwapper =
      new OversizedRebalancerSwapper(address(oversizedCore), NECT, WBTC);
    EverlongRebalancerAdapter rebalancer = new EverlongRebalancerAdapter();
    uint256 rebalancerAmountIn = 5e18;
    deal(NECT, address(rebalancer), rebalancerAmountIn);
    vm.expectRevert(EverlongRebalancerAdapter.EverlongRebalancerAdapter_NothingToFill.selector);
    rebalancer.executeEverlongRebalancer(
      abi.encode(address(oversizedSwapper), NECT, uint256(0), uint256(0), MATH, RATIO),
      rebalancerAmountIn,
      NECT,
      WBTC,
      recipient
    );
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
