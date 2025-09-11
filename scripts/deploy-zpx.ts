export {};

async function main() {
  // TODO: Deploy ZPXV1 implementation and UUPS proxy, mint allocations to vesting & emissions manager
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
