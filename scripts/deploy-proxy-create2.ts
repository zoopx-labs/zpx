import hre from 'hardhat';
import { createPublicClient, createWalletClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { encodeFunctionData, encodeAbiParameters, keccak256 } from 'viem';
import { TextEncoder } from 'util';

async function main() {
  // Env / config
  const admin = process.env.ZPX_ADMIN;
  if (!admin) throw new Error('ZPX_ADMIN required');
  const minters = process.env.ZPX_MINTERS ? process.env.ZPX_MINTERS.split(',').map(s => s.trim()) : [];
  const pauser = process.env.ZPX_PAUSER || '0x0000000000000000000000000000000000000000';
  const saltInput = process.env.CREATE2_SALT || 'zpx-superchain-addr';
  const RPC_URL = process.env.RPC_URL || 'http://127.0.0.1:8545';
  const PRIV_KEY = process.env.PRIVATE_KEY;
  if (!PRIV_KEY) throw new Error('PRIVATE_KEY required for viem wallet client');

  // Ensure artifacts are compiled before running this script (run `npx hardhat compile` separately)

  // Create viem clients
  const publicClient: any = createPublicClient({ transport: http(RPC_URL as any) } as any);
  const walletClient: any = createWalletClient({ account: privateKeyToAccount(PRIV_KEY as `0x${string}`) as any, transport: http(RPC_URL as any) } as any);

  // 1) Deploy implementation (ZPXV1) via creation bytecode
  const zpxArtifact = await hre.artifacts.readArtifact('ZPXV1');
  const implTxHash = await walletClient.sendTransaction({
    to: undefined,
    data: zpxArtifact.bytecode as any,
    chain: undefined as any,
  } as any);
  const implRc = await publicClient.waitForTransactionReceipt({ hash: implTxHash });
  const implAddress = implRc.contractAddress;
  if (!implAddress) throw new Error('Implementation deployment failed');
  console.log('Implementation deployed at', implAddress);

  // 2) Build initializer calldata for initialize(admin, initialMinters, pauser)
  const initData = encodeFunctionData({
    abi: zpxArtifact.abi as any,
    functionName: 'initialize',
    args: [admin, minters, pauser],
  });

  // 3) Construct ERC1967Proxy bytecode with constructor args (address, bytes)
  const proxyArtifact = await hre.artifacts.readArtifact('ERC1967Proxy');
  const ctorEncoded = encodeAbiParameters(
    [{ type: 'address' }, { type: 'bytes' }],
    [implAddress, initData]
  );
  const proxyBytecode = `${proxyArtifact.bytecode}${ctorEncoded.slice(2)}`; // concat, remove 0x

  // 4) Deploy/Create Create2Deployer (if not deployed) — here we always deploy fresh
  const create2Artifact = await hre.artifacts.readArtifact('Create2Deployer');
  const create2TxHash = await walletClient.sendTransaction({ to: undefined, data: create2Artifact.bytecode as any, chain: undefined as any } as any);
  const create2Rc = await publicClient.waitForTransactionReceipt({ hash: create2TxHash });
  const create2Addr = create2Rc.contractAddress as string;
  console.log('Create2Deployer:', create2Addr);

  // 5) Compute expected proxy address: computeAddress(salt, keccak256(proxyBytecode)) via contract or replicate off-chain
  // viem keccak256 wants Bytes or hex string; ensure 0x hex inputs
  const encoder = new TextEncoder();
  const salt = keccak256(encoder.encode(saltInput));
  const bytecodeHash = keccak256(`0x${proxyBytecode.slice(2)}`);

  // Call contract computeAddress view
  const computed = await publicClient.readContract({
    address: create2Addr as `0x${string}`,
    abi: create2Artifact.abi as any,
    functionName: 'computeAddress',
    args: [salt as any, bytecodeHash as any],
  });
  console.log('Computed proxy address:', computed);

  // 6) Deploy proxy via create2
  const deployTxHash = await walletClient.writeContract({
    address: create2Addr as `0x${string}`,
    abi: create2Artifact.abi as any,
    functionName: 'deploy',
    args: [salt as any, proxyBytecode],
    chain: undefined as any,
  } as any);
  const deployRc = await publicClient.waitForTransactionReceipt({ hash: deployTxHash });
  console.log('Deploy tx:', deployRc.transactionHash);

  // 7) Verify
  const deployedAddr = await publicClient.readContract({
    address: create2Addr as `0x${string}`,
    abi: create2Artifact.abi as any,
    functionName: 'computeAddress',
    args: [salt as any, bytecodeHash as any],
  });
  console.log('Deployed proxy at', deployedAddr);
  if ((deployedAddr as string).toLowerCase() !== (computed as string).toLowerCase()) {
    throw new Error('Deployed address mismatch');
  }

  console.log('Implementation:', implAddress);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
