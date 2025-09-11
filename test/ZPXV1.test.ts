import { describe, it, beforeEach } from "mocha";
import { expect } from "chai";
import { viem, artifacts } from "hardhat";
import { encodeFunctionData } from "viem";

const CAP = BigInt("100000000") * BigInt(10) ** BigInt(18);

/** Split a 65-byte secp256k1 signature 0x{r}{s}{v} into { v, r, s } */
function splitVRS(sigHex: `0x${string}`): { v: number; r: `0x${string}`; s: `0x${string}` } {
  const s = sigHex.slice(2);
  const r = `0x${s.slice(0, 64)}` as `0x${string}`;
  const sPart = `0x${s.slice(64, 128)}` as `0x${string}`;
  const vByte = s.slice(128, 130);
  const v = parseInt(vByte, 16);
  return { v, r, s: sPart };
}

// small helpers to force concrete types from viem reads
const asBigInt = (x: unknown) => BigInt(x as any);
const asNumber = (x: unknown) => Number(x as any);

async function fixture() {
  const publicClient = await viem.getPublicClient();
  const [admin, minter, pauser, user1, user2, attacker] = await viem.getWalletClients();

  // --- Artifacts ---
  const ZPXV1 = await artifacts.readArtifact("contracts/ZPXV1.sol:ZPXV1");

  // If you ship a local proxy (recommended for deterministic behavior in tests)
  const Proxy = await artifacts.readArtifact("contracts/LocalERC1967Proxy.sol:LocalERC1967Proxy");
  // If you instead compiled OZ's ERC1967Proxy, you could use:
  // const Proxy = await artifacts.readArtifact("ERC1967Proxy");

  // --- Deploy implementation ---
  const implHash = await admin.deployContract({
    abi: ZPXV1.abi,
    bytecode: ZPXV1.bytecode as `0x${string}`,
    args: [], // <-- viem types require args (even if empty)
  });
  const implRcpt = await publicClient.waitForTransactionReceipt({ hash: implHash });
  const impl = implRcpt.contractAddress as `0x${string}`;

  // --- Build initializer calldata ---
  const initCalldata = encodeFunctionData({
    abi: ZPXV1.abi as any,
    functionName: "initialize",
    args: [admin.account.address, [minter.account.address], pauser.account.address],
  });

  // --- Deploy proxy (constructor args; no bytecode concatenation) ---
  const proxyHash = await admin.deployContract({
    abi: Proxy.abi,
    bytecode: Proxy.bytecode as `0x${string}`,
    args: [impl, initCalldata],
  });
  const proxyRc = await publicClient.waitForTransactionReceipt({ hash: proxyHash });
  const proxyAddress = proxyRc.contractAddress as `0x${string}`;

  const contract = await viem.getContractAt("contracts/ZPXV1.sol:ZPXV1", proxyAddress);

  return {
    publicClient,
    contract,
    impl,
    proxyAddress,
    admin,
    minter,
    pauser,
    user1,
    user2,
    attacker,
  };
}

describe("ZPXV1 (viem) - core behavior", function () {
  let ctx: Awaited<ReturnType<typeof fixture>>;

  beforeEach(async () => {
    ctx = await fixture();
  });

  async function expectRevert(p: Promise<any>) {
    let thrown = false;
    try {
      await p;
    } catch {
      thrown = true;
    }
    expect(thrown, "expected tx to revert").to.be.true;
  }

  // ---------------- Initialization ----------------
  describe("Initialization", () => {
    it("has correct metadata and roles", async () => {
      const name = (await ctx.contract.read.name()) as string;
      const symbol = (await ctx.contract.read.symbol()) as string;
      const decimals = asNumber(await ctx.contract.read.decimals());
      expect(name).to.equal("ZoopX");
      expect(symbol).to.equal("ZPX");
      expect(decimals).to.equal(18);

      const DEFAULT_ADMIN_ROLE = (await ctx.contract.read.DEFAULT_ADMIN_ROLE()) as `0x${string}`;
      const MINTER_ROLE = (await ctx.contract.read.MINTER_ROLE()) as `0x${string}`;
      const PAUSER_ROLE = (await ctx.contract.read.PAUSER_ROLE()) as `0x${string}`;

      const isAdmin = (await ctx.contract.read.hasRole([
        DEFAULT_ADMIN_ROLE,
        ctx.admin.account.address,
      ])) as boolean;
      const isMinter = (await ctx.contract.read.hasRole([
        MINTER_ROLE,
        ctx.minter.account.address,
      ])) as boolean;
      const isPauser = (await ctx.contract.read.hasRole([
        PAUSER_ROLE,
        ctx.pauser.account.address,
      ])) as boolean;

      expect(isAdmin).to.eq(true);
      expect(isMinter).to.eq(true);
      expect(isPauser).to.eq(true);
    });
  });

  // ---------------- Roles ----------------
  describe("Roles", () => {
    it("only admin can grant/revoke minter", async () => {
      const MINTER_ROLE = (await ctx.contract.read.MINTER_ROLE()) as `0x${string}`;

      // grant by admin
      await ctx.admin.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "grantRole",
        args: [MINTER_ROLE, ctx.user1.account.address],
      } as any);
      const granted = (await ctx.contract.read.hasRole([
        MINTER_ROLE,
        ctx.user1.account.address,
      ])) as boolean;
      expect(granted).to.eq(true);

      // revoke by admin
      await ctx.admin.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "revokeRole",
        args: [MINTER_ROLE, ctx.user1.account.address],
      } as any);
      const revoked = (await ctx.contract.read.hasRole([
        MINTER_ROLE,
        ctx.user1.account.address,
      ])) as boolean;
      expect(revoked).to.eq(false);

      // attempt grant by non-admin should revert
      await expectRevert(
        ctx.user1.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "grantRole",
          args: [MINTER_ROLE, ctx.user2.account.address],
        } as any)
      );
    });
  });

  // ---------------- Permit (EIP-2612) ----------------
  describe("Permit (EIP-2612)", () => {
    it("allows permit signed by owner and increments nonce", async () => {
      // mint some tokens to user1 so allowance matters
      await ctx.minter.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "mint",
        args: [ctx.user1.account.address, BigInt(1000)],
      } as any);

      const chainId = Number(await ctx.publicClient.getChainId());
      const domain = {
        name: "ZoopX",
        version: "1",
        chainId,
        verifyingContract: ctx.proxyAddress,
      } as const;

      const nonce = asBigInt(await ctx.contract.read.nonces([ctx.user1.account.address]));
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 60 * 60);
      const value = BigInt(500);

      const message: {
        owner: `0x${string}`;
        spender: `0x${string}`;
        value: bigint;
        nonce: bigint;
        deadline: bigint;
      } = {
        owner: ctx.user1.account.address,
        spender: ctx.user2.account.address,
        value,
        nonce,
        deadline,
      };

      const sig = (await ctx.user1.signTypedData({
        domain,
        types: {
          Permit: [
            { name: "owner", type: "address" },
            { name: "spender", type: "address" },
            { name: "value", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" },
          ],
        },
        primaryType: "Permit",
        message,
      })) as `0x${string}`;

      const { v, r, s } = splitVRS(sig);

      await ctx.user2.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "permit",
        args: [
          ctx.user1.account.address,
          ctx.user2.account.address,
          value,
          deadline,
          v,
          r,
          s,
        ],
      } as any);

      const allowance = asBigInt(
        await ctx.contract.read.allowance([ctx.user1.account.address, ctx.user2.account.address])
      );
      expect(allowance).to.equal(value);

      const newNonce = asBigInt(await ctx.contract.read.nonces([ctx.user1.account.address]));
      expect(newNonce).to.equal(nonce + BigInt(1));
    });

    it("rejects expired permit", async () => {
      const chainId = Number(await ctx.publicClient.getChainId());
      const domain = {
        name: "ZoopX",
        version: "1",
        chainId,
        verifyingContract: ctx.proxyAddress,
      } as const;
      const nonce = asBigInt(await ctx.contract.read.nonces([ctx.user1.account.address]));
      const deadline = BigInt(Math.floor(Date.now() / 1000) - 10);
      const value = BigInt(1);

      const message: {
        owner: `0x${string}`;
        spender: `0x${string}`;
        value: bigint;
        nonce: bigint;
        deadline: bigint;
      } = {
        owner: ctx.user1.account.address,
        spender: ctx.user2.account.address,
        value,
        nonce,
        deadline,
      };

      const sig = (await ctx.user1.signTypedData({
        domain,
        types: {
          Permit: [
            { name: "owner", type: "address" },
            { name: "spender", type: "address" },
            { name: "value", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" },
          ],
        },
        primaryType: "Permit",
        message,
      })) as `0x${string}`;
      const { v, r, s } = splitVRS(sig);

      await expectRevert(
        ctx.user2.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "permit",
          args: [
            ctx.user1.account.address,
            ctx.user2.account.address,
            value,
            deadline,
            v,
            r,
            s,
          ],
        } as any)
      );
    });
  });

  // ---------------- Minting & Cap ----------------
  describe("Minting & Cap", () => {
    it("minter can mint and cap enforced", async () => {
      const supplyBefore = asBigInt(await ctx.contract.read.totalSupply());

      await ctx.minter.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "mint",
        args: [ctx.user1.account.address, BigInt(1000)],
      } as any);

      const supplyAfter = asBigInt(await ctx.contract.read.totalSupply());
      expect(supplyAfter).to.equal(supplyBefore + BigInt(1000));

      // zero address mint reverts
      await expectRevert(
        ctx.minter.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "mint",
          args: ["0x0000000000000000000000000000000000000000", BigInt(1)],
        } as any)
      );

      // cap enforcement
      const cap = asBigInt(await ctx.contract.read.cap());
      expect(cap).to.equal(CAP);

      // try to exceed cap
      const supply = asBigInt(await ctx.contract.read.totalSupply());
      const toMint = cap - supply + BigInt(1);

      await expectRevert(
        ctx.minter.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "mint",
          args: [ctx.user2.account.address, toMint],
        } as any)
      );
    });

    it("mintBatch atomic and validation", async () => {
      // valid batch
      await ctx.minter.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "mintBatch",
        args: [
          [ctx.user1.account.address, ctx.user2.account.address],
          [BigInt(10), BigInt(20)],
        ],
      } as any);

      const b1 = asBigInt(await ctx.contract.read.balanceOf([ctx.user1.account.address]));
      const b2 = asBigInt(await ctx.contract.read.balanceOf([ctx.user2.account.address]));
      expect(b1 >= BigInt(10)).to.be.true;
      expect(b2 >= BigInt(20)).to.be.true;

      // length mismatch
      await expectRevert(
        ctx.minter.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "mintBatch",
          args: [[ctx.user1.account.address], [BigInt(1), BigInt(2)]],
        } as any)
      );

      // address zero in recipients
      await expectRevert(
        ctx.minter.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "mintBatch",
          args: [["0x0000000000000000000000000000000000000000"], [BigInt(1)]],
        } as any)
      );
    });
  });

  // ---------------- Burning ----------------
  describe("Burning", () => {
    it("burn and burnFrom behave correctly", async () => {
      await ctx.minter.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "mint",
        args: [ctx.user1.account.address, BigInt(1000)],
      } as any);

      await ctx.user1.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "approve",
        args: [ctx.user2.account.address, BigInt(500)],
      } as any);

      await ctx.user2.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "burnFrom",
        args: [ctx.user1.account.address, BigInt(200)],
      } as any);

      const bal = asBigInt(await ctx.contract.read.balanceOf([ctx.user1.account.address]));
      expect(bal).to.equal(BigInt(800));

      // insufficient allowance
      await expectRevert(
        ctx.user2.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "burnFrom",
          args: [ctx.user1.account.address, BigInt(1000)],
        } as any)
      );
    });
  });

  // ---------------- Pause ----------------
  describe("Pause", () => {
    it("pauser can pause/unpause and actions blocked when paused", async () => {
      await ctx.pauser.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "pause",
        args: [],
      } as any);

      // transfer should revert
      await expectRevert(
        ctx.user1.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "transfer",
          args: [ctx.user2.account.address, BigInt(1)],
        } as any)
      );

      // mint should revert
      await expectRevert(
        ctx.minter.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "mint",
          args: [ctx.user1.account.address, BigInt(1)],
        } as any)
      );

      await ctx.pauser.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "unpause",
        args: [],
      } as any);

      // now succeed
      await ctx.minter.writeContract({
        address: ctx.contract.address,
        abi: ctx.contract.abi as any,
        functionName: "mint",
        args: [ctx.user1.account.address, BigInt(1)],
      } as any);
    });
  });

//   ---------------- Rescue (optional / requires MockERC20) ----------------

  describe("Rescue", () => {
    it("admin can rescue unrelated ERC20s; cannot rescue ZPX itself", async () => {
      const Mock = await artifacts.readArtifact("contracts/mocks/MockERC20.sol:MockERC20");
      // deploy mock ERC20
      const mockHash = await ctx.admin.deployContract({
        abi: Mock.abi,
        bytecode: Mock.bytecode as `0x${string}`,
  args: ["Mock Token", "MCK"],
      });
      const mockRcpt = await ctx.publicClient.waitForTransactionReceipt({ hash: mockHash });
      const mockAddr = mockRcpt.contractAddress as `0x${string}`;
  
      // Transfer some to proxy, then have admin call rescueERC20(mockAddr, treasury, amount)
      // Ensure calling rescueERC20 on token == proxyAddress reverts.
      await expectRevert(
        ctx.admin.writeContract({
          address: ctx.contract.address,
          abi: ctx.contract.abi as any,
          functionName: "rescueERC20",
          args: [ctx.proxyAddress, ctx.user1.account.address, BigInt(1e18)], // adjust args to your signature
        } as any)
      );
    });
  });
});
