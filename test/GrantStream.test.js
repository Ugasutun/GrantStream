const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * GrantStream.sol — Test Suite
 * Run: npx hardhat test
 */
describe("GrantStream", function () {
  let grantStream;
  let funder, grantee, verifier, stranger;

  // Helper: 1 ETH in wei
  const ONE_ETH  = ethers.parseEther("1.0");
  const HALF_ETH = ethers.parseEther("0.5");

  // Helper: create a simple 2-milestone grant
  async function createBasicGrant(overrides = {}) {
    const titles   = overrides.titles   ?? ["Design mockups", "Working prototype"];
    const amounts  = overrides.amounts  ?? [HALF_ETH, HALF_ETH];
    const total    = amounts.reduce((a, b) => a + b, 0n);
    const tx = await grantStream.connect(funder).createGrant(
      overrides.title    ?? "Build a cool dApp",
      overrides.grantee  ?? grantee.address,
      overrides.verifier ?? verifier.address,
      titles,
      amounts,
      { value: overrides.value ?? total }
    );
    const receipt = await tx.wait();
    // Extract grantId from GrantCreated event
    const event = receipt.logs
      .map(l => { try { return grantStream.interface.parseLog(l); } catch { return null; } })
      .find(e => e?.name === "GrantCreated");
    return event.args.grantId;
  }

  beforeEach(async () => {
    [funder, grantee, verifier, stranger] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("GrantStream");
    grantStream = await Factory.deploy();
    await grantStream.waitForDeployment();
  });

  // ── createGrant ────────────────────────────────────────────────────────────

  describe("createGrant()", () => {
    it("locks ETH and emits GrantCreated", async () => {
      await expect(
        grantStream.connect(funder).createGrant(
          "My Grant", grantee.address, verifier.address,
          ["M1", "M2"], [HALF_ETH, HALF_ETH],
          { value: ONE_ETH }
        )
      )
        .to.emit(grantStream, "GrantCreated")
        .withArgs(1n, funder.address, grantee.address, verifier.address, ONE_ETH, "My Grant");

      // Contract balance should hold the locked ETH
      const bal = await ethers.provider.getBalance(await grantStream.getAddress());
      expect(bal).to.equal(ONE_ETH);
    });

    it("increments grantId correctly", async () => {
      await createBasicGrant();
      await createBasicGrant();
      expect(await grantStream.totalGrants()).to.equal(2n);
    });

    it("reverts if msg.value doesn't match sum of milestone amounts", async () => {
      await expect(
        grantStream.connect(funder).createGrant(
          "Bad Grant", grantee.address, verifier.address,
          ["M1"], [ONE_ETH],
          { value: HALF_ETH }   // wrong amount
        )
      ).to.be.revertedWithCustomError(grantStream, "MsgValueMismatch");
    });

    it("reverts on zero grantee address", async () => {
      await expect(
        grantStream.connect(funder).createGrant(
          "T", ethers.ZeroAddress, verifier.address,
          ["M1"], [ONE_ETH], { value: ONE_ETH }
        )
      ).to.be.revertedWithCustomError(grantStream, "ZeroAddress");
    });

    it("reverts on empty title", async () => {
      await expect(
        grantStream.connect(funder).createGrant(
          "", grantee.address, verifier.address,
          ["M1"], [ONE_ETH], { value: ONE_ETH }
        )
      ).to.be.revertedWithCustomError(grantStream, "EmptyTitle");
    });

    it("reverts on empty milestones array", async () => {
      await expect(
        grantStream.connect(funder).createGrant(
          "T", grantee.address, verifier.address,
          [], [], { value: 0n }
        )
      ).to.be.revertedWithCustomError(grantStream, "NoMilestones");
    });

    it("reverts on milestone amount of zero", async () => {
      await expect(
        grantStream.connect(funder).createGrant(
          "T", grantee.address, verifier.address,
          ["M1"], [0n], { value: 0n }
        )
      ).to.be.revertedWithCustomError(grantStream, "MilestoneAmountZero");
    });
  });

  // ── submitEvidence ─────────────────────────────────────────────────────────

  describe("submitEvidence()", () => {
    it("grantee can submit evidence and status becomes SUBMITTED", async () => {
      const grantId = await createBasicGrant();
      await expect(
        grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://QmTestHash")
      )
        .to.emit(grantStream, "EvidenceSubmitted")
        .withArgs(grantId, 0n, grantee.address, "ipfs://QmTestHash");

      const [, , status, uri] = await grantStream.getMilestone(grantId, 0);
      expect(status).to.equal(1n); // SUBMITTED
      expect(uri).to.equal("ipfs://QmTestHash");
    });

    it("non-grantee cannot submit evidence", async () => {
      const grantId = await createBasicGrant();
      await expect(
        grantStream.connect(stranger).submitEvidence(grantId, 0, "ipfs://bad")
      ).to.be.revertedWithCustomError(grantStream, "Unauthorized");
    });

    it("reverts if milestone already SUBMITTED (no double-submit)", async () => {
      const grantId = await createBasicGrant();
      await grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://first");
      await expect(
        grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://second")
      ).to.be.revertedWithCustomError(grantStream, "MilestoneNotPending");
    });

    it("grantee can resubmit after rejection", async () => {
      const grantId = await createBasicGrant();
      await grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://v1");
      await grantStream.connect(verifier).rejectMilestone(grantId, 0);
      // status is now REJECTED — resubmission should work
      await expect(
        grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://v2")
      ).to.emit(grantStream, "EvidenceSubmitted");
    });
  });

  // ── approveMilestone ───────────────────────────────────────────────────────

  describe("approveMilestone()", () => {
    it("releases ETH to grantee and emits MilestoneApproved", async () => {
      const grantId = await createBasicGrant();
      await grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://QmEv");

      const before = await ethers.provider.getBalance(grantee.address);
      await expect(grantStream.connect(verifier).approveMilestone(grantId, 0))
        .to.emit(grantStream, "MilestoneApproved")
        .withArgs(grantId, 0n, verifier.address, HALF_ETH);

      const after = await ethers.provider.getBalance(grantee.address);
      expect(after - before).to.be.closeTo(HALF_ETH, ethers.parseEther("0.001"));
    });

    it("marks grant COMPLETED when last milestone is approved", async () => {
      const grantId = await createBasicGrant();
      await grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://ev0");
      await grantStream.connect(verifier).approveMilestone(grantId, 0);
      await grantStream.connect(grantee).submitEvidence(grantId, 1, "ipfs://ev1");
      await expect(grantStream.connect(verifier).approveMilestone(grantId, 1))
        .to.emit(grantStream, "GrantCompleted")
        .withArgs(grantId);

      const [,,,,,, , status] = await grantStream.getGrant(grantId);
      expect(status).to.equal(1n); // COMPLETED
    });

    it("non-verifier cannot approve", async () => {
      const grantId = await createBasicGrant();
      await grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://x");
      await expect(
        grantStream.connect(stranger).approveMilestone(grantId, 0)
      ).to.be.revertedWithCustomError(grantStream, "Unauthorized");
    });

    it("reverts if milestone is not SUBMITTED", async () => {
      const grantId = await createBasicGrant();
      await expect(
        grantStream.connect(verifier).approveMilestone(grantId, 0)
      ).to.be.revertedWithCustomError(grantStream, "MilestoneNotSubmitted");
    });
  });

  // ── rejectMilestone ────────────────────────────────────────────────────────

  describe("rejectMilestone()", () => {
    it("sets milestone status to REJECTED and emits event", async () => {
      const grantId = await createBasicGrant();
      await grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://weak");
      await expect(grantStream.connect(verifier).rejectMilestone(grantId, 0))
        .to.emit(grantStream, "MilestoneRejected")
        .withArgs(grantId, 0n, verifier.address);

      const [, , status] = await grantStream.getMilestone(grantId, 0);
      expect(status).to.equal(3n); // REJECTED
    });
  });

  // ── cancelGrant ────────────────────────────────────────────────────────────

  describe("cancelGrant()", () => {
    it("refunds unreleased ETH to funder", async () => {
      const grantId = await createBasicGrant();

      const before = await ethers.provider.getBalance(funder.address);
      const tx     = await grantStream.connect(funder).cancelGrant(grantId);
      const rcpt   = await tx.wait();
      const gasCost = rcpt.gasUsed * rcpt.gasPrice;
      const after  = await ethers.provider.getBalance(funder.address);

      expect(after - before + gasCost).to.be.closeTo(ONE_ETH, ethers.parseEther("0.001"));
    });

    it("partial refund after one milestone paid", async () => {
      const grantId = await createBasicGrant();
      await grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://ev");
      await grantStream.connect(verifier).approveMilestone(grantId, 0); // HALF_ETH released

      const before  = await ethers.provider.getBalance(funder.address);
      const tx      = await grantStream.connect(funder).cancelGrant(grantId);
      const rcpt    = await tx.wait();
      const gasCost = rcpt.gasUsed * rcpt.gasPrice;
      const after   = await ethers.provider.getBalance(funder.address);

      // Only the remaining HALF_ETH should be refunded
      expect(after - before + gasCost).to.be.closeTo(HALF_ETH, ethers.parseEther("0.001"));
    });

    it("cannot cancel while a milestone is SUBMITTED", async () => {
      const grantId = await createBasicGrant();
      await grantStream.connect(grantee).submitEvidence(grantId, 0, "ipfs://ev");
      await expect(
        grantStream.connect(funder).cancelGrant(grantId)
      ).to.be.revertedWithCustomError(grantStream, "CannotCancelWhileSubmitted");
    });

    it("non-funder cannot cancel", async () => {
      const grantId = await createBasicGrant();
      await expect(
        grantStream.connect(stranger).cancelGrant(grantId)
      ).to.be.revertedWithCustomError(grantStream, "Unauthorized");
    });
  });

  // ── View helpers ───────────────────────────────────────────────────────────

  describe("View helpers", () => {
    it("getGrantsByFunder and getGrantsByGrantee return correct IDs", async () => {
      await createBasicGrant();
      await createBasicGrant();

      const byFunder  = await grantStream.getGrantsByFunder(funder.address);
      const byGrantee = await grantStream.getGrantsByGrantee(grantee.address);

      expect(byFunder.length).to.equal(2);
      expect(byGrantee.length).to.equal(2);
    });
  });
});
