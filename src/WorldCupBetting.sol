// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
    function getReputation(address user) external view returns (uint256);
}

/**
 * @title WorldCupBetting
 * @notice Parimutuel prediction market supporting ETH and ERC20 collateral,
 *         a secondary position market, and a 2% platform fee on winning payouts.
 */
contract WorldCupBetting is ReentrancyGuard, Ownable {

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    enum MarketStatus {
        Open,
        Closed,
        Resolved,
        Cancelled
    }

    /// @dev Mappings cannot live inside a struct that is copied to memory,
    ///      so outcomePool is kept in a separate top-level mapping keyed by
    ///      (marketId, outcomeIndex).
    struct Market {
        string      description;
        string      details;
        string[]    outcomes;
        uint256     resolutionTime;
        address     arbitrator;
        address     tokenAddress;   // address(0) = native ETH
        MarketStatus status;
        uint256     winningOutcome;
        address     creator;
        uint256     totalPool;
    }

    struct Bet {
        uint256  marketId;
        uint256  outcomeIndex;
        uint256  amount;       // collateral deposited (= shares 1 : 1)
        address  owner;
        bool     claimed;
        bool     listed;
        uint256  listPrice;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    IReputationSystem public reputationSystem;

    uint256 public marketCount;
    uint256 public betCount;

    mapping(uint256 => Market)  private _markets;
    mapping(uint256 => Bet)     private _bets;

    /// @dev Total collateral wagered on each outcome per market.
    mapping(uint256 => mapping(uint256 => uint256)) private _outcomePool;

    /// @dev Ordered list of bet IDs placed in a market.
    mapping(uint256 => uint256[]) private _marketBetIds;

    /// @dev All bet IDs ever associated with an address (including bought positions).
    mapping(address => uint256[]) private _userBetIds;

    /// @dev Accrued platform fees per collateral token (address(0) = ETH).
    mapping(address => uint256) private _availableFees;

    uint256 private constant FEE_BPS        = 200;    // 2 %
    uint256 private constant BPS_DENOM      = 10_000;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _reputationSystem) Ownable(msg.sender) {
        reputationSystem = IReputationSystem(_reputationSystem);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Market lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new prediction market.
     * @param _description  Human-readable question.
     * @param _details      Extra context / resolution criteria.
     * @param _outcomes     Array of outcome labels (e.g. ["Brazil","Draw","Serbia"]).
     * @param _resolutionTime  Unix timestamp after which the market may be resolved.
     * @param _arbitrator   Address allowed to call resolveMarket.
     * @param _tokenAddress ERC20 collateral; use address(0) for native ETH.
     * @return marketId     The new market's ID (1-indexed, equals marketCount after call).
     */
    function createMarket(
        string memory  _description,
        string memory  _details,
        string[] memory _outcomes,
        uint256        _resolutionTime,
        address        _arbitrator,
        address        _tokenAddress
    ) external returns (uint256) {
        marketCount++;
        uint256 marketId = marketCount;

        Market storage m = _markets[marketId];
        m.description    = _description;
        m.details        = _details;
        m.outcomes       = _outcomes;
        m.resolutionTime = _resolutionTime;
        m.arbitrator     = _arbitrator;
        m.tokenAddress   = _tokenAddress;
        m.status         = MarketStatus.Open;
        m.creator        = msg.sender;

        return marketId;
    }

    /**
     * @notice Place a bet on an outcome.
     * @param _marketId     Target market.
     * @param _outcomeIndex Index into the market's outcomes array.
     * @param _amount       Collateral to stake (ignored for ETH markets — use msg.value).
     * @param _minShares    Minimum shares expected; reverts with "Slippage exceeded" if not met.
     * @return betId        Unique ID for this bet position.
     */
    function placeBet(
        uint256 _marketId,
        uint256 _outcomeIndex,
        uint256 _amount,
        uint256 _minShares
    ) external payable nonReentrant returns (uint256) {
        Market storage m = _markets[_marketId];

        require(block.timestamp < m.resolutionTime, "Market closed");
        require(m.status == MarketStatus.Open,      "Market closed");
        require(_outcomeIndex < m.outcomes.length,  "Invalid outcome");

        // ── Pull collateral ──────────────────────────────────────────────────
        uint256 amount;
        if (m.tokenAddress == address(0)) {
            amount = msg.value;
        } else {
            amount = _amount;
            IERC20(m.tokenAddress).transferFrom(msg.sender, address(this), amount);
        }

        // ── Slippage guard ───────────────────────────────────────────────────
        // Shares are 1:1 with collateral in this parimutuel design.
        uint256 shares = calculateShares(_marketId, _outcomeIndex, amount);
        require(shares >= _minShares, "Slippage exceeded");

        // ── Accounting ───────────────────────────────────────────────────────
        _outcomePool[_marketId][_outcomeIndex] += amount;
        m.totalPool += amount;

        betCount++;
        uint256 betId = betCount;

        _bets[betId] = Bet({
            marketId:     _marketId,
            outcomeIndex: _outcomeIndex,
            amount:       amount,
            owner:        msg.sender,
            claimed:      false,
            listed:       false,
            listPrice:    0
        });

        _marketBetIds[_marketId].push(betId);
        _userBetIds[msg.sender].push(betId);

        return betId;
    }

    /**
     * @notice Resolve a market.  Only callable by the market's arbitrator after
     *         resolutionTime has passed.
     * @param _marketId      Target market.
     * @param _winningOutcome Index of the correct outcome.
     */
    function resolveMarket(uint256 _marketId, uint256 _winningOutcome) external {
        Market storage m = _markets[_marketId];

        require(block.timestamp >= m.resolutionTime, "Too early");
        require(msg.sender == m.arbitrator,          "Only arbitrator");
        require(m.status == MarketStatus.Open,       "Market already resolved");
        require(_winningOutcome < m.outcomes.length, "Invalid outcome");

        m.status         = MarketStatus.Resolved;
        m.winningOutcome = _winningOutcome;
    }

    /**
     * @notice Claim winnings (or settle a loss) for a specific bet.
     *         Winners receive their proportional share of the total pool minus
     *         the 2% platform fee.  Losers receive nothing but the call is still
     *         valid so reputation can be recorded.  Cannot be called twice.
     * @param _betId  The bet position to settle.
     */
    function claimWinnings(uint256 _betId) external nonReentrant {
        Bet storage bet = _bets[_betId];

        require(bet.owner == msg.sender, "Not owner");
        require(!bet.claimed,            "Already claimed");
        require(!bet.listed,             "Position is listed");

        Market storage m = _markets[bet.marketId];
        require(m.status == MarketStatus.Resolved, "Not resolved");

        bet.claimed = true;

        bool won = (bet.outcomeIndex == m.winningOutcome);

        // Update on-chain reputation regardless of outcome.
        try reputationSystem.updateReputation(msg.sender, won) {} catch {}

        if (won) {
            // Gross payout = bettor's share of the entire pool.
            uint256 winningPool = _outcomePool[bet.marketId][m.winningOutcome];
            uint256 grossPayout = (bet.amount * m.totalPool) / winningPool;

            // 2% platform fee on the winning payout path.
            uint256 fee        = (grossPayout * FEE_BPS) / BPS_DENOM;
            uint256 netPayout  = grossPayout - fee;

            _availableFees[m.tokenAddress] += fee;

            _transfer(m.tokenAddress, msg.sender, netPayout);
        }
        // Losers: function returns normally; no ETH/ERC20 transfer.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Secondary market
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice List a bet position for sale.
     * @param _betId  Bet to list; must be owned by msg.sender.
     * @param _price  Ask price in the market's collateral token.
     */
    function listPosition(uint256 _betId, uint256 _price) external {
        Bet storage bet = _bets[_betId];

        require(bet.owner == msg.sender, "Not owner");
        require(!bet.claimed,            "Already claimed");
        require(!bet.listed,             "Already listed");

        Market storage m = _markets[bet.marketId];
        require(m.status == MarketStatus.Open, "Market closed");

        bet.listed    = true;
        bet.listPrice = _price;
    }

    /**
     * @notice Cancel an active listing and reclaim ownership.
     * @param _betId  The listed bet to cancel.
     */
    function cancelListing(uint256 _betId) external {
        Bet storage bet = _bets[_betId];

        require(bet.owner == msg.sender, "Not owner");
        require(bet.listed,              "Not listed");

        bet.listed    = false;
        bet.listPrice = 0;
    }

    /**
     * @notice Buy a listed position.  Ownership of the bet transfers to the
     *         buyer; the seller receives the list price immediately.
     * @param _betId  The listed bet to purchase.
     */
    function buyPosition(uint256 _betId) external payable nonReentrant {
        Bet storage bet = _bets[_betId];

        require(bet.listed,              "Not listed");
        require(bet.owner != msg.sender, "Cannot buy own listing");

        Market storage m = _markets[bet.marketId];
        require(m.status == MarketStatus.Open, "Market closed");

        address seller = bet.owner;
        uint256 price  = bet.listPrice;

        // Transfer ownership before external calls (CEI pattern).
        bet.listed    = false;
        bet.listPrice = 0;
        bet.owner     = msg.sender;

        _userBetIds[msg.sender].push(_betId);

        // Pay seller.
        if (m.tokenAddress == address(0)) {
            require(msg.value == price, "Wrong ETH amount");
            (bool ok, ) = seller.call{value: price}("");
            require(ok, "Transfer failed");
        } else {
            IERC20(m.tokenAddress).transferFrom(msg.sender, seller, price);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fee management
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw all accrued platform fees for a given collateral token.
     * @param _tokenAddress address(0) for ETH; otherwise the ERC20 contract.
     */
    function withdrawFees(address _tokenAddress) external onlyOwner nonReentrant {
        uint256 amount = _availableFees[_tokenAddress];
        require(amount > 0, "No fees");

        _availableFees[_tokenAddress] = 0;

        _transfer(_tokenAddress, owner(), amount);
    }

    /**
     * @notice Returns the platform fees available to withdraw for a token.
     */
    function getAvailableFees(address _tokenAddress) external view returns (uint256) {
        return _availableFees[_tokenAddress];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Shares received for a given deposit.
     *         This implementation uses a 1:1 mapping (shares = amount).
     */
    function calculateShares(
        uint256 /* _marketId */,
        uint256 /* _outcomeIndex */,
        uint256 _amount
    ) public pure returns (uint256) {
        return _amount;
    }

    /**
     * @notice Implied probability of an outcome expressed as a WAD (1e18 = 100%).
     *         Returns 0 if the pool is empty.
     */
    function getPrice(uint256 _marketId, uint256 _outcomeIndex) public view returns (uint256) {
        uint256 total = _markets[_marketId].totalPool;
        if (total == 0) return 0;
        return (_outcomePool[_marketId][_outcomeIndex] * 1e18) / total;
    }

    /**
     * @notice Total collateral locked in a market.
     */
    function getTotalPool(uint256 _marketId) public view returns (uint256) {
        return _markets[_marketId].totalPool;
    }

    /**
     * @notice All bet IDs ever associated with a user (includes bought positions).
     */
    function getUserBets(address _user) external view returns (uint256[] memory) {
        return _userBetIds[_user];
    }

    /**
     * @notice All bet IDs placed in a market, in placement order.
     */
    function getMarketBets(uint256 _marketId) external view returns (uint256[] memory) {
        return _marketBetIds[_marketId];
    }

    /**
     * @notice Full market data.
     * @dev    Return values are named so ethers.js can access them as properties
     *         (e.g. `m.status`).
     */
    function getMarket(uint256 _marketId)
        external
        view
        returns (
            uint256      id,
            string memory description,
            string memory details,
            string[] memory outcomes,
            uint256      resolutionTime,
            address      arbitrator,
            address      tokenAddress,
            MarketStatus status,
            uint256      winningOutcome,
            address      creator
        )
    {
        Market storage m = _markets[_marketId];
        return (
            _marketId,
            m.description,
            m.details,
            m.outcomes,
            m.resolutionTime,
            m.arbitrator,
            m.tokenAddress,
            m.status,
            m.winningOutcome,
            m.creator
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _transfer(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(token).transfer(to, amount);
        }
    }

    receive() external payable {}
}
