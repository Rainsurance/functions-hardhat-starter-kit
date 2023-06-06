const { types } = require("hardhat/config")
const { networks } = require("../../networks")

// npx hardhat functions-deploy-rainsurance --network polygonMumbai --verify true --subid 550 --gifregistry 0xc74170ad97c9eF3AdA552427Ea3163500D484961

// RainOracleCLFunctions contract deployed to 0xd5359d7097cC3E112e75E4af79418Db316d426fD on mumbai
task("functions-deploy-rainsurance", "Deploys the RainOracleCLFunctions contract")
  .addParam("subid", "Subscription ID")
  .addParam("gifregistry", "GIF Registry")
  .addOptionalParam("verify", "Set to true to verify client contract", false, types.boolean)
  .setAction(async (taskArgs) => {
    if (network.name === "hardhat") {
      throw Error(
        'This command cannot be used on a local hardhat chain.  Specify a valid network or simulate an RainOracleCLFunctions request locally with "npx hardhat functions-simulate-rainsurance".'
      )
    }

    const subscriptionId = taskArgs.subid
    const gifRegistry = taskArgs.gifregistry

    // Check to see if the maximum gas limit has been exceeded
    const gasLimit = 300_000

    console.log(`Deploying RainOracleCLFunctions contract to ${network.name}`)

    const oracleAddress = networks[network.name]["functionsOracleProxy"]

    console.log("\n__Compiling Contracts__")
    await run("compile")

    const baseName = `Rain_${Math.floor(Date.now() / 1000)}_Oracle`
    const clientName = ethers.utils.formatBytes32String(baseName)
    const clientContractFactory = await ethers.getContractFactory("RainOracleCLFunctions")
    const clientContract = await clientContractFactory.deploy(
      clientName,
      gifRegistry,
      oracleAddress,
      subscriptionId,
      gasLimit
    )

    console.log(
      `\nWaiting ${networks[network.name].confirmations} blocks for transaction ${
        clientContract.deployTransaction.hash
      } to be confirmed...`
    )
    await clientContract.deployTransaction.wait(networks[network.name].confirmations)

    const verifyContract = taskArgs.verify

    if (verifyContract && !!networks[network.name].verifyApiKey && networks[network.name].verifyApiKey !== "UNSET") {
      try {
        console.log("\nVerifying contract...")
        await clientContract.deployTransaction.wait(Math.max(6 - networks[network.name].confirmations, 0))
        await run("verify:verify", {
          address: clientContract.address,
          constructorArguments: [clientName, gifRegistry, oracleAddress, subscriptionId, gasLimit],
        })
        console.log("Contract verified")
      } catch (error) {
        if (!error.message.includes("Already Verified")) {
          console.log("Error verifying contract.  Delete the build folder and try again.")
          console.log(error)
        } else {
          console.log("Contract already verified")
        }
      }
    } else if (verifyContract) {
      console.log(
        "\nPOLYGONSCAN_API_KEY, ETHERSCAN_API_KEY or SNOWTRACE_API_KEY is missing. Skipping contract verification..."
      )
    }

    console.log(`\nRainOracleCLFunctions contract deployed to ${clientContract.address} on ${network.name}`)
  })
