// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/everlong-psm/EverlongPsmAdapter.sol';

interface IPsmAdmin {
  function metaCore() external view returns (address);
  function setMintCap(address stable, uint256 mintCap) external;
  function setCapHook(address capHook) external;
  function previewDeposit(address stable, uint256 stableAmount, uint16 maxFeePercentage)
    external
    view
    returns (uint256 mintedDebtToken, uint256 debtTokenFee);
  function previewRedeem(address stable, uint256 debtTokenAmount, uint16 maxFeePercentage)
    external
    view
    returns (uint256 stableAmount, uint256 stableFee);
}

interface IMetaCoreOwner {
  function owner() external view returns (address);
}

interface INectMinters {
  function PSMBonds(address) external view returns (bool);
}

/// Cap hook binding tighter than the PSM's own ceilings, per side.
contract TightCapHook {
  uint256 public immutable ceiling;
  uint256 public immutable exitCeiling;
  uint256 public immutable outflowCeiling;

  constructor(uint256 _ceiling, uint256 _exitCeiling) {
    ceiling = _ceiling;
    exitCeiling = _exitCeiling;
    outflowCeiling = type(uint256).max;
  }

  function maxMint(address) external view returns (uint256) {
    return ceiling;
  }

  function maxRedeem(address) external view returns (uint256) {
    return exitCeiling;
  }

  function getMaxPsmOutflow(address, address, bool) external view returns (uint256) {
    return outflowCeiling;
  }

  function onPSMDeposit(address, uint256) external {}
  function onPSMWithdraw(address, uint256) external {}
}

/// Cap hook binding only the per-caller stable outflow, leaving the burn ceiling open.
contract OutflowCapHook {
  uint256 public immutable outflow;

  constructor(uint256 _outflow) {
    outflow = _outflow;
  }

  function maxMint(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function maxRedeem(address) external pure returns (uint256) {
    return type(uint256).max;
  }

  function getMaxPsmOutflow(address, address, bool) external view returns (uint256) {
    return outflow;
  }

  function onPSMDeposit(address, uint256) external {}
  function onPSMWithdraw(address, uint256) external {}
}

/// Fork tests against the live Berachain PermissionlessPSM (NECT/HONEY, both 18d).
/// Each test sets its own capacity so assertions survive re-tuning of the deployment.
contract EverlongPsmAdapterTest is Test {
  using stdStorage for StdStorage;

  address constant PSM = 0x0999417c0f9ded4356B099bcC83A16437B841323;
  address constant NECT = 0x1cE0a25D13CE4d52071aE7e02Cf1F6606F4C79d3; // debt token, 18d
  address constant HONEY = 0xFCBD14DC51f0A4d49d5E53C2E0950e0bC26d0Dce; // stable, 18d

  string RPC_URL = vm.envOr('RPC_80094', string('https://berachain.drpc.org'));
  /// @dev Every unpinned fork is pinned here: one block keeps the suite deterministic and
  /// lets forge cache the RPC reads, which the public endpoint's rate limit needs.
  uint256 constant PINNED_BLOCK = 25_107_939;

  EverlongPsmAdapter adapter;
  address recipient = makeAddr('recipient');
  address owner;

  function setUp() public {
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    adapter = new EverlongPsmAdapter();
    owner = IMetaCoreOwner(IPsmAdmin(PSM).metaCore()).owner();

    // NECT only lets whitelisted PSM bonds mint or burn; the grant is live on-chain.
    assertTrue(INectMinters(NECT).PSMBonds(PSM), 'PSM lost its NECT mint/burn grant');
  }

  function _data() internal pure returns (bytes memory) {
    return abi.encode(PSM, NECT);
  }

  /// @dev Argument resolved before the prank — a call in the list would consume it.
  function _openMintRoom(uint256 room) internal {
    uint256 cap = IPermissionlessPSM(PSM).debtTokenMinted(HONEY) + room;
    vm.prank(owner);
    IPsmAdmin(PSM).setMintCap(HONEY, cap);
  }

  /// @dev stable -> debt at par minus the entry toll.
  function test_depositMatchesPreview() public {
    _openMintRoom(1000e18);
    uint256 amountIn = 100e18;
    deal(HONEY, address(adapter), amountIn);

    (uint256 expectedOut,) = IPsmAdmin(PSM).previewDeposit(HONEY, amountIn, type(uint16).max);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongPsm(_data(), amountIn, HONEY, NECT, recipient);

    assertEq(amountOut, expectedOut, 'deposit out must match the venue preview');
    assertEq(amountUnused, 0, 'nothing to return inside the mint room');
    assertEq(IERC20(NECT).balanceOf(recipient), amountOut, 'recipient must receive the debt token');
  }

  /// @dev Regression: clamping on `mintCap` alone overshoots a tighter hook ceiling and
  /// reverts PassedMintCap instead of partial-filling.
  function test_depositClampsToCapHookCeilingNotMintCap() public {
    _openMintRoom(1000e18);
    uint256 hookCeiling = IPermissionlessPSM(PSM).debtTokenMinted(HONEY) + 40e18;
    address hook = address(new TightCapHook(hookCeiling, type(uint256).max));
    vm.prank(owner);
    IPsmAdmin(PSM).setCapHook(hook);

    uint256 room = IPermissionlessPSM(PSM).availableMint(HONEY);
    assertLt(room, 1000e18, 'the hook must be the binding ceiling for this test to mean anything');

    uint256 amountIn = 100e18; // deliberately past the hook ceiling
    deal(HONEY, address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongPsm(_data(), amountIn, HONEY, NECT, recipient);

    assertGt(amountOut, 0, 'must partial-fill, not revert');
    assertEq(amountUnused, amountIn - room, 'unused must be the input past the hook ceiling');
    assertLe(amountOut, room, 'the fill must fit the ceiling the PSM enforces');
  }

  /// @dev Regression: clamping the burn on `debtTokenMinted` alone ignores the reserve,
  /// so `_payOut` reverts InsufficientReserve once the reserve sits below the book.
  function test_redeemClampsToAvailableReserve() public {
    _openMintRoom(1000e18);
    deal(HONEY, address(adapter), 200e18);
    (, uint256 minted) = adapter.executeEverlongPsm(_data(), 200e18, HONEY, NECT, recipient);

    // Strand most of the stable, as a deployed yield hook would.
    uint256 reserve = 30e18;
    deal(HONEY, PSM, reserve);
    assertLt(
      reserve, IPermissionlessPSM(PSM).debtTokenMinted(HONEY), 'reserve must be the binding bound'
    );

    vm.prank(recipient);
    IERC20(NECT).transfer(address(adapter), minted);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongPsm(_data(), minted, NECT, HONEY, recipient);

    assertGt(amountOut, 0, 'must partial-fill against the reserve, not revert');
    assertLe(amountOut, reserve, 'payout cannot exceed what the PSM holds');
    assertEq(
      amountUnused,
      minted - (minted < reserve ? minted : reserve),
      'unused must be the unpayable remainder'
    );
  }

  /// @dev NECT's PSMBonds entry alone decides whether the mint lands; revoking it keeps
  /// that dependency visible if the grant is ever pulled.
  function test_mintBlockedWithoutPsmBondGrant() public {
    _openMintRoom(1000e18);
    deal(HONEY, address(adapter), 100e18);

    stdstore.target(NECT).sig('PSMBonds(address)').with_key(PSM).checked_write(false);
    vm.expectRevert('Debt: Caller not BO/DM');
    adapter.executeEverlongPsm(_data(), 100e18, HONEY, NECT, recipient);

    // Regrant and the identical call goes through — nothing else changed.
    stdstore.target(NECT).sig('PSMBonds(address)').with_key(PSM).checked_write(true);
    (, uint256 amountOut) = adapter.executeEverlongPsm(_data(), 100e18, HONEY, NECT, recipient);
    assertGt(amountOut, 0, 'the PSMBond grant is the only thing gating the mint');
  }

  /// @dev No capacity is a clean refusal, not a revert from inside the venue.
  function test_noCapacityReverts() public {
    _openMintRoom(0);
    deal(HONEY, address(adapter), 100e18);
    vm.expectRevert(EverlongPsmAdapter.EverlongPsmAdapter_NothingToFill.selector);
    adapter.executeEverlongPsm(_data(), 100e18, HONEY, NECT, recipient);
  }

  /// @dev Regression: the redeem clamp ignored the cap hook's exit ceiling, so an
  /// oversized burn was attempted in full and `_bookBurn` reverted PassedOutflowCap.
  function test_redeemClampsToCapHookExitCeiling() public {
    _openMintRoom(1000e18);
    deal(HONEY, address(adapter), 200e18);
    (, uint256 minted) = adapter.executeEverlongPsm(_data(), 200e18, HONEY, NECT, recipient);
    assertGt(minted, 40e18, 'the mint must exceed the ceiling for this test to bind');

    uint256 exitCeiling = 40e18;
    address hook = address(new TightCapHook(type(uint256).max, exitCeiling));
    vm.prank(owner);
    IPsmAdmin(PSM).setCapHook(hook);

    vm.prank(recipient);
    IERC20(NECT).transfer(address(adapter), minted);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEverlongPsm(_data(), minted, NECT, HONEY, recipient);

    assertGt(amountOut, 0, 'must partial-fill to the ceiling, not revert');
    assertEq(amountUnused, minted - exitCeiling, 'burn past the ceiling must stay unused');
  }

  /// @dev The hook's per-caller outflow ceiling is a SECOND exit bound, in stable units,
  /// and reverts PassedOutflowCap just like maxRedeem. Clamping only the burn misses it.
  function test_redeemClampsToCapHookOutflowCeiling() public {
    _openMintRoom(1000e18);
    deal(HONEY, address(adapter), 200e18);
    (, uint256 minted) = adapter.executeEverlongPsm(_data(), 200e18, HONEY, NECT, recipient);

    uint256 outflow = 25e18; // stable units
    address hook = address(new OutflowCapHook(outflow)); // before the prank, or it is consumed
    vm.prank(owner);
    IPsmAdmin(PSM).setCapHook(hook);

    vm.prank(recipient);
    IERC20(NECT).transfer(address(adapter), minted);
    (, uint256 amountOut) = adapter.executeEverlongPsm(_data(), minted, NECT, HONEY, recipient);

    assertGt(amountOut, 0, 'must partial-fill to the outflow ceiling, not revert');
    assertLe(amountOut, outflow, 'stable leaving cannot exceed the per-caller ceiling');
  }

  /// @dev Canonical adapter test: the fuzzed value is the runtime `amountIn`, passed
  /// straight to the entrypoint; past the mint room it partial-fills and the
  /// accounting must close on balances either way.
  function test_executeEverlongPsm(uint256 amountIn) public {
    amountIn = bound(amountIn, 1e12, 100_000_000e18);
    vm.createSelectFork(RPC_URL, PINNED_BLOCK);
    EverlongPsmAdapter psmAdapter = new EverlongPsmAdapter();
    deal(HONEY, address(psmAdapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      psmAdapter.executeEverlongPsm(abi.encode(PSM, NECT), amountIn, HONEY, NECT, recipient);

    assertGt(amountOut, 0);
    assertEq(amountUnused, IERC20(HONEY).balanceOf(address(psmAdapter)));
    assertEq(amountOut, IERC20(NECT).balanceOf(recipient));
  }
}
