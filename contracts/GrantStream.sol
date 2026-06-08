// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GrantStream
 * @author MR SYCO (Sycosmile) — contribution to teethaking/GrantStream
 * @notice On-chain grant escrow with milestone-based fund release.
 *         Funders lock ETH; each tranche is released only when a grantee
 *         submits evidence and the designated verifier approves it.
 *
 * Flow per milestone:
 *   PENDING → (grantee submits evidence) → SUBMITTED
 *           → (verifier approves)         → APPROVED  → funds sent
 *           → (verifier rejects)          → PENDING   → grantee resubmits
 *
 * Cancellation:
 *   Funder may cancel the entire grant while no milestone is SUBMITTED.
 *   All remaining locked funds are returned to the funder.
 */
contract GrantStream {
    // ─── Enums ────────────────────────────────────────────────────────────────

    enum MilestoneStatus {
        PENDING,    // 0 — awaiting grantee submission
        SUBMITTED,  // 1 — evidence submitted, awaiting verifier decision
        APPROVED,   // 2 — verifier approved; funds disbursed
        REJECTED    // 3 — verifier rejected; grantee may resubmit
    }

    enum GrantStatus {
        ACTIVE,    // 0 — in progress
        COMPLETED, // 1 — all milestones paid
        CANCELLED  // 2 — funder cancelled; remaining funds returned
    }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct Milestone {
        string  title;           // human-readable milestone name
        uint256 amount;          // ETH locked for this milestone (wei)
        MilestoneStatus status;
        string  evidenceURI;     // IPFS URI submitted by grantee
        uint256 submittedAt;     // block.timestamp of latest submission
        uint256 paidAt;          // block.timestamp of fund release (0 if unpaid)
    }

    struct Grant {
        uint256   id;
        string    title;
        address   funder;
        address   grantee;
        address   verifier;
        uint256   totalAmount;    // sum of all milestone amounts (wei)
        uint256   releasedAmount; // cumulative amount already paid out
        GrantStatus status;
        uint256   createdAt;
        Milestone[] milestones;
    }

    // ─── Storage ──────────────────────────────────────────────────────────────

    uint256 private _grantCounter;

    /// @dev grantId → Grant
    mapping(uint256 => Grant) private _grants;

    /// @dev funder address → list of grant IDs they created
    mapping(address => uint256[]) private _grantsByFunder;

    /// @dev grantee address → list of grant IDs they are recipient of
    mapping(address => uint256[]) private _grantsByGrantee;

    // ─── Events ───────────────────────────────────────────────────────────────

    event GrantCreated(
        uint256 indexed grantId,
        address indexed funder,
        address indexed grantee,
        address verifier,
        uint256 totalAmount,
        string  title
    );

    event EvidenceSubmitted(
        uint256 indexed grantId,
        uint256 indexed milestoneIndex,
        address indexed grantee,
        string  evidenceURI
    );

    event MilestoneApproved(
        uint256 indexed grantId,
        uint256 indexed milestoneIndex,
        address indexed verifier,
        uint256 amount
    );

    event MilestoneRejected(
        uint256 indexed grantId,
        uint256 indexed milestoneIndex,
        address indexed verifier
    );

    event GrantCancelled(
        uint256 indexed grantId,
        address indexed funder,
        uint256 refundAmount
    );

    event GrantCompleted(uint256 indexed grantId);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error Unauthorized();
    error InvalidGrant();
    error InvalidMilestone();
    error GrantNotActive();
    error MilestoneNotPending();
    error MilestoneNotSubmitted();
    error InsufficientFunds();
    error TransferFailed();
    error CannotCancelWhileSubmitted();
    error ZeroAddress();
    error EmptyTitle();
    error NoMilestones();
    error MilestoneAmountZero();
    error MsgValueMismatch();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyFunder(uint256 grantId) {
        if (_grants[grantId].funder != msg.sender) revert Unauthorized();
        _;
    }

    modifier onlyGrantee(uint256 grantId) {
        if (_grants[grantId].grantee != msg.sender) revert Unauthorized();
        _;
    }

    modifier onlyVerifier(uint256 grantId) {
        if (_grants[grantId].verifier != msg.sender) revert Unauthorized();
        _;
    }

    modifier grantExists(uint256 grantId) {
        if (grantId == 0 || grantId > _grantCounter) revert InvalidGrant();
        _;
    }

    modifier grantIsActive(uint256 grantId) {
        if (_grants[grantId].status != GrantStatus.ACTIVE) revert GrantNotActive();
        _;
    }

    // ─── External: Funder ─────────────────────────────────────────────────────

    /**
     * @notice Create a new grant and lock ETH for all milestones in one tx.
     * @param title       Human-readable grant title.
     * @param grantee     Recipient wallet.
     * @param verifier    Address authorised to approve/reject milestones.
     * @param mTitles     Array of milestone titles.
     * @param mAmounts    Array of milestone amounts (wei); must sum to msg.value.
     */
    function createGrant(
        string calldata title,
        address grantee,
        address verifier,
        string[] calldata mTitles,
        uint256[] calldata mAmounts
    ) external payable returns (uint256 grantId) {
        // ── Validation ────────────────────────────────────────────────────────
        if (grantee  == address(0)) revert ZeroAddress();
        if (verifier == address(0)) revert ZeroAddress();
        if (bytes(title).length == 0) revert EmptyTitle();
        if (mTitles.length == 0) revert NoMilestones();
        if (mTitles.length != mAmounts.length) revert InvalidMilestone();

        uint256 total;
        for (uint256 i; i < mAmounts.length; ++i) {
            if (mAmounts[i] == 0) revert MilestoneAmountZero();
            total += mAmounts[i];
        }
        if (msg.value != total) revert MsgValueMismatch();

        // ── Assign ID ─────────────────────────────────────────────────────────
        grantId = ++_grantCounter;

        Grant storage g = _grants[grantId];
        g.id            = grantId;
        g.title         = title;
        g.funder        = msg.sender;
        g.grantee       = grantee;
        g.verifier      = verifier;
        g.totalAmount   = total;
        g.status        = GrantStatus.ACTIVE;
        g.createdAt     = block.timestamp;

        for (uint256 i; i < mTitles.length; ++i) {
            g.milestones.push(Milestone({
                title       : mTitles[i],
                amount      : mAmounts[i],
                status      : MilestoneStatus.PENDING,
                evidenceURI : "",
                submittedAt : 0,
                paidAt      : 0
            }));
        }

        _grantsByFunder[msg.sender].push(grantId);
        _grantsByGrantee[grantee].push(grantId);

        emit GrantCreated(grantId, msg.sender, grantee, verifier, total, title);
    }

    /**
     * @notice Cancel an active grant and refund all unreleased funds.
     *         Reverts if any milestone is currently in SUBMITTED state
     *         (verifier decision must be made first).
     */
    function cancelGrant(uint256 grantId)
        external
        grantExists(grantId)
        grantIsActive(grantId)
        onlyFunder(grantId)
    {
        Grant storage g = _grants[grantId];

        // Block cancellation while evidence is pending review
        for (uint256 i; i < g.milestones.length; ++i) {
            if (g.milestones[i].status == MilestoneStatus.SUBMITTED) {
                revert CannotCancelWhileSubmitted();
            }
        }

        uint256 refund = g.totalAmount - g.releasedAmount;
        g.status = GrantStatus.CANCELLED;

        emit GrantCancelled(grantId, msg.sender, refund);

        _safeTransfer(msg.sender, refund);
    }

    // ─── External: Grantee ────────────────────────────────────────────────────

    /**
     * @notice Submit an IPFS evidence URI for a specific milestone.
     * @param grantId         ID of the grant.
     * @param milestoneIndex  Zero-based index of the milestone.
     * @param evidenceURI     IPFS URI (e.g. "ipfs://Qm...") pointing to evidence.
     */
    function submitEvidence(
        uint256 grantId,
        uint256 milestoneIndex,
        string calldata evidenceURI
    )
        external
        grantExists(grantId)
        grantIsActive(grantId)
        onlyGrantee(grantId)
    {
        Grant storage g = _grants[grantId];
        if (milestoneIndex >= g.milestones.length) revert InvalidMilestone();

        Milestone storage m = g.milestones[milestoneIndex];

        // Allow submission only from PENDING or REJECTED states
        if (
            m.status != MilestoneStatus.PENDING &&
            m.status != MilestoneStatus.REJECTED
        ) revert MilestoneNotPending();

        m.evidenceURI = evidenceURI;
        m.status      = MilestoneStatus.SUBMITTED;
        m.submittedAt = block.timestamp;

        emit EvidenceSubmitted(grantId, milestoneIndex, msg.sender, evidenceURI);
    }

    // ─── External: Verifier ───────────────────────────────────────────────────

    /**
     * @notice Approve a submitted milestone, releasing its ETH to the grantee.
     */
    function approveMilestone(uint256 grantId, uint256 milestoneIndex)
        external
        grantExists(grantId)
        grantIsActive(grantId)
        onlyVerifier(grantId)
    {
        Grant storage g = _grants[grantId];
        if (milestoneIndex >= g.milestones.length) revert InvalidMilestone();

        Milestone storage m = g.milestones[milestoneIndex];
        if (m.status != MilestoneStatus.SUBMITTED) revert MilestoneNotSubmitted();

        uint256 payout  = m.amount;
        m.status        = MilestoneStatus.APPROVED;
        m.paidAt        = block.timestamp;
        g.releasedAmount += payout;

        emit MilestoneApproved(grantId, milestoneIndex, msg.sender, payout);

        // Mark grant complete if all milestones paid
        if (g.releasedAmount == g.totalAmount) {
            g.status = GrantStatus.COMPLETED;
            emit GrantCompleted(grantId);
        }

        _safeTransfer(g.grantee, payout);
    }

    /**
     * @notice Reject a submitted milestone; grantee may resubmit evidence.
     */
    function rejectMilestone(uint256 grantId, uint256 milestoneIndex)
        external
        grantExists(grantId)
        grantIsActive(grantId)
        onlyVerifier(grantId)
    {
        Grant storage g = _grants[grantId];
        if (milestoneIndex >= g.milestones.length) revert InvalidMilestone();

        Milestone storage m = g.milestones[milestoneIndex];
        if (m.status != MilestoneStatus.SUBMITTED) revert MilestoneNotSubmitted();

        m.status = MilestoneStatus.REJECTED;

        emit MilestoneRejected(grantId, milestoneIndex, msg.sender);
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /// @notice Returns core grant data (without milestones array).
    function getGrant(uint256 grantId)
        external
        view
        grantExists(grantId)
        returns (
            uint256 id,
            string memory title,
            address funder,
            address grantee,
            address verifier,
            uint256 totalAmount,
            uint256 releasedAmount,
            GrantStatus status,
            uint256 createdAt,
            uint256 milestoneCount
        )
    {
        Grant storage g = _grants[grantId];
        return (
            g.id,
            g.title,
            g.funder,
            g.grantee,
            g.verifier,
            g.totalAmount,
            g.releasedAmount,
            g.status,
            g.createdAt,
            g.milestones.length
        );
    }

    /// @notice Returns data for a specific milestone.
    function getMilestone(uint256 grantId, uint256 milestoneIndex)
        external
        view
        grantExists(grantId)
        returns (
            string memory title,
            uint256 amount,
            MilestoneStatus status,
            string memory evidenceURI,
            uint256 submittedAt,
            uint256 paidAt
        )
    {
        Grant storage g = _grants[grantId];
        if (milestoneIndex >= g.milestones.length) revert InvalidMilestone();
        Milestone storage m = g.milestones[milestoneIndex];
        return (m.title, m.amount, m.status, m.evidenceURI, m.submittedAt, m.paidAt);
    }

    /// @notice All grant IDs created by a funder.
    function getGrantsByFunder(address funder) external view returns (uint256[] memory) {
        return _grantsByFunder[funder];
    }

    /// @notice All grant IDs where address is the grantee.
    function getGrantsByGrantee(address grantee) external view returns (uint256[] memory) {
        return _grantsByGrantee[grantee];
    }

    /// @notice Total number of grants ever created.
    function totalGrants() external view returns (uint256) {
        return _grantCounter;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _safeTransfer(address to, uint256 amount) internal {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
