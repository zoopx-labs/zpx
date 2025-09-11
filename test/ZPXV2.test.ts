import { describe, it, beforeEach } from "mocha";
import { expect } from "chai";
import { viem, artifacts } from "hardhat";
import { encodeFunctionData } from "viem";

// helpers to coerce unknown -> typed
const asBigInt = (x: unknown) => BigInt(x as any);
const asString = (x: unknown) => String(x as any);



async function fixtureV2() {
  const publicClient = await viem.getPublicClient();
  const [admin, minter, pauser, user1, user2, mockBridge] = await viem.getWalletClients();

  // --- Artifacts (fully qualified names recommended) ---
  const ZPXV1 = await artifacts.readArtifact("contracts/ZPXV1.sol:ZPXV1");

  // If you ship a local proxy in your repo:
  const Proxy = await artifacts.readArtifact(
    "contracts/LocalERC1967Proxy.sol:LocalERC1967Proxy"
  );

  // If instead you compiled OZ's proxy, use:
  // const Proxy = await artifacts.readArtifact("ERC1967Proxy");

  // --- Deploy V1 implementation ---
  const implHash = await admin.deployContract({
    abi: ZPXV1.abi,
    bytecode: ZPXV1.bytecode as `0x${string}`,
    args: [], // viem requires args (even if empty)
  });
  const implRc = await publicClient.waitForTransactionReceipt({ hash: implHash });
  const impl = implRc.contractAddress as `0x${string}`;

  // --- Build initializer calldata for V1 ---
  const initCalldata = encodeFunctionData({
    abi: ZPXV1.abi as any,
    functionName: "initialize",
    args: [
      admin.account.address,
      [minter.account.address],
      pauser.account.address,
    ],
  });

  // --- Deploy proxy pointing to V1 implementation ---
  const proxyHash = await admin.deployContract({
    abi: Proxy.abi,
    bytecode: Proxy.bytecode as `0x${string}`,
    args: [impl, initCalldata],
  });
  const proxyRc = await publicClient.waitForTransactionReceipt({ hash: proxyHash });
  const proxyAddress = proxyRc.contractAddress as `0x${string}`;

  return {
    publicClient,
    proxyAddress,
    admin,
    minter,
    pauser,
    user1,
    user2,
    mockBridge,
  };
}

describe("ZPXV2 (viem) - upgrade and bridge hooks", function () {
  let ctx: Awaited<ReturnType<typeof fixtureV2>>;

  beforeEach(async () => {
    ctx = await fixtureV2();
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

  it("admin can upgrade proxy to V2 and address remains the same", async () => {
    // Load V2 artifact and define minimal UUPS ABI for upgradeTo
    const ZPXV2 = await artifacts.readArtifact("contracts/ZPXV2.sol:ZPXV2");
    const UUPS_ABI = [
      {
        name: "upgradeToAndCall",
        type: "function",
        stateMutability: "payable",
        inputs: [
          { name: "newImplementation", type: "address" },
          { name: "data", type: "bytes" },
        ],
        outputs: [],
      },
    ] as const;

    // Deploy V2 implementation
    const implTx = await ctx.admin.deployContract({
      abi: ZPXV2.abi,
      bytecode: ZPXV2.bytecode as `0x${string}`,
      args: [],
    });
    const implRc = await ctx.publicClient.waitForTransactionReceipt({ hash: implTx });
    const implV2 = implRc.contractAddress as `0x${string}`;

    // Call UUPS upgradeToAndCall on proxy using a minimal UUPS ABI
    await ctx.admin.writeContract({
      address: ctx.proxyAddress,
      abi: UUPS_ABI as any,
      functionName: "upgradeToAndCall",
      args: [implV2, "0x"],
    } as any);

    // Sanity: proxy code exists & address unchanged
    const codeAfter = await ctx.publicClient.getBytecode({ address: ctx.proxyAddress });
    expect(codeAfter && codeAfter.length > 2, "proxy has no code").to.eq(true);

    // Optional: basic state invariants via V2 ABI
    const zpxV2 = await viem.getContractAt(
      "contracts/ZPXV2.sol:ZPXV2",
      ctx.proxyAddress
    );
    const name = (await zpxV2.read.name()) as string;
    const symbol = (await zpxV2.read.symbol()) as string;
    expect(name).to.eq("ZoopX");
    expect(symbol).to.eq("ZPX");
  });

  it("bridge hooks work and are role-protected", async () => {
    const ZPXV2 = await artifacts.readArtifact("contracts/ZPXV2.sol:ZPXV2");
    const UUPS_ABI = [
      {
        name: "upgradeToAndCall",
        type: "function",
        stateMutability: "payable",
        inputs: [
          { name: "newImplementation", type: "address" },
          { name: "data", type: "bytes" },
        ],
        outputs: [],
      },
    ] as const;

    // Deploy V2 implementation
    const implTx = await ctx.admin.deployContract({
      abi: ZPXV2.abi,
      bytecode: ZPXV2.bytecode as `0x${string}`,
      args: [],
    });
    const implRc = await ctx.publicClient.waitForTransactionReceipt({ hash: implTx });
    const implV2 = implRc.contractAddress as `0x${string}`;

    // Upgrade to V2 using minimal UUPS ABI
    await ctx.admin.writeContract({
      address: ctx.proxyAddress,
      abi: UUPS_ABI as any,
      functionName: "upgradeToAndCall",
      args: [implV2, "0x"],
    } as any);

    // Interact via V2 ABI now
    const zpxV2 = await viem.getContractAt(
      "contracts/ZPXV2.sol:ZPXV2",
      ctx.proxyAddress
    );

    // configure bridge via reinitializer(2)
    await ctx.admin.writeContract({
      address: ctx.proxyAddress,
      abi: zpxV2.abi as any,
      functionName: "upgradeToSuperchainERC20",
      args: [ctx.mockBridge.account.address],
    } as any);

    const bridgeAddr = (await zpxV2.read.superchainBridge()) as `0x${string}`;
    expect(bridgeAddr.toLowerCase()).to.equal(ctx.mockBridge.account.address.toLowerCase());

    // mint via bridge
    await ctx.mockBridge.writeContract({
      address: ctx.proxyAddress,
      abi: zpxV2.abi as any,
      functionName: "crosschainMint",
      args: [ctx.user1.account.address, BigInt(1000)],
    } as any);
    const bal1 = asBigInt(await zpxV2.read.balanceOf([ctx.user1.account.address]));
    expect(bal1).to.equal(BigInt(1000));

    // burn via bridge
    await ctx.mockBridge.writeContract({
      address: ctx.proxyAddress,
      abi: zpxV2.abi as any,
      functionName: "crosschainBurn",
      args: [ctx.user1.account.address, BigInt(400)],
    } as any);
    const bal2 = asBigInt(await zpxV2.read.balanceOf([ctx.user1.account.address]));
    expect(bal2).to.equal(BigInt(600));

    // non-bridge cannot call hooks
    await expectRevert(
      ctx.user2.writeContract({
        address: ctx.proxyAddress,
        abi: zpxV2.abi as any,
        functionName: "crosschainMint",
        args: [ctx.user2.account.address, BigInt(1)],
      } as any)
    );
  });
});
