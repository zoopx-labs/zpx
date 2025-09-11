import { describe, it, beforeEach } from 'node:test';
import { expect } from 'chai';
import hardhat from 'hardhat';
const viem = (hardhat as any).viem;

async function fixtureV2() {
  const publicClient = await viem.getPublicClient();
  const [admin, minter, pauser, user1, user2, mockBridge] = await viem.getWalletClients();

  const ZPXV1 = await viem.artifacts.readArtifact('ZPXV1');
  const Proxy = await viem.artifacts.readArtifact('ERC1967Proxy');

  const implTx = await admin.deployContract({ bytecode: ZPXV1.bytecode });
  const implRc = await publicClient.waitForTransactionReceipt({ hash: implTx });
  const impl = implRc.contractAddress as `0x${string}`;

  const initCalldata = viem.encodeFunctionData({ abi: ZPXV1.abi as any, functionName: 'initialize', args: [admin.address, [minter.address], pauser.address] });
  const proxyCtor = viem.encodeFunctionData({ abi: Proxy.abi as any, functionName: 'constructor', args: [impl, initCalldata] });
  const proxyBytecode = `${Proxy.bytecode}${proxyCtor.slice(2)}`;

  const proxyTx = await admin.deployContract({ bytecode: proxyBytecode as any });
  const proxyRc = await publicClient.waitForTransactionReceipt({ hash: proxyTx });
  const proxyAddress = proxyRc.contractAddress as `0x${string}`;

  return { publicClient, proxyAddress, admin, minter, pauser, user1, user2, mockBridge };
}

describe('ZPXV2 (viem) - upgrade and bridge hooks', function () {
  let ctx: Awaited<ReturnType<typeof fixtureV2>>;

  beforeEach(async () => {
    ctx = await fixtureV2();
  });

  async function expectRevert(p: Promise<any>) {
    let thrown = false;
    try { await p; } catch (e) { thrown = true; }
    expect(thrown).to.be.true;
  }

  it('admin can upgrade proxy to V2 and address remains the same', async () => {
    const ZPXV2 = await viem.artifacts.readArtifact('ZPXV2');
    const implTx = await ctx.admin.deployContract({ bytecode: ZPXV2.bytecode });
    const implRc = await ctx.publicClient.waitForTransactionReceipt({ hash: implTx });
    const implV2 = implRc.contractAddress as `0x${string}`;

    // call upgradeTo on proxy
    await ctx.admin.writeContract({ address: ctx.proxyAddress, abi: ZPXV2.abi as any, functionName: 'upgradeTo', args: [implV2] } as any);

    const codeAfter = await ctx.publicClient.getBytecode({ address: ctx.proxyAddress });
    expect(codeAfter).to.not.be.undefined;
  });

  it('bridge hooks work and are role-protected', async () => {
    const ZPXV2 = await viem.artifacts.readArtifact('ZPXV2');
    const implTx = await ctx.admin.deployContract({ bytecode: ZPXV2.bytecode });
    const implRc = await ctx.publicClient.waitForTransactionReceipt({ hash: implTx });
    const implV2 = implRc.contractAddress as `0x${string}`;

    await ctx.admin.writeContract({ address: ctx.proxyAddress, abi: ZPXV2.abi as any, functionName: 'upgradeTo', args: [implV2] } as any);

    const zpxV2 = await viem.getContractAt('ZPXV2', ctx.proxyAddress);

    // configure bridge
    await ctx.admin.writeContract({ address: ctx.proxyAddress, abi: zpxV2.abi as any, functionName: 'upgradeToSuperchainERC20', args: [ctx.mockBridge.address] } as any);

    const bridgeAddr = await zpxV2.read.superchainBridge();
    expect(bridgeAddr).to.equal(ctx.mockBridge.address);

    // mint via bridge
    await ctx.mockBridge.writeContract({ address: ctx.proxyAddress, abi: zpxV2.abi as any, functionName: 'crosschainMint', args: [ctx.user1.address, BigInt(1000)] } as any);
    const bal = BigInt(await zpxV2.read.balanceOf([ctx.user1.address]));
    expect(bal).to.equal(BigInt(1000));

    // burn via bridge
    await ctx.mockBridge.writeContract({ address: ctx.proxyAddress, abi: zpxV2.abi as any, functionName: 'crosschainBurn', args: [ctx.user1.address, BigInt(400)] } as any);
    const bal2 = BigInt(await zpxV2.read.balanceOf([ctx.user1.address]));
    expect(bal2).to.equal(BigInt(600));

    // non-bridge cannot call
  await expectRevert(ctx.user2.writeContract({ address: ctx.proxyAddress, abi: zpxV2.abi as any, functionName: 'crosschainMint', args: [ctx.user2.address, BigInt(1)] } as any));
  });
});
