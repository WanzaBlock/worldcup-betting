// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/WorldCupBetting.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockReputationSystem {
    mapping(address => uint256) public reputation;
    mapping(address => uint256) public correctCount;
    mapping(address => uint256) public totalCount;

    function updateReputation(address user, bool correct) external {
        totalCount[user]++;
        if (correct) {
            correctCount[user]++;
            reputation[user] += 10;
        }
    }

    function getReputation(address user) external view returns (uint256) {
        return reputation[user];
    }
}

// Malicious contract to test reentrancy guard
contract ReentrancyAttacker {
    WorldCupBetting public target;
    uint256 public betId;
    bool public attacking;

    constructor(address _target) {
        target = WorldCupBetting(payable(_target));
    }

    function attack(uint256 _marketId, uint256 _outcomeIndex) external payable {
        betId = target.placeBet{value: msg.value}(
            _marketId,
            _outcomeIndex,
            0,
            0
        );
    }

    function claimAttack() external {
        attacking = true;
        target.claimWinnings(betId);
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            // Attempt reentrant claim — should revert
            target.claimWinnings(betId);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main test suite
// ─────────────────────────────────────────────────────────────────────────────

contract WorldCupBettingTest is Test {

    receive() external payable {}
    WorldCupBetting public betting;
    MockReputationSystem public reputation;
    MockERC20 public token;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public arbitrator = makeAddr("arbitrator");

    string[] outcomes;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        reputation = new MockReputationSystem();
        betting = new WorldCupBetting(address(reputation));
        token = new MockERC20();

        outcomes.push("Brazil");
        outcomes.push("Draw");
        outcomes.push("Serbia");

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);

        token.mint(alice, 1_000e18);
        token.mint(bob, 1_000e18);
        token.mint(carol, 1_000e18);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _createETHMarket() internal returns (uint256 marketId) {
        marketId = betting.createMarket(
            "Brazil vs Serbia",
            "FIFA World Cup Group Stage",
            outcomes,
            block.timestamp + 1 days,
            arbitrator,
            address(0)
        );
    }

    function _createERC20Market() internal returns (uint256 marketId) {
        marketId = betting.createMarket(
            "Brazil vs Serbia ERC20",
            "FIFA World Cup Group Stage",
            outcomes,
            block.timestamp + 1 days,
            arbitrator,
            address(token)
        );
    }

    function _resolveMarket(uint256 marketId, uint256 winningOutcome) internal {
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(arbitrator);
        betting.resolveMarket(marketId, winningOutcome);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 1. Market Creation
    // ═════════════════════════════════════════════════════════════════════════

    function test_createMarket_incrementsMarketCount() public {
        assertEq(betting.marketCount(), 0);
        _createETHMarket();
        assertEq(betting.marketCount(), 1);
    }

    function test_createMarket_storesCorrectData() public {
        uint256 resolutionTime = block.timestamp + 1 days;
        uint256 marketId = betting.createMarket(
            "Brazil vs Serbia",
            "Group stage match",
            outcomes,
            resolutionTime,
            arbitrator,
            address(0)
        );

        (
            uint256 id,
            string memory description,
            ,
            string[] memory _outcomes,
            uint256 _resolutionTime,
            address _arbitrator,
            address tokenAddress,
            WorldCupBetting.MarketStatus status,
            ,
            address creator
        ) = betting.getMarket(marketId);

        assertEq(id, marketId);
        assertEq(description, "Brazil vs Serbia");
        assertEq(_resolutionTime, resolutionTime);
        assertEq(_arbitrator, arbitrator);
        assertEq(tokenAddress, address(0));
        assertEq(creator, address(this));
        assertEq(_outcomes.length, 3);
        assertEq(uint8(status), uint8(WorldCupBetting.MarketStatus.Open));
    }

    function test_createMarket_anyoneCanCreate() public {
        vm.prank(alice);
        uint256 marketId = _createETHMarket();
        (, , , , , , , , , address creator) = betting.getMarket(marketId);
        assertEq(creator, alice);
    }

    function test_createMarket_multipleMarkets() public {
        uint256 id1 = _createETHMarket();
        uint256 id2 = _createETHMarket();
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(betting.marketCount(), 2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 2. Place Bet — ETH
    // ═════════════════════════════════════════════════════════════════════════

    function test_placeBet_ETH_success() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        assertEq(betId, 1);
        assertEq(betting.betCount(), 1);
        assertEq(betting.getTotalPool(marketId), 1 ether);
    }

    function test_placeBet_ETH_updatesOutcomePool() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(bob);
        betting.placeBet{value: 2 ether}(marketId, 1, 0, 0);

        assertEq(betting.getTotalPool(marketId), 3 ether);
        // Price of outcome 0 = 1/3 of pool
        assertEq(betting.getPrice(marketId, 0), uint256(1e18) / 3);
    }

    function test_placeBet_ETH_tracksUserBets() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        uint256[] memory aliceBets = betting.getUserBets(alice);
        assertEq(aliceBets.length, 1);
        assertEq(aliceBets[0], 1);
    }

    function test_placeBet_ETH_tracksMarketBets() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);
        vm.prank(bob);
        betting.placeBet{value: 2 ether}(marketId, 1, 0, 0);

        uint256[] memory marketBets = betting.getMarketBets(marketId);
        assertEq(marketBets.length, 2);
    }

    function test_placeBet_revertsAfterResolutionTime() public {
        uint256 marketId = _createETHMarket();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(alice);
        vm.expectRevert("Market closed");
        betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);
    }

    function test_placeBet_revertsInvalidOutcome() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        vm.expectRevert("Invalid outcome");
        betting.placeBet{value: 1 ether}(marketId, 99, 0, 0);
    }

    function test_placeBet_revertsSlippageExceeded() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        vm.expectRevert("Slippage exceeded");
        // minShares = 2 ether but only sending 1 ether (1:1 ratio)
        betting.placeBet{value: 1 ether}(marketId, 0, 0, 2 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 3. Place Bet — ERC20
    // ═════════════════════════════════════════════════════════════════════════

    function test_placeBet_ERC20_success() public {
        uint256 marketId = _createERC20Market();

        vm.startPrank(alice);
        token.approve(address(betting), 100e18);
        uint256 betId = betting.placeBet(marketId, 0, 100e18, 0);
        vm.stopPrank();

        assertEq(betId, 1);
        assertEq(betting.getTotalPool(marketId), 100e18);
        assertEq(token.balanceOf(address(betting)), 100e18);
    }

    function test_placeBet_ERC20_multipleUsers() public {
        uint256 marketId = _createERC20Market();

        vm.startPrank(alice);
        token.approve(address(betting), 300e18);
        betting.placeBet(marketId, 0, 100e18, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(betting), 300e18);
        betting.placeBet(marketId, 1, 200e18, 0);
        vm.stopPrank();

        assertEq(betting.getTotalPool(marketId), 300e18);
        // Alice has 1/3 of pool
        assertEq(betting.getPrice(marketId, 0), uint256(1e18) / 3);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 4. Resolve Market
    // ═════════════════════════════════════════════════════════════════════════

    function test_resolveMarket_success() public {
        uint256 marketId = _createETHMarket();
        _resolveMarket(marketId, 0);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            WorldCupBetting.MarketStatus status,
            uint256 winningOutcome,

        ) = betting.getMarket(marketId);

        assertEq(uint8(status), uint8(WorldCupBetting.MarketStatus.Resolved));
        assertEq(winningOutcome, 0);
    }

    function test_resolveMarket_revertsTooEarly() public {
        uint256 marketId = _createETHMarket();

        vm.prank(arbitrator);
        vm.expectRevert("Too early");
        betting.resolveMarket(marketId, 0);
    }

    function test_resolveMarket_revertsNonArbitrator() public {
        uint256 marketId = _createETHMarket();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(alice);
        vm.expectRevert("Only arbitrator");
        betting.resolveMarket(marketId, 0);
    }

    function test_resolveMarket_revertsInvalidOutcome() public {
        uint256 marketId = _createETHMarket();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(arbitrator);
        vm.expectRevert("Invalid outcome");
        betting.resolveMarket(marketId, 99);
    }

    function test_resolveMarket_revertsDoubleResolve() public {
        uint256 marketId = _createETHMarket();
        _resolveMarket(marketId, 0);

        vm.prank(arbitrator);
        vm.expectRevert("Market already resolved");
        betting.resolveMarket(marketId, 1);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 5. Claim Winnings — ETH
    // ═════════════════════════════════════════════════════════════════════════

    function test_claimWinnings_ETH_winnerReceivesPayout() public {
        uint256 marketId = _createETHMarket();

        // Alice bets 1 ETH on outcome 0 (Brazil)
        vm.prank(alice);
        uint256 aliceBetId = betting.placeBet{value: 1 ether}(
            marketId,
            0,
            0,
            0
        );

        // Bob bets 1 ETH on outcome 1 (Draw) — loser
        vm.prank(bob);
        betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        // Resolve: outcome 0 wins
        _resolveMarket(marketId, 0);

        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        betting.claimWinnings(aliceBetId);

        uint256 aliceBalanceAfter = alice.balance;

        // Total pool = 2 ETH. Alice holds all winning pool (1 ETH).
        // Gross payout = (1/1) * 2 = 2 ETH.
        // 2% fee = 0.04 ETH. Net = 1.96 ETH.
        uint256 expectedNet = 2 ether - ((2 ether * 200) / 10_000);
        assertEq(aliceBalanceAfter - aliceBalanceBefore, expectedNet);
    }

    function test_claimWinnings_ETH_loserReceivesNothing() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(bob);
        uint256 bobBetId = betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        _resolveMarket(marketId, 0); // outcome 0 wins; bob loses

        uint256 bobBalanceBefore = bob.balance;

        vm.prank(bob);
        betting.claimWinnings(bobBetId);

        assertEq(bob.balance, bobBalanceBefore); // no ETH received
    }

    function test_claimWinnings_fee_accrues() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 aliceBetId = betting.placeBet{value: 1 ether}(
            marketId,
            0,
            0,
            0
        );
        vm.prank(bob);
        betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        _resolveMarket(marketId, 0);

        vm.prank(alice);
        betting.claimWinnings(aliceBetId);

        // 2% of 2 ETH gross payout
        uint256 expectedFee = (2 ether * 200) / 10_000;
        assertEq(betting.getAvailableFees(address(0)), expectedFee);
    }

    function test_claimWinnings_revertsDoubleClaim() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);
        vm.prank(bob);
        betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        _resolveMarket(marketId, 0);

        vm.prank(alice);
        betting.claimWinnings(betId);

        vm.prank(alice);
        vm.expectRevert("Already claimed");
        betting.claimWinnings(betId);
    }

    function test_claimWinnings_revertsNotOwner() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        _resolveMarket(marketId, 0);

        vm.prank(bob);
        vm.expectRevert("Not owner");
        betting.claimWinnings(betId);
    }

    function test_claimWinnings_revertsMarketNotResolved() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(alice);
        vm.expectRevert("Not resolved");
        betting.claimWinnings(betId);
    }

    function test_claimWinnings_updatesReputation() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 aliceBetId = betting.placeBet{value: 1 ether}(
            marketId,
            0,
            0,
            0
        );
        vm.prank(bob);
        uint256 bobBetId = betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        _resolveMarket(marketId, 0);

        vm.prank(alice);
        betting.claimWinnings(aliceBetId);
        vm.prank(bob);
        betting.claimWinnings(bobBetId);

        // Alice won → reputation increased
        assertGt(reputation.reputation(alice), 0);
        // Bob lost → no reputation gain
        assertEq(reputation.reputation(bob), 0);
    }

    function test_claimWinnings_ERC20_winner() public {
        uint256 marketId = _createERC20Market();

        vm.startPrank(alice);
        token.approve(address(betting), 100e18);
        uint256 aliceBetId = betting.placeBet(marketId, 0, 100e18, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(betting), 100e18);
        betting.placeBet(marketId, 1, 100e18, 0);
        vm.stopPrank();

        _resolveMarket(marketId, 0);

        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.prank(alice);
        betting.claimWinnings(aliceBetId);

        uint256 grossPayout = 200e18;
        uint256 fee = (grossPayout * 200) / 10_000;
        uint256 expectedNet = grossPayout - fee;

        assertEq(token.balanceOf(alice) - aliceBalBefore, expectedNet);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 6. Secondary Market
    // ═════════════════════════════════════════════════════════════════════════

    function test_listPosition_success() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(alice);
        betting.listPosition(betId, 1.5 ether);
    }

    function test_listPosition_revertsNotOwner() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(bob);
        vm.expectRevert("Not owner");
        betting.listPosition(betId, 1.5 ether);
    }

    function test_listPosition_revertsAlreadyListed() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(alice);
        betting.listPosition(betId, 1.5 ether);

        vm.prank(alice);
        vm.expectRevert("Already listed");
        betting.listPosition(betId, 2 ether);
    }

    function test_cancelListing_success() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(alice);
        betting.listPosition(betId, 1.5 ether);

        vm.prank(alice);
        betting.cancelListing(betId);
    }

    function test_cancelListing_revertsNotListed() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(alice);
        vm.expectRevert("Not listed");
        betting.cancelListing(betId);
    }

    function test_buyPosition_ETH_success() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(alice);
        betting.listPosition(betId, 1.5 ether);

        uint256 aliceBalBefore = alice.balance;

        vm.prank(bob);
        betting.buyPosition{value: 1.5 ether}(betId);

        // Bob now owns the bet
        uint256[] memory bobBets = betting.getUserBets(bob);
        assertEq(bobBets.length, 1);
        assertEq(bobBets[0], betId);

        // Alice received 1.5 ETH
        assertEq(alice.balance - aliceBalBefore, 1.5 ether);
    }

    function test_buyPosition_revertsWrongETHAmount() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(alice);
        betting.listPosition(betId, 1.5 ether);

        vm.prank(bob);
        vm.expectRevert("Wrong ETH amount");
        betting.buyPosition{value: 1 ether}(betId);
    }

    function test_buyPosition_revertsOwnListing() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(alice);
        betting.listPosition(betId, 1.5 ether);

        vm.prank(alice);
        vm.expectRevert("Cannot buy own listing");
        betting.buyPosition{value: 1.5 ether}(betId);
    }

    function test_buyPosition_revertsNotListed() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);

        vm.prank(bob);
        vm.expectRevert("Not listed");
        betting.buyPosition{value: 1 ether}(betId);
    }

    function test_claimWinnings_revertsPositionListed() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);
        vm.prank(bob);
        betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        vm.prank(alice);
        betting.listPosition(betId, 1.5 ether);

        _resolveMarket(marketId, 0);

        vm.prank(alice);
        vm.expectRevert("Position is listed");
        betting.claimWinnings(betId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 7. Fee Withdrawal
    // ═════════════════════════════════════════════════════════════════════════

    function test_withdrawFees_ETH_success() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);
        vm.prank(bob);
        betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        _resolveMarket(marketId, 0);

        vm.prank(alice);
        betting.claimWinnings(betId);

        uint256 fees = betting.getAvailableFees(address(0));
        assertGt(fees, 0);

        uint256 ownerBalBefore = owner.balance;
        betting.withdrawFees(address(0));

        assertEq(owner.balance - ownerBalBefore, fees);
        assertEq(betting.getAvailableFees(address(0)), 0);
    }

    function test_withdrawFees_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        betting.withdrawFees(address(0));
    }

    function test_withdrawFees_revertsNoFees() public {
        vm.expectRevert("No fees");
        betting.withdrawFees(address(0));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 8. View Functions
    // ═════════════════════════════════════════════════════════════════════════

    function test_getPrice_returnsZeroOnEmptyPool() public {
        uint256 marketId = _createETHMarket();
        assertEq(betting.getPrice(marketId, 0), 0);
    }

    function test_getPrice_returnsCorrectImpliedProbability() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        betting.placeBet{value: 3 ether}(marketId, 0, 0, 0);
        vm.prank(bob);
        betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        // Outcome 0 has 3/4 of pool = 0.75e18
        assertEq(betting.getPrice(marketId, 0), 0.75e18);
        // Outcome 1 has 1/4 of pool = 0.25e18
        assertEq(betting.getPrice(marketId, 1), 0.25e18);
    }

    function test_calculateShares_isOneToOne() public view {
        assertEq(betting.calculateShares(1, 0, 1 ether), 1 ether);
        assertEq(betting.calculateShares(1, 0, 500e18), 500e18);
    }

    function test_getTotalPool_accumulatesCorrectly() public {
        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);
        vm.prank(bob);
        betting.placeBet{value: 2 ether}(marketId, 1, 0, 0);
        vm.prank(carol);
        betting.placeBet{value: 3 ether}(marketId, 2, 0, 0);

        assertEq(betting.getTotalPool(marketId), 6 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 9. Multi-bettor payout fairness
    // ═════════════════════════════════════════════════════════════════════════

    function test_multiWinner_payoutProportional() public {
        uint256 marketId = _createETHMarket();

        // Alice and Carol both bet on outcome 0 (winner)
        vm.prank(alice);
        uint256 aliceBet = betting.placeBet{value: 1 ether}(marketId, 0, 0, 0);
        vm.prank(carol);
        uint256 carolBet = betting.placeBet{value: 3 ether}(marketId, 0, 0, 0);

        // Bob bets on outcome 1 (loser)
        vm.prank(bob);
        betting.placeBet{value: 4 ether}(marketId, 1, 0, 0);

        _resolveMarket(marketId, 0);

        uint256 aliceBefore = alice.balance;
        uint256 carolBefore = carol.balance;

        vm.prank(alice);
        betting.claimWinnings(aliceBet);
        vm.prank(carol);
        betting.claimWinnings(carolBet);

        uint256 aliceGain = alice.balance - aliceBefore;
        uint256 carolGain = carol.balance - carolBefore;

        // Carol staked 3x Alice, so gains ~3x (within fee rounding)
        assertApproxEqRel(carolGain, aliceGain * 3, 1e15); // 0.1% tolerance
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 10. Reentrancy Guard
    // ═════════════════════════════════════════════════════════════════════════

    function test_reentrancy_claimWinnings_protected() public {
        uint256 marketId = _createETHMarket();

        ReentrancyAttacker attacker = new ReentrancyAttacker(address(betting));
        vm.deal(address(attacker), 10 ether);

        attacker.attack{value: 1 ether}(marketId, 0);

        // Bob loses so attacker's outcome wins
        vm.prank(bob);
        betting.placeBet{value: 1 ether}(marketId, 1, 0, 0);

        _resolveMarket(marketId, 0);

        // Reentrancy attempt should revert
        vm.expectRevert();
        attacker.claimAttack();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 11. Fuzz Tests
    // ═════════════════════════════════════════════════════════════════════════

    function testFuzz_placeBet_ETH_anyAmount(uint256 amount) public {
        amount = bound(amount, 1 wei, 50 ether);
        vm.deal(alice, amount);

        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        uint256 betId = betting.placeBet{value: amount}(marketId, 0, 0, 0);

        assertEq(betId, 1);
        assertEq(betting.getTotalPool(marketId), amount);
    }

    function testFuzz_getPrice_sumToOne(
        uint256 a,
        uint256 b,
        uint256 c
    ) public {
        a = bound(a, 1 ether, 10 ether);
        b = bound(b, 1 ether, 10 ether);
        c = bound(c, 1 ether, 10 ether);

        vm.deal(alice, a);
        vm.deal(bob, b);
        vm.deal(carol, c);

        uint256 marketId = _createETHMarket();

        vm.prank(alice);
        betting.placeBet{value: a}(marketId, 0, 0, 0);
        vm.prank(bob);
        betting.placeBet{value: b}(marketId, 1, 0, 0);
        vm.prank(carol);
        betting.placeBet{value: c}(marketId, 2, 0, 0);

        uint256 p0 = betting.getPrice(marketId, 0);
        uint256 p1 = betting.getPrice(marketId, 1);
        uint256 p2 = betting.getPrice(marketId, 2);

        // Prices should sum to 1e18 (within 1 wei rounding)
        assertApproxEqAbs(p0 + p1 + p2, 1e18, 2);
    }
}
