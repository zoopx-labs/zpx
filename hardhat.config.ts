import "dotenv/config";
import "ts-node/register/transpile-only";
import "tsconfig-paths/register";
import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
  networks: {
    hardhat: { chainId: 31337 },
    sepolia: {
      url: process.env.RPC_SEPOLIA || "",
      accounts: process.env.DEPLOYER_MNEMONIC
        ? {
            mnemonic: process.env.DEPLOYER_MNEMONIC,
            path: "m/44'/60'/0'/0",
            initialIndex: 0,
            count: 10,
          }
        : [],
    },
  },
  mocha: { timeout: 200000 },
};

export default config;
