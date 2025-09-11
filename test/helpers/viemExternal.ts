import { readFileSync } from 'fs';
import { createPublicClient, createWalletClient, http, Hex, Address, Chain } from 'viem';
import { hardhat as hardhatChain } from 'viem/chains';
import { mnemonicToAccount } from 'viem/accounts';

type Artifact = { abi: any; bytecode?: Hex };

const ARTIFACTS: Record<string, string> = {
  Counter: 'artifacts/contracts/Counter.sol/Counter.json',
  ZPXV1: 'artifacts/contracts/ZPXV1.sol/ZPXV1.json',
  ZPXV2: 'artifacts/contracts/ZPXV2.sol/ZPXV2.json',
  LocalERC1967Proxy: 'artifacts/contracts/LocalERC1967Proxy.sol/LocalERC1967Proxy.json',
  MockERC20: 'artifacts/test/mocks/MockERC20.sol/MockERC20.json',
};

export function readArtifact(name: keyof typeof ARTIFACTS): Artifact {
  const p = ARTIFACTS[name];
  const raw = readFileSync(p, 'utf8');
  const json = JSON.parse(raw);
  return { abi: json.abi, bytecode: json.bytecode as Hex };
}

export async function getExternalViem(opts?: { rpcUrl?: string; chain?: Chain; accounts?: number }) {
  const rpcUrl = opts?.rpcUrl ?? 'http://127.0.0.1:8545';
  const chain = opts?.chain ?? hardhatChain;
  const accountsCount = opts?.accounts ?? 6;

  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  // Hardhat's default mnemonic
  const mnemonic = 'test test test test test test test test test test test junk';
  const walletClients = Array.from({ length: accountsCount }, (_, i) => {
    const account = mnemonicToAccount(mnemonic, { accountIndex: i });
    return createWalletClient({ account, chain, transport: http(rpcUrl) });
  });

  const addresses = walletClients.map((w) => w.account.address as Address);

  return { publicClient, walletClients, addresses };
}
