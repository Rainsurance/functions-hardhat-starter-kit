const { networks } = require("../../networks")

// npx hardhat functions-sub-create --network polygonMumbai --amount 1

// Created subscription with ID: 550
// Owner: 0xe220825b597e4D5867218E0Efa9684Dd26957b00

// authorized consumer contracts for subscription 550:
// [
//   '0x915bc4E84f348952E16320c1adbAE4119EefB147', -> FunctionsConsumer
//   '0xd5359d7097cC3E112e75E4af79418Db316d426fD', -> RainOracle CL Functions
//   '0x6424B8917f9A18A24d6001F14D82ce69F54726a7', -> RainProduct
//   '0x6030A6e9BB4D09d6732Fda63b0C5C9E5a76d340F', -> Insurer EOA
//   '0xFCc026DbeD1FaB63C4ec517D1F4B58A63bdfd136',
//   '0xB59EF5D36eC439fF9e98746Fe7944275e81B0e45' -> RainOracle CL Functions new
//   '0x307ba83B5BfA2215D1aeB90Cadb52ffF56F27868' -> RainProduct new
//   '0xf6095B7750AC506E757550A8C015CfAc30EaEFf5' -> RainOracle CL Functions with Automation
//   '0x0963e107D43b2452c825eaa02743083dcc723045' -> RainOracle CL Functions with Automation 2023.06.07
// ]

task("functions-sub-create", "Creates a new billing subscription for Functions consumer contracts")
  .addOptionalParam("amount", "Initial amount used to fund the subscription in LINK")
  .addOptionalParam("contract", "Address of the client contract address authorized to use the new billing subscription")
  .setAction(async (taskArgs) => {
    if (network.name === "hardhat") {
      throw Error(
        'This command cannot be used on a local hardhat chain.  Specify a valid network or simulate a request locally with "npx hardhat functions-simulate".'
      )
    }

    const linkAmount = taskArgs.amount
    const consumer = taskArgs.contract

    const RegistryFactory = await ethers.getContractFactory(
      "contracts/dev/functions/FunctionsBillingRegistry.sol:FunctionsBillingRegistry"
    )
    const registry = await RegistryFactory.attach(networks[network.name]["functionsBillingRegistryProxy"])

    // TODO: Remove the following 6 lines on open access
    const Oracle = await ethers.getContractFactory("contracts/dev/functions/FunctionsOracle.sol:FunctionsOracle")
    const oracle = await Oracle.attach(networks[network.name]["functionsOracleProxy"])
    const isWalletAllowed = await oracle.isAuthorizedSender((await ethers.getSigner()).address)

    if (!isWalletAllowed)
      return console.log(
        "\nChainlink Functions is currently in a closed testing phase.\nFor access sign up here:\nhttps://functions.chain.link"
      )

    console.log("Creating Functions billing subscription")
    const createSubscriptionTx = await registry.createSubscription()

    // If a consumer or linkAmount was also specified, wait 1 block instead of networks[network.name].confirmations blocks
    const createWaitBlockConfirmations = consumer || linkAmount ? 1 : networks[network.name].confirmations
    console.log(
      `Waiting ${createWaitBlockConfirmations} blocks for transaction ${createSubscriptionTx.hash} to be confirmed...`
    )
    const createSubscriptionReceipt = await createSubscriptionTx.wait(createWaitBlockConfirmations)

    const subscriptionId = createSubscriptionReceipt.events[0].args["subscriptionId"].toNumber()

    console.log(`Subscription created with ID: ${subscriptionId}`)

    if (linkAmount) {
      // Fund subscription
      const juelsAmount = ethers.utils.parseUnits(linkAmount)

      const LinkTokenFactory = await ethers.getContractFactory("LinkToken")
      const linkToken = await LinkTokenFactory.attach(networks[network.name]["linkToken"])

      const accounts = await ethers.getSigners()
      const signer = accounts[0]

      // Check for a sufficent LINK balance to fund the subscription
      const balance = await linkToken.balanceOf(signer.address)
      if (juelsAmount.gt(balance)) {
        throw Error(
          `Insufficent LINK balance. Trying to fund subscription with ${ethers.utils.formatEther(
            juelsAmount
          )} LINK, but only have ${ethers.utils.formatEther(balance)}.`
        )
      }

      console.log(`Funding with ${ethers.utils.formatEther(juelsAmount)} LINK`)
      const fundTx = await linkToken.transferAndCall(
        networks[network.name]["functionsBillingRegistryProxy"],
        juelsAmount,
        ethers.utils.defaultAbiCoder.encode(["uint64"], [subscriptionId])
      )
      // If a consumer was also specified, wait 1 block instead of networks[network.name].confirmations blocks
      const fundWaitBlockConfirmations = !!consumer ? 1 : networks[network.name].confirmations
      console.log(`Waiting ${fundWaitBlockConfirmations} blocks for transaction ${fundTx.hash} to be confirmed...`)
      await fundTx.wait(fundWaitBlockConfirmations)

      console.log(`Subscription ${subscriptionId} funded with ${ethers.utils.formatEther(juelsAmount)} LINK`)
    }

    if (consumer) {
      // Add consumer
      console.log(`Adding consumer contract address ${consumer} to subscription ${subscriptionId}`)
      const addTx = await registry.addConsumer(subscriptionId, consumer)
      console.log(
        `Waiting ${networks[network.name].confirmations} blocks for transaction ${addTx.hash} to be confirmed...`
      )
      await addTx.wait(networks[network.name].confirmations)

      console.log(`Authorized consumer contract: ${consumer}`)
    }

    const subInfo = await registry.getSubscription(subscriptionId)
    console.log(`\nCreated subscription with ID: ${subscriptionId}`)
    console.log(`Owner: ${subInfo[1]}`)
    console.log(`Balance: ${ethers.utils.formatEther(subInfo[0])} LINK`)
    console.log(`${subInfo[2].length} authorized consumer contract${subInfo[2].length === 1 ? "" : "s"}:`)
    console.log(subInfo[2])
  })
