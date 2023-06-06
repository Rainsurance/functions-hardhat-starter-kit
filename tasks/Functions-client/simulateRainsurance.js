const {
  simulateRequest,
  buildRequest,
  getDecodedResultLog,
  getRequestConfig,
} = require("../../FunctionsSandboxLibrary")
const { networks, SHARED_DON_PUBLIC_KEY } = require("../../networks")
const path = require("path")
const process = require("process")
const fs = require("fs")

// Loads environment variables from .env.enc file (if it exists)
require("@chainlink/env-enc").config()

task(
  "functions-simulate-rainsurance",
  "Simulates an end-to-end fulfillment locally for the RainOracleCLFunctions contract"
)
  .addOptionalParam(
    "gaslimit",
    "Maximum amount of gas that can be used to call fulfillRequest in the client contract (defaults to 100,000)"
  )
  .addOptionalParam(
    "functionpath",
    "Path to Functions request config file",
    `${__dirname}/../../meteoblue.v2.js`,
    types.string
  )
  .setAction(async (taskArgs, hre) => {
    // Simulation can only be conducted on a local fork of the blockchain
    if (network.name !== "hardhat") {
      throw Error('Simulated requests can only be conducted using --network "hardhat"')
    }

    // Check to see if the maximum gas limit has been exceeded
    const gasLimit = parseInt(taskArgs.gaslimit ?? "100000")
    if (gasLimit > 300000) {
      throw Error("Gas limit must be less than or equal to 300,000")
    }

    // Recompile the latest version of the contracts
    console.log("\n__Compiling Contracts__")
    await run("compile")

    // Deploy a mock oracle & registry contract to simulate a fulfillment
    console.log("\n__Deploying Mock Oracle__")
    const { oracle, registry, linkToken } = await deployMockOracle()

    const accounts = await ethers.getSigners()
    const deployer = accounts[0]

    // Add the wallet initiating the request to the oracle allowlist to authorize a simulated fulfillment
    const allowlistTx = await oracle.addAuthorizedSenders([deployer.address])
    await allowlistTx.wait(1)

    // Create & fund a subscription
    console.log("\n__Creating & funding subscription__")
    const createSubscriptionTx = await registry.createSubscription()
    const createSubscriptionReceipt = await createSubscriptionTx.wait(1)
    const subscriptionId = createSubscriptionReceipt.events[0].args["subscriptionId"].toNumber()
    const juelsAmount = ethers.utils.parseUnits("10")
    await linkToken.transferAndCall(
      registry.address,
      juelsAmount,
      ethers.utils.defaultAbiCoder.encode(["uint64"], [subscriptionId])
    )

    const functionpath = taskArgs.functionpath
    if (functionpath == "") {
      throw Error("Function path is empty")
    }

    // Build the parameters to make a request from the client contract
    console.log("\n__Build request config__")
    const unvalidatedRequestConfig = {
      codeLocation: 0,
      codeLanguage: 0,
      source: fs.readFileSync(functionpath).toString(),
      secrets: { apiKey: process.env.METEOBLUE_API_KEY ?? "" },
      perNodeSecrets: [],
      walletPrivateKey: process.env["PRIVATE_KEY"],
      args: ["1684724400", "1684983599", "25761527", "-80194972", "1000000", "100"],
      //expectedReturnType: "uint256",
      expectedReturnType: "Buffer",
      secretsURLs: [],
    }

    const requestConfig = getRequestConfig(unvalidatedRequestConfig)
    // Fetch the mock DON public key
    const DONPublicKey = await oracle.getDONPublicKey()
    // Remove the preceding 0x from the DON public key
    requestConfig.DONPublicKey = DONPublicKey.slice(2)
    const request = await buildRequest(requestConfig)

    // console.log("\n__Request config below__")
    // console.log(request);

    // console.log("\__Request args below__")
    startDate = request.args[0]
    endDate = request.args[1]
    lat = request.args[2]
    lng = request.args[3]
    coordMultiplier = request.args[4]
    precMultiplier = request.args[5]
    secrets = request.secrets ?? []
    source = request.source

    // console.log(`${startDate}, ${endDate}, ${lat}, ${lng}, ${coordMultiplier}, ${precMultiplier}, ${secrets}`)
    // console.log(`secrets: ${secrets}`);

    console.log("\n__Deploying the client contract__")

    // Deploy the client contract
    const gifRegistry = "0x4C9fCDB1df601cd1F01fb006290A7F371CeC1aCd"
    const clientName = ethers.utils.formatBytes32String("RainOracleCLFunctions")
    const clientFactory = await ethers.getContractFactory("RainOracleCLFunctions")
    const client = await deployClientContract(
      clientFactory,
      clientName,
      gifRegistry,
      oracle.address,
      subscriptionId,
      gasLimit
    )
    await client.deployTransaction.wait(1)
    console.log("__Client Deploy is done__")

    console.log("__Adding consumer__")
    // Authorize the client contract to use the subscription
    await registry.addConsumer(subscriptionId, client.address)

    // Make a request & simulate a fulfillment
    await new Promise(async (resolve) => {
      const clientContract = await clientFactory.attach(client.address)

      console.log("__ABI Encode request params__")
      const input = await clientContract.encodeRequestParameters(
        startDate,
        endDate,
        lat,
        lng,
        coordMultiplier,
        precMultiplier,
        secrets,
        source
      )
      //console.log(input)
      gifRequestId = 1

      // Initiate the request from the client contract
      console.log("__Initiating the request from the client contract__")

      const requestTx = await clientContract.request(gifRequestId, input)

      //TEST
      // const policyId = "0xda6e04c64fd5599ee4e0cbe0795661d6ed9baa62349e62c934500e98dbb39ab5"
      // const requestTx = await clientContract.indirectRequest(policyId, secrets, source)
      //TEST END

      const requestTxReceipt = await requestTx.wait(1)
      const requestId = requestTxReceipt.events[2].args.id
      const requestGasUsed = requestTxReceipt.gasUsed.toString()

      // Simulating the JavaScript code locally
      console.log("\nExecuting JavaScript request source code locally...")

      const { success, result, resultLog } = await simulateRequest(requestConfig)
      console.log(`\n${resultLog}`)

      // Simulate a request fulfillment
      const accounts = await ethers.getSigners()
      const dummyTransmitter = accounts[0].address
      const dummySigners = Array(31).fill(dummyTransmitter)
      let i = 0
      try {
        const fulfillTx = await registry.fulfillAndBill(
          requestId,
          success ? result : "0x",
          success ? "0x" : result,
          dummyTransmitter,
          dummySigners,
          4,
          100_000,
          500_000,
          {
            gasLimit: 500_000,
          }
        )
        await fulfillTx.wait(1)
      } catch (fulfillError) {
        // Catch & report any unexpected fulfillment errors
        console.log("\nUnexpected error encountered when calling fulfillRequest in client contract.")
        console.log(fulfillError)
        resolve()
      }

      // Listen for the OCRResponse event & log the simulated response returned to the client contract
      client.on("OCRResponse", async (eventRequestId, result, err) => {
        console.log("__Simulated On-Chain Response__")
        if (eventRequestId !== requestId) {
          throw Error(`${eventRequestId} is not equal to ${requestId}`)
        }
        // Check for & log a successful request
        console.log("__Check for & log a successful request__")
        if (result !== "0x") {
          console.log(
            `Response returned to client contract represented as a hex string: ${result}\n${getDecodedResultLog(
              requestConfig,
              result
            )}`
          )
        }
        // Check for & log a request that returned an error message
        console.log("__Check for & log a request that returned an error message__")
        if (err !== "0x") {
          console.log(`Error message returned to client contract: "${Buffer.from(err.slice(2), "hex")}"\n`)
        }
      })

      // Listen for the BillingEnd event & log the estimated billing data
      console.log("__Listen for the BillingEnd event & log the estimated billing data__")
      registry.on(
        "BillingEnd",
        async (
          eventRequestId,
          eventSubscriptionId,
          eventSignerPayment,
          eventTransmitterPayment,
          eventTotalCost,
          eventSuccess
        ) => {
          if (requestId == eventRequestId) {
            // Check for a successful request & log a message if the fulfillment was not successful
            if (!eventSuccess) {
              console.log(
                "\nError encountered when calling fulfillRequest in client contract.\n" +
                  "Ensure the fulfillRequest function in the client contract is correct and the --gaslimit is sufficient.\n"
              )
            }

            const fulfillGasUsed = await getGasUsedForFulfillRequest(
              clientFactory,
              clientName,
              gifRegistry,
              subscriptionId,
              gasLimit,
              success,
              result
            )
            console.log(`Gas used by sendRequest: ${requestGasUsed}`)
            console.log(`Gas used by client callback function: ${fulfillGasUsed}`)
            return resolve()
          }
        }
      )
    })
  })

const getGasUsedForFulfillRequest = async (
  clientFactory,
  clientName,
  gifRegistry,
  subscriptionId,
  gasLimit,
  success,
  result
) => {
  console.log("__Get gas used for fulfill request__")
  const accounts = await ethers.getSigners()
  const deployer = accounts[0]
  const simulatedRequestId = "0x0000000000000000000000000000000000000000000000000000000000000001"

  const client = await deployClientContract(
    clientFactory,
    clientName,
    gifRegistry,
    deployer.address,
    subscriptionId,
    gasLimit
  )
  client.addSimulatedRequestId(deployer.address, simulatedRequestId)
  await client.deployTransaction.wait(1)
  console.log("__Client Deploy is done params__")

  let txReceipt
  if (success) {
    txReceipt = await client.handleOracleFulfillment(simulatedRequestId, result, [])
  } else {
    txReceipt = await client.handleOracleFulfillment(simulatedRequestId, [], result)
  }
  const txResult = await txReceipt.wait(1)

  return txResult.gasUsed.toString()
}

const deployClientContract = async (
  clientFactory,
  clientName,
  gifRegistry,
  oracleAddress,
  subscriptionId,
  gasLimit
) => {
  console.log("__Constructor params__")
  console.log(`${clientName}, ${gifRegistry}, ${oracleAddress}, ${subscriptionId}, ${gasLimit}`)
  return await clientFactory.deploy(clientName, gifRegistry, oracleAddress, subscriptionId, gasLimit)
}

const deployMockOracle = async () => {
  // Deploy mocks: LINK token & LINK/ETH price feed
  const linkTokenFactory = await ethers.getContractFactory("LinkToken")
  const linkPriceFeedFactory = await ethers.getContractFactory("MockV3Aggregator")
  const linkToken = await linkTokenFactory.deploy()
  const linkPriceFeed = await linkPriceFeedFactory.deploy(0, ethers.BigNumber.from(5021530000000000))
  // Deploy proxy admin
  await upgrades.deployProxyAdmin()
  // Deploy the oracle contract
  const oracleFactory = await ethers.getContractFactory("contracts/dev/functions/FunctionsOracle.sol:FunctionsOracle")
  const oracleProxy = await upgrades.deployProxy(oracleFactory, [], {
    kind: "transparent",
  })
  await oracleProxy.deployTransaction.wait(1)
  // Set the secrets encryption public DON key in the mock oracle contract
  await oracleProxy.setDONPublicKey("0x" + SHARED_DON_PUBLIC_KEY)
  // Deploy the mock registry billing contract
  const registryFactory = await ethers.getContractFactory(
    "contracts/dev/functions/FunctionsBillingRegistry.sol:FunctionsBillingRegistry"
  )
  const registryProxy = await upgrades.deployProxy(
    registryFactory,
    [linkToken.address, linkPriceFeed.address, oracleProxy.address],
    {
      kind: "transparent",
    }
  )
  await registryProxy.deployTransaction.wait(1)
  // Set registry configuration
  const config = {
    maxGasLimit: 300_000,
    stalenessSeconds: 86_400,
    gasAfterPaymentCalculation: 39_173,
    weiPerUnitLink: ethers.BigNumber.from("5000000000000000"),
    gasOverhead: 519_719,
    requestTimeoutSeconds: 300,
  }
  await registryProxy.setConfig(
    config.maxGasLimit,
    config.stalenessSeconds,
    config.gasAfterPaymentCalculation,
    config.weiPerUnitLink,
    config.gasOverhead,
    config.requestTimeoutSeconds
  )
  // Set the current account as an authorized sender in the mock registry to allow for simulated local fulfillments
  const accounts = await ethers.getSigners()
  const deployer = accounts[0]
  await registryProxy.setAuthorizedSenders([oracleProxy.address, deployer.address])
  await oracleProxy.setRegistry(registryProxy.address)
  return { oracle: oracleProxy, registry: registryProxy, linkToken }
}
