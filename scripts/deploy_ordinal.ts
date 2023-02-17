import { ethers, upgrades } from "hardhat";

async function main() {
  const factory = await ethers.getContractFactory("OrdinalBTCMarket");
  const contract = await upgrades.deployProxy(
    factory,
    [
      "",
      "",
      ""
    ],
    {initializer: "initialize"}
  )
  await contract.deployed()

  console.log(`OrdinalBTCMarketContract deployed to ${contract.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
