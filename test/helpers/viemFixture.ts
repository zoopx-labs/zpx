import { createPublicClient, createWalletClient, http } from 'viem';
import { hardhat } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import bip39 from 'bip39';
import hdkey from 'ethereumjs-wallet/hdkey';

const DEFAULT_MNEMONIC = 'test test test test test test test test test test test junk';

export async function getViemFixture(count = 6) {
  const seed = await bip39.mnemonicToSeed(DEFAULT_MNEMONIC);
  const hd = hdkey.fromMasterSeed(seed);
  const privKeys: string[] = [];
  for (let i = 0; i < count; i++) {
    const derivation = `m/44'/60'/0'/0/${i}`;
    const wallet = hd.derivePath(derivation).getWallet();
    const pk = '0x' + wallet.getPrivateKey().toString('hex');
    privKeys.push(pk);
  }

  const publicClient = createPublicClient({ chain: hardhat, transport: http('http://127.0.0.1:8545') });

  const walletClients = privKeys.map(pk => createWalletClient({ chain: hardhat, transport: http('http://127.0.0.1:8545'), account: privateKeyToAccount(pk) }));

  return { publicClient, walletClients };
}
