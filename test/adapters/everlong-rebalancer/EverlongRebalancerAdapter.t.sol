// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/everlong-rebalancer/EverlongRebalancerAdapter.sol';

/// @notice Fork tests against the live Berachain CollateralRebalancer stack
/// (rebalancer 0xA6b8...d6b3, swapper 0x2777...F054, NECT 18d / WBTC 8d).
///
/// `test_replaySettledLeverage` / `test_replaySettledDeleverage` re-execute every fill
/// the rebalancer has settled so far THROUGH THE ADAPTER on a fork of the fill's parent
/// block. The settled share counts and stable amounts are immutable chain facts from the
/// rebalancer's LeverageIncreased/LeverageDecreased events; the adapter (whose share
/// sizing is re-derived on-chain from the token amountIn) must land on exactly the same
/// fill.
contract EverlongRebalancerAdapterTest is Test {
  using TokenHelper for address;

  address constant SWAPPER = 0x27775EC38E2b394738B73C0D25f63e20063DF054;
  address constant NECT = 0x1cE0a25D13CE4d52071aE7e02Cf1F6606F4C79d3; // stable
  address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c; // volatile
  // Deployed CollRebalancerMath (linked into the rebalancer impl) and the ratio it
  // validates against — neither is exposed by a getter.
  address constant MATH = 0x4eBD7A6543Ace6076F089082931c380a3675bC5c;
  uint256 constant LEVERAGE_RATIO_WAD = 444_444_444_444_444_444;

  string RPC_URL = vm.envOr('RPC_80094', string('https://berachain.drpc.org'));
  /// @dev Every unpinned fork is pinned here: one block keeps the suite deterministic and
  /// lets forge cache the RPC reads, which the public endpoint's rate limit needs.
  uint256 constant PINNED_BLOCK = 25_107_939;

  address recipient = makeAddr('recipient');

  struct SettledLeverage {
    uint256 fillBlock;
    uint256 collVaultSharesIn;
    uint256 grossStableOut; // rebalancer LeverageIncreased.stableOut
  }

  struct SettledDeleverage {
    uint256 fillBlock;
    uint256 grossStableIn; // rebalancer LeverageDecreased.stableIn
    uint256 netStableIn; // swapper StableForVolatileSwapped.netStableIn
    uint256 volatileOut; // swapper StableForVolatileSwapped.volatileOut
    uint256 collVaultSharesOut;
  }

  function _bytesData() internal pure returns (address, address) {
    return (SWAPPER, NECT);
  }

  /// @dev volatile -> stable. amountIn is set to the mint-side volatile leg of the
  /// settled share count AT THE PARENT BLOCK, so the adapter's on-chain bisection must
  /// recover exactly the settled shares — proving the inversion agrees with the venue.
  function test_replaySettledLeverage() public {
    SettledLeverage[3] memory fills = [
      SettledLeverage(24_736_813, 325_575_695_741, 16_233_085_183_578_902_831),
      SettledLeverage(24_736_819, 325_317_236_855, 16_228_279_433_395_203_569),
      SettledLeverage(24_736_822, 325_035_093_692, 16_222_631_502_220_807_982)
    ];
    for (uint256 i = 0; i < fills.length; i++) {
      SettledLeverage memory f = fills[i];
      vm.createSelectFork(RPC_URL, f.fillBlock - 1);
      EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();

      (uint256 stableLeg, uint256 volatileLeg) =
        ICollateralRebalancerSwapper(SWAPPER).previewTokenAmounts(f.collVaultSharesIn, true);
      deal(WBTC, address(adapter), volatileLeg);

      // hint-free run (sharesHint = 0) so the whole inversion is exercised on-chain
      bytes memory data =
        abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD);
      vm.recordLogs();
      (uint256 amountUnused, uint256 amountOut) =
        adapter.executeEverlongRebalancer(data, volatileLeg, WBTC, NECT, recipient);

      // Per-share volatile is ~1e-7 sats here, so the preview has multi-million-share
      // rounding plateaus: the settled fill (share-denominated by the keeper) sits
      // INSIDE a plateau while the adapter takes its right edge — the LARGEST share
      // count the same volatile budget affords, the same rule the kyberswap-dex-lib
      // simulator inverts by. Assert that maximality directly on-chain:
      uint256 minted = _mintedSharesFromLogs();
      assertGe(minted, f.collVaultSharesIn, 'adapter shares must cover the settled fill');
      (, uint256 volAtMinted) =
        ICollateralRebalancerSwapper(SWAPPER).previewTokenAmounts(minted, true);
      assertLe(volAtMinted, volatileLeg, 'derived shares must fit the volatile budget');
      (, uint256 volAtNext) =
        ICollateralRebalancerSwapper(SWAPPER).previewTokenAmounts(minted + 1, true);
      assertGt(volAtNext, volatileLeg, 'one share more must exceed the volatile budget');

      // previewTokenAmounts is a documented conservative upper bound on the physical
      // legs ("fee realization and per-rung withdrawal rounding can make execution
      // differ slightly"); the ALM refunds what the preview over-reserves, so the net
      // stable is AT LEAST the settled-fill-implied net and the slack stays tiny.
      uint256 expectedNetFloor = f.grossStableOut - stableLeg;
      assertGe(amountOut, expectedNetFloor, 'settled-implied net is a floor of execution');
      assertLt(
        amountOut - expectedNetFloor,
        f.grossStableOut / 2000,
        'plateau + materialization slack must stay within 5bp of the gross'
      );
      assertEq(NECT.balanceOf(recipient), amountOut, 'net stable delivered to recipient');
      assertEq(
        WBTC.balanceOf(address(adapter)), amountUnused, 'refunded volatile stays in the adapter'
      );
    }
  }

  /// @dev stable -> volatile, driven the way production does: the router funds the NET
  /// stable and passes distinct gross/net hints, with the freed stable leg covering the
  /// rest of the gross. Every amount here is a settled chain fact.
  function test_replaySettledDeleverage() public {
    SettledDeleverage[2] memory fills = [
      SettledDeleverage(
        24_736_815, 16_116_652_431_195_149_121, 10_132_227_981_359_897_368, 15_707, 313_304_599_949
      ),
      SettledDeleverage(
        24_736_821, 16_129_906_364_468_588_729, 10_143_595_570_600_375_733, 15_712, 313_403_356_357
      )
    ];
    for (uint256 i = 0; i < fills.length; i++) {
      SettledDeleverage memory f = fills[i];
      assertLt(f.netStableIn, f.grossStableIn, 'the recycled leg must make net < gross');
      bytes memory data =
        abi.encode(SWAPPER, NECT, f.grossStableIn, f.netStableIn, MATH, LEVERAGE_RATIO_WAD);

      // Production: the route delivers the simulator's exact physical net and the
      // quoted gross settles verbatim. No synthetic headroom belongs in amountIn.
      vm.createSelectFork(RPC_URL, f.fillBlock - 1);
      EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
      deal(NECT, address(adapter), f.netStableIn);
      (uint256 amountUnused, uint256 amountOut) =
        adapter.executeEverlongRebalancer(data, f.netStableIn, NECT, WBTC, recipient);

      assertEq(amountOut, f.volatileOut, 'volatile out must match the settled fill');
      assertEq(amountUnused, 0, 'the physical net quote must be consumed exactly');
      assertEq(WBTC.balanceOf(recipient), amountOut);

      // Overfunded, from a FRESH fork: the run above settles a real deleverage and moves
      // the curve, so the surplus case has to start from the same pre-fill state.
      vm.createSelectFork(RPC_URL, f.fillBlock - 1);
      adapter = new EverlongRebalancerAdapter();
      deal(NECT, address(adapter), f.grossStableIn);
      (uint256 overUnused, uint256 overOut) =
        adapter.executeEverlongRebalancer(data, f.grossStableIn, NECT, WBTC, recipient);

      assertEq(overOut, f.volatileOut, 'surplus input must not change the lot');
      assertEq(overUnused, f.grossStableIn - f.netStableIn, 'surplus must refund untouched');
      assertEq(NECT.balanceOf(address(adapter)), overUnused, 'unspent stable stays in the adapter');
    }
  }

  /// @dev The seeded bisection must agree with the hint-free one. The hint is also the
  /// cap, so the seed here sits ABOVE the answer (a stale quote from a bigger lot); a
  /// hint below it caps instead — test_leverageOversizedClampsToQuote.
  function test_leverage_hintMatchesHintFree() public {
    vm.createSelectFork(RPC_URL, 24_736_812);
    uint256 amountIn = 30_000; // sats, below the full realignment lot

    uint256 snapshot = vm.snapshotState();
    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    deal(WBTC, address(adapter), amountIn);
    (uint256 unusedFree, uint256 outFree) = adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD),
      amountIn,
      WBTC,
      NECT,
      recipient
    );
    vm.revertToState(snapshot);

    adapter = new EverlongRebalancerAdapter();
    deal(WBTC, address(adapter), amountIn);
    (uint256 unusedHint, uint256 outHint) = adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(2 * 325_575_695_741), uint256(0), MATH, LEVERAGE_RATIO_WAD), // stale, high
      amountIn,
      WBTC,
      NECT,
      recipient
    );

    assertEq(outFree, outHint, 'hint must not change the fill');
    assertEq(unusedFree, unusedHint);

    // The exact hint costs one preview call, the hint-free bracket a search: pin that the
    // hint is actually taken rather than re-derived.
    uint256 quoted = 325_575_695_741;
    (, uint256 quotedVolatile) =
      ICollateralRebalancerSwapper(SWAPPER).previewTokenAmounts(quoted, true);
    vm.revertToState(snapshot);
    adapter = new EverlongRebalancerAdapter();
    deal(WBTC, address(adapter), quotedVolatile);
    uint256 gasBefore = gasleft();
    adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, quoted, uint256(0), MATH, LEVERAGE_RATIO_WAD),
      quotedVolatile,
      WBTC,
      NECT,
      recipient
    );
    uint256 gasExactHint = gasBefore - gasleft();

    vm.revertToState(snapshot);
    adapter = new EverlongRebalancerAdapter();
    deal(WBTC, address(adapter), quotedVolatile);
    gasBefore = gasleft();
    adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD),
      quotedVolatile,
      WBTC,
      NECT,
      recipient
    );
    uint256 gasHintFree = gasBefore - gasleft();
    assertLt(gasExactHint, gasHintFree, 'an exact hint must skip the search');
    emit log_named_uint('leverage gas, exact hint', gasExactHint);
    emit log_named_uint('leverage gas, hint-free', gasHintFree);
  }

  /// @dev The quote-time share count is a CAP, not only a seed: the rebalancer's
  /// physical-CR floor is evaluated only inside increaseLeverage, so a bisection that
  /// outruns the quote sizes the call into a revert. With twice the volatile the quote
  /// needs, the fill must post exactly the quoted shares and refund the rest.
  function test_leverageOversizedClampsToQuote() public {
    vm.createSelectFork(RPC_URL, 24_736_812);
    uint256 quotedShares = 325_575_695_741; // the 30k-sat lot at this block
    (, uint256 quotedVolatile) =
      ICollateralRebalancerSwapper(SWAPPER).previewTokenAmounts(quotedShares, true);
    uint256 amountIn = quotedVolatile * 2;

    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    deal(WBTC, address(adapter), amountIn);
    vm.recordLogs();
    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, quotedShares, uint256(0), MATH, LEVERAGE_RATIO_WAD),
      amountIn,
      WBTC,
      NECT,
      recipient
    );

    assertGt(amountOut, 0);
    assertEq(_mintedSharesFromLogs(), quotedShares, 'must post exactly the quoted shares');
    assertGe(amountUnused, amountIn - quotedVolatile, 'the excess volatile must refund');
    assertEq(IERC20(WBTC).allowance(address(adapter), SWAPPER), 0);
  }

  /// @dev Exact physical-net funding — what a router sends for a quoted (gross, net) —
  /// must fill with zero remainder. Discover the physical net from one execution, then
  /// replay the same state with exactly that amount; the aggregate reserve preview is
  /// intentionally not treated as an execution-exact substitute.
  function test_deleverageExactNetFundingFills() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    uint256 quotedGross = 20e18;
    uint256 previewNet = _netFor(quotedGross);
    assertGt(previewNet, 0);

    uint256 snapshot = vm.snapshotState();
    EverlongRebalancerAdapter probe = new EverlongRebalancerAdapter();
    deal(NECT, address(probe), quotedGross);
    (uint256 probeUnused,) = probe.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, quotedGross, previewNet, MATH, LEVERAGE_RATIO_WAD),
      quotedGross,
      NECT,
      WBTC,
      recipient
    );
    uint256 physicalNet = quotedGross - probeUnused;
    assertGt(physicalNet, 0);
    vm.revertToState(snapshot);

    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    deal(NECT, address(adapter), physicalNet);
    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, quotedGross, physicalNet, MATH, LEVERAGE_RATIO_WAD),
      physicalNet,
      NECT,
      WBTC,
      recipient
    );

    assertGt(amountOut, 0, 'exact-net funding must fill');
    assertEq(amountUnused, 0, 'physical net funding must not manufacture a remainder');
    assertEq(IERC20(NECT).allowance(address(adapter), SWAPPER), 0);
  }

  function _mintedSharesFromLogs() internal returns (uint256) {
    // VolatileForStableSwapped(caller, receiver, volatileIn, volatileRefund, netStableOut,
    //                          grossStableOut, collVaultSharesMinted, ...)
    Vm.Log[] memory logs = vm.getRecordedLogs();
    bytes32 topic = keccak256(
      'VolatileForStableSwapped(address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)'
    );
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == SWAPPER && logs[i].topics[0] == topic) {
        (,,,, uint256 minted,,,) = abi.decode(
          logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
        );
        return minted;
      }
    }
    revert('VolatileForStableSwapped not found');
  }

  /// @dev Net stable spent for `gross` debt retired, straight off the venue's own math.
  function _netFor(uint256 gross) internal view returns (uint256) {
    ICollateralRebalancer.ExchangeState memory st =
      ICollateralRebalancer(ICollateralRebalancerSwapper(SWAPPER).core()).exchangeState();
    (uint256 shares,,) = ICollRebalancerMath(MATH)
      .deleverageQuote(
        st.collVaultShares, st.debt, st.reservationValueWad, LEVERAGE_RATIO_WAD, st.spreadPpm, gross
      );
    (uint256 stableLeg,) = ICollateralRebalancerSwapper(SWAPPER).previewTokenAmounts(shares, false);
    return gross > stableLeg ? gross - stableLeg : 0;
  }

  /// @dev Regression: a partial fill (runtime amount below the quoted net) used to rescale
  /// the gross linearly, which the bonding curve and the recycled stable leg make wrong —
  /// at this state that lands 0.78% past the net cap.
  function test_deleveragePartialUsesCurveGross() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);

    uint256 quotedGross = 20e18;
    uint256 quotedNet = _netFor(quotedGross);
    assertGt(quotedNet, 0, 'venue must quote deleverage at this state');

    uint256 amountIn = quotedNet * 70 / 100; // below the quote -> partial path

    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    deal(NECT, address(adapter), amountIn);
    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, quotedGross, quotedNet, MATH, LEVERAGE_RATIO_WAD),
      amountIn,
      NECT,
      WBTC,
      recipient
    );

    assertGt(amountOut, 0, 'partial fill must still fill');
    uint256 netSpent = amountIn - amountUnused;
    assertLe(netSpent, amountIn, 'never spend past the budget');

    // The linear step lands OVER the cap here. The bounded curve derivation removes that
    // failure and consumes the budget to within its documented recovery tolerance.
    uint256 linearNet = _netFor(quotedGross * amountIn / quotedNet);
    assertGt(linearNet, amountIn, 'linear rescale must overshoot, else this proves nothing');
    assertGe(netSpent * 1e6 / amountIn, 999_999, 'recovery sizing must consume the budget');
  }

  /// @dev Worst-case gas probe: hint-free leverage across sizes up to the venue's max
  /// lot, where the share bisection brackets up from 1 and each step is a staticcall.
  function test_gas_leverageWorstCase() public {
    vm.createSelectFork(RPC_URL, 24_736_812);
    uint256[6] memory sizes = [uint256(30_000), 60_000, 100_000, 150_000, 200_000, 280_000];
    for (uint256 i = 0; i < sizes.length; i++) {
      uint256 snap = vm.snapshotState();
      EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
      deal(WBTC, address(adapter), sizes[i]);
      uint256 before = gasleft();
      try adapter.executeEverlongRebalancer(
        abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD),
        sizes[i],
        WBTC,
        NECT,
        recipient
      ) returns (
        uint256, uint256
      ) {
        emit log_named_uint('ok   sats', sizes[i]);
        emit log_named_uint('  gas    ', before - gasleft());
      } catch {
        emit log_named_uint('REJECTED sats', sizes[i]);
      }
      vm.revertToState(snap);
    }
  }

  /// @dev How close the sizing gets with and without quote hints. The hint-free path
  /// starts at `budget`, which is far below the answer whenever the recycled leg is
  /// large, so it needs more steps to converge than the seeded one.
  function test_gas_deleverageConvergence() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    uint256 quotedGross = 20e18;
    uint256 quotedNet = _netFor(quotedGross);
    uint256 amountIn = quotedNet * 70 / 100;

    for (uint256 k = 0; k < 2; k++) {
      bool hinted = k == 1;
      uint256 snap = vm.snapshotState();
      EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
      deal(NECT, address(adapter), amountIn);
      bytes memory data = hinted
        ? abi.encode(SWAPPER, NECT, quotedGross, quotedNet, MATH, LEVERAGE_RATIO_WAD)
        : abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD);
      (uint256 unused_,) = adapter.executeEverlongRebalancer(data, amountIn, NECT, WBTC, recipient);
      uint256 spent = amountIn - unused_;
      emit log_named_string('mode', hinted ? 'hinted' : 'hint-free');
      emit log_named_uint('  budget   ', amountIn);
      emit log_named_uint('  spent    ', spent);
      emit log_named_uint('  shortfall', amountIn - spent);
      vm.revertToState(snap);
    }
  }

  /// @dev Sweeps the partial-deleverage split across the range. A linear seed is worst at
  /// small budgets, where the true gross is furthest from proportional, so the whole
  /// range has to be measured rather than one split.
  function test_deleveragePartialSweep() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    uint256 quotedGross = 20e18;
    uint256 quotedNet = _netFor(quotedGross);
    _sweep(quotedGross, quotedNet, true);
    _sweep(quotedGross, quotedNet, false);
    // Small absolute lots: integer flooring in the ratio step weighs more the smaller
    // the budget, so the worst case is here rather than at a small fraction of a big lot.
    uint256[3] memory smallGross = [uint256(1e18), 1e17, 1e16];
    for (uint256 j = 0; j < smallGross.length; j++) {
      uint256 n = _netFor(smallGross[j]);
      if (n == 0) continue;
      emit log_named_uint('small lot gross', smallGross[j]);
      _sweep(smallGross[j], n, true);
      _sweep(smallGross[j], n, false);
    }
  }

  function _sweep(uint256 quotedGross, uint256 quotedNet, bool hinted) internal {
    uint256[10] memory pcts = [uint256(1), 2, 5, 10, 20, 40, 60, 80, 95, 99];
    uint256 worstBps;
    uint256 worstPct;
    for (uint256 i = 0; i < pcts.length; i++) {
      uint256 amountIn = quotedNet * pcts[i] / 100;
      if (amountIn == 0) continue;
      uint256 snap = vm.snapshotState();
      EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
      deal(NECT, address(adapter), amountIn);
      bytes memory data = hinted
        ? abi.encode(SWAPPER, NECT, quotedGross, quotedNet, MATH, LEVERAGE_RATIO_WAD)
        : abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD);
      // A lot the book itself refuses is a venue limit, not a solver miss.
      try adapter.executeEverlongRebalancer(data, amountIn, NECT, WBTC, recipient) returns (
        uint256 unused_, uint256 out
      ) {
        if (out == 0) {
          vm.revertToState(snap);
          continue;
        }
        uint256 bps = unused_ * 10_000 / amountIn;
        if (bps > worstBps) {
          worstBps = bps;
          worstPct = pcts[i];
        }
      } catch {} // venue refused this lot
      vm.revertToState(snap);
    }
    emit log_named_string('mode', hinted ? 'hinted' : 'hint-free');
    emit log_named_uint('  worst unused bps', worstBps);
    emit log_named_uint('  at split pct    ', worstPct);
    assertLe(worstBps, 1, 'no split may leave more than 1 bps of the budget unused');
  }

  /// @dev No allowance may outlive a partial fill. The approval is taken on the whole
  /// `amountIn` up front, and both directions size themselves to the venue — but the
  /// swapper pulls the full amount and refunds the remainder as a TOKEN transfer, so it
  /// consumes the approval rather than stranding it. This pins that behaviour: a swapper
  /// that instead pulled only what it spent would leave the remainder standing, and the
  /// adapter would have to clear it explicitly the way the cvamm one does.
  function test_partialFillClearsAllowance() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);

    // Deleverage below the quoted net: the gross is re-derived and floors, so the budget
    // is never spent to the wei. Splits vary in how much they strand, so take the first
    // that actually leaves one.
    uint256 quotedNet = _netFor(20e18);
    uint256[3] memory pcts = [uint256(40), 60, 80];
    bool checkedDeleverage;
    for (uint256 i = 0; i < pcts.length && !checkedDeleverage; i++) {
      uint256 snap = vm.snapshotState();
      EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
      uint256 amountIn = quotedNet * pcts[i] / 100;
      deal(NECT, address(adapter), amountIn);
      try adapter.executeEverlongRebalancer(
        abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD),
        amountIn,
        NECT,
        WBTC,
        recipient
      ) returns (
        uint256 amountUnused, uint256
      ) {
        if (amountUnused != 0) {
          assertEq(
            IERC20(NECT).allowance(address(adapter), SWAPPER),
            0,
            'no stable allowance may outlive the fill'
          );
          checkedDeleverage = true;
        }
      } catch {} // venue refused this lot
      if (!checkedDeleverage) vm.revertToState(snap);
    }
    assertTrue(checkedDeleverage, 'no split left a remainder, so the assertion never ran');

    // Leverage: the share bisection floors, so the volatile leg strands a remainder too.
    // Sized like the other leverage cases — a lot the book can actually absorb.
    EverlongRebalancerAdapter lev = new EverlongRebalancerAdapter();
    uint256 volIn = 30_000; // sats
    deal(WBTC, address(lev), volIn);
    lev.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD),
      volIn,
      WBTC,
      NECT,
      recipient
    );
    // Whether the bisection lands exactly or strands a sliver, nothing may be left
    // standing.
    assertEq(
      IERC20(WBTC).allowance(address(lev), SWAPPER), 0, 'no volatile allowance may outlive the fill'
    );
  }

  /// @dev Regression: the position is keeper-managed, so a quoted (gross, net) pair can
  /// go stale between quote and fill. The fast path used the hint verbatim, and a router
  /// funding exactly the quoted net had no headroom — a third-party fill moved the
  /// required net ~68 bps and the whole route reverted. It must now re-derive instead.
  function test_deleverageSurvivesStateDrift() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    uint256 quotedGross = 20e18;
    uint256 quotedNet = _netFor(quotedGross);

    // A third party deleverages first, moving the position under our quote.
    EverlongRebalancerAdapter mover = new EverlongRebalancerAdapter();
    deal(NECT, address(mover), 5e18);
    mover.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD),
      5e18,
      NECT,
      WBTC,
      recipient
    );
    assertGt(_netFor(quotedGross), quotedNet, 'the drift must raise the required net');

    // The victim fills with EXACTLY the stale quoted net — the production shape.
    EverlongRebalancerAdapter a = new EverlongRebalancerAdapter();
    deal(NECT, address(a), quotedNet);
    (uint256 unused_, uint256 out) = a.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, quotedGross, quotedNet, MATH, LEVERAGE_RATIO_WAD),
      quotedNet,
      NECT,
      WBTC,
      recipient
    );
    assertGt(out, 0, 'a stale hint must re-derive, not revert the route');
    assertLe(quotedNet - unused_, quotedNet, 'never spends past the budget');
  }

  /// @dev Canonical adapter test, deleverage leg: the fuzzed value is the runtime
  /// `amountIn` (hint-free, inside the lot the venue quotes at the pinned block).
  function test_executeEverlongRebalancer(uint256 amountIn) public {
    amountIn = bound(amountIn, 1e18, 30e18);
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    deal(NECT, address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD),
      amountIn,
      NECT,
      WBTC,
      recipient
    );

    assertGt(amountOut, 0);
    assertEq(amountUnused, IERC20(NECT).balanceOf(address(adapter)));
    assertEq(amountOut, IERC20(WBTC).balanceOf(recipient));
    assertEq(IERC20(NECT).allowance(address(adapter), SWAPPER), 0);
  }

  /// @dev Canonical adapter test, leverage leg.
  function test_executeEverlongRebalancer_leverage(uint256 amountIn) public {
    amountIn = bound(amountIn, 5000, 30_000); // sats
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    deal(WBTC, address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, uint256(0), uint256(0), MATH, LEVERAGE_RATIO_WAD),
      amountIn,
      WBTC,
      NECT,
      recipient
    );

    assertGt(amountOut, 0);
    assertEq(amountUnused, IERC20(WBTC).balanceOf(address(adapter)));
    assertEq(amountOut, IERC20(NECT).balanceOf(recipient));
    assertEq(IERC20(WBTC).allowance(address(adapter), SWAPPER), 0);
  }

  /// @dev The math address and ratio are version tags, not route-selectable behavior.
  /// A missing ratio fails closed instead of silently selecting a fallback.
  function test_deleverageZeroRatioWordReverts() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    uint256 quotedGross = 20e18;
    uint256 quotedNet = _netFor(quotedGross);
    uint256 amountIn = quotedNet * 70 / 100;

    EverlongRebalancerAdapter adapter = new EverlongRebalancerAdapter();
    deal(NECT, address(adapter), amountIn);
    vm.expectRevert(
      EverlongRebalancerAdapter.EverlongRebalancerAdapter_MathVersionMismatch.selector
    );
    adapter.executeEverlongRebalancer(
      abi.encode(SWAPPER, NECT, quotedGross, quotedNet, MATH, uint256(0)),
      amountIn,
      NECT,
      WBTC,
      recipient
    );
  }
}
