// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/everlong-cvamm/EverlongCvammAdapter.sol';

/// @notice Fork tests against the live Berachain CvammALM (NECT 18d / WBTC 8d).
///
/// `test_replaySettledSwaps` is the strongest gate: every swap the venue has settled so
/// far is re-executed THROUGH THE ADAPTER on a fork of its parent block, and the adapter
/// must reproduce the settled (amountInUsed, amountOut) to the wei. The settled numbers
/// are immutable chain facts read from the venue's own Swap events.
contract EverlongCvammAdapterTest is Test {
  using TokenHelper for address;

  address constant ALM = 0xF5124F5605ce1e91A7429B837b7daC8f9E5378dd;
  address constant NECT = 0x1cE0a25D13CE4d52071aE7e02Cf1F6606F4C79d3; // stable, token0
  address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c; // volatile, token1

  string RPC_URL = vm.envOr('RPC_80094', string('https://berachain.drpc.org'));
  uint256 constant PINNED_BLOCK = 25_107_939;

  struct SettledSwap {
    uint256 fillBlock;
    bool stableIn;
    uint256 amountInUsed;
    uint256 amountOut;
  }

  address recipient = makeAddr('recipient');

  function _settledSwaps() internal pure returns (SettledSwap[26] memory s) {
    s[0] = SettledSwap(24_710_246, true, 867_079_883_292_166_013, 1339);
    s[1] = SettledSwap(24_718_315, true, 9_989_830_569_600_000_000, 15_299);
    s[2] = SettledSwap(24_718_412, true, 9_989_830_569_600_000_000, 15_277);
    s[3] = SettledSwap(24_718_414, true, 9_989_830_569_600_000_000, 15_266);
    s[4] = SettledSwap(24_718_416, true, 9_989_877_163_959_000_000, 15_258);
    s[5] = SettledSwap(24_718_418, true, 9_989_747_109_144_000_000, 15_242);
    s[6] = SettledSwap(24_718_659, true, 10_193_987_263_153_248_160, 15_534);
    s[7] = SettledSwap(24_718_661, true, 10_193_987_263_153_248_160, 15_511);
    s[8] = SettledSwap(24_719_736, false, 289_774, 182_613_414_876_231_814_869);
    s[9] = SettledSwap(24_719_738, true, 225_945_811_467_202_560_000, 351_771);
    s[10] = SettledSwap(24_719_740, false, 351_005, 222_832_384_009_401_577_185);
    s[11] = SettledSwap(24_731_620, true, 9_850_123_728_037_687_640, 15_765);
    s[12] = SettledSwap(24_731_622, true, 9_850_123_728_037_687_640, 15_697);
    s[13] = SettledSwap(24_731_624, true, 9_892_818_529_044_949_431, 15_704);
    s[14] = SettledSwap(24_731_626, true, 9_966_181_427_764_650_000, 15_763);
    // Post-FFAD-upgrade fills (V2 impl on the same proxy, dynamic directional fees via the
    // fee hook): the first V2 fill, then a consecutive-block session where the directional
    // fees flipped between fills — amounts read from the settled Transfer events.
    s[15] = SettledSwap(24_842_443, true, 41_839_614_101_974_141_153, 64_490);
    s[16] = SettledSwap(24_851_050, true, 21_344_773_036_602_903_406, 33_000);
    s[17] = SettledSwap(24_851_051, false, 32_983, 20_073_149_042_142_064_543);
    s[18] = SettledSwap(24_852_477, true, 33_681_533_486_499_002_033, 52_000);
    s[19] = SettledSwap(24_852_478, false, 51_974, 31_971_785_080_102_244_364);
    s[20] = SettledSwap(24_852_479, true, 31_088_954_932_161_355_729, 48_000);
    s[21] = SettledSwap(24_852_480, false, 47_976, 29_510_235_063_504_224_580);
    s[22] = SettledSwap(24_852_481, true, 26_548_406_326_476_430_144, 41_000);
    s[23] = SettledSwap(24_852_482, false, 40_979, 25_200_120_638_781_700_197);
    s[24] = SettledSwap(24_852_483, true, 23_307_813_433_172_828_336, 36_000);
    s[25] = SettledSwap(24_852_484, false, 35_982, 22_123_711_591_926_966_525);
  }

  function test_replaySettledSwaps() public {
    SettledSwap[26] memory swaps = _settledSwaps();
    for (uint256 i = 0; i < swaps.length; i++) {
      SettledSwap memory s = swaps[i];
      vm.createSelectFork(RPC_URL, s.fillBlock - 1);
      EverlongCvammAdapter adapter = new EverlongCvammAdapter();

      (address tokenIn, address tokenOut) = s.stableIn ? (NECT, WBTC) : (WBTC, NECT);
      deal(tokenIn, address(adapter), s.amountInUsed);

      (uint256 amountUnused, uint256 amountOut) =
        adapter.executeEverlongCvamm(abi.encode(ALM), s.amountInUsed, tokenIn, tokenOut, recipient);

      assertEq(amountUnused, 0, 'settled amountInUsed must be fully consumed');
      assertEq(amountOut, s.amountOut, 'adapter must reproduce the settled amountOut');
      assertEq(tokenOut.balanceOf(recipient), s.amountOut, 'output delivered to recipient');
      assertEq(tokenIn.balanceOf(address(adapter)), 0, 'input fully spent');
    }
  }

  /// @dev An oversized input hits the solvency clamp: the fill truncates and the
  /// untaken remainder stays in the adapter, surfacing through `amountUnused`.
  function test_partialFill_oversizedInput() public {
    vm.createSelectFork(RPC_URL, 24_759_900);
    EverlongCvammAdapter adapter = new EverlongCvammAdapter();

    uint256 amountIn = 100_000_000e18; // far beyond the book
    deal(NECT, address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongCvamm(abi.encode(ALM), amountIn, NECT, WBTC, recipient);

    assertGt(amountOut, 0);
    assertGt(amountUnused, 0, 'oversized input must partially fill');
    assertEq(NECT.balanceOf(address(adapter)), amountUnused, 'unused input stays in the adapter');
    assertEq(WBTC.balanceOf(recipient), amountOut);
  }

  /// @dev The same partial path in the volatile-in direction, which carries its own gas
  /// profile and its own default.
  function test_partialFill_oversizedVolatileIn() public {
    vm.createSelectFork(RPC_URL, 24_759_900);
    EverlongCvammAdapter adapter = new EverlongCvammAdapter();

    uint256 amountIn = 1000e8; // far beyond the book
    deal(WBTC, address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongCvamm(abi.encode(ALM), amountIn, WBTC, NECT, recipient);

    assertGt(amountOut, 0);
    assertGt(amountUnused, 0, 'oversized input must partially fill');
    assertEq(WBTC.balanceOf(address(adapter)), amountUnused, 'unused input stays in the adapter');
    assertEq(NECT.balanceOf(recipient), amountOut);
  }

  /// @dev A partial fill must not leave a standing allowance equal to the stranded
  /// remainder — the ALM is an upgradeable proxy and could take it later.
  function test_partialFillClearsAllowance() public {
    vm.createSelectFork(RPC_URL, 24_759_900);
    EverlongCvammAdapter adapter = new EverlongCvammAdapter();

    uint256 amountIn = 100_000_000e18; // far beyond the book
    deal(NECT, address(adapter), amountIn);
    (uint256 amountUnused,) =
      adapter.executeEverlongCvamm(abi.encode(ALM), amountIn, NECT, WBTC, recipient);

    assertGt(amountUnused, 0, 'the fill must be partial for this to mean anything');
    assertEq(IERC20(NECT).allowance(address(adapter), ALM), 0, 'no allowance may outlive the swap');
  }

  /// @dev Canonical adapter test: the fuzzed value is the runtime `amountIn`, passed
  /// straight to the entrypoint; accounting must close on balances either way.
  function test_executeEverlongCvamm(uint256 amountIn) public {
    amountIn = bound(amountIn, 1e16, 1000e18);
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    EverlongCvammAdapter adapter = new EverlongCvammAdapter();
    deal(NECT, address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongCvamm(abi.encode(ALM), amountIn, NECT, WBTC, recipient);

    assertGt(amountOut, 0);
    assertEq(amountUnused, IERC20(NECT).balanceOf(address(adapter)));
    assertEq(amountOut, IERC20(WBTC).balanceOf(recipient));
    assertEq(IERC20(NECT).allowance(address(adapter), ALM), 0);
  }
}
