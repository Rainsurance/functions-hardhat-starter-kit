// SPDX-License-Identifier: MIT
pragma solidity 0.8.2;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "@etherisc/gif-interface/contracts/components/Product.sol";
import "@etherisc/gif-contracts/contracts/shared/TransferHelper.sol";

contract RainProduct is Product, AccessControl, Initializable {
  using EnumerableSet for EnumerableSet.Bytes32Set;

  bytes32 public constant NAME = "RainProduct";
  bytes32 public constant VERSION = "0.0.1";
  bytes32 public constant POLICY_FLOW = "PolicyDefaultFlow";

  bytes32 public constant INSURER_ROLE = keccak256("INSURER");

  uint256 public constant COORD_MULTIPLIER = 10 ** 6;
  uint256 public constant PERCENTAGE_MULTIPLIER = 2 ** 24;
  uint256 public constant PRECIPITATION_MULTIPLIER = 100;

  uint256 public constant PRECIPITATION_MIN = 0;
  uint256 public constant PRECIPITATION_MAX = 1000;

  struct Risk {
    bytes32 id; // hash over placeId, start, end
    uint256 startDate; // ~ cropId
    uint256 endDate;
    bytes32 placeId; // ~ uaiId
    int256 lat;
    int256 long;
    uint256 trigger; // at and bellow this precipitation no payout is made (%)
    uint256 exit; // at and above this precipitation the max payout is made (%)
    uint256 precHist; // ~aph - historical average precipitation for placeId / period (mm)
    uint256 precDays; // minimum number of rainy days for the risk to be valid (#)
    uint256 requestId;
    bool requestTriggered;
    uint256 responseAt;
    uint256 precActual; // ~aaay - actual average precipitation for placeId / current period (mm)
    uint256 precDaysActual; // actual number of rainy days (#)
    uint256 payoutPercentage; // payout percentage for placeId / current period (%)
    uint256 createdAt;
    uint256 updatedAt;
  }
  struct Process {
    bytes32 riskId;
    bytes32 processId;
    uint256 startDate;
    uint256 endDate;
    bytes32 placeId;
    uint256 precHist;
    uint256 sumInsured;
  }

  uint256 private _oracleId;
  IERC20 private _token;

  // variables
  bytes32[] private _riskIds;
  mapping(bytes32 /* riskId */ => Risk) private _risks;
  mapping(bytes32 /* riskId */ => EnumerableSet.Bytes32Set /* processIds */) private _policies;
  bytes32[] private _applications; // useful for debugging, might need to get rid of this
  mapping(address /* policyHolder */ => bytes32[] /* processIds */) private _processIdsForHolder; // hold list of applications/policies Ids for address
  mapping(address /* policyHolder */ => Process[] /* processIds */) private _processesForHolder; // hold list of applications/policies for address

  // events
  event LogRainPolicyApplicationCreated(
    bytes32 policyId,
    address policyHolder,
    uint256 premiumAmount,
    uint256 sumInsuredAmount
  );
  event LogRainPolicyCreated(bytes32 policyId, address policyHolder, uint256 premiumAmount, uint256 sumInsuredAmount);
  event LogRainOracleCallbackReceived(uint256 requestId, bytes32 processId, bytes fireCategory);
  event LogRainClaimConfirmed(bytes32 processId, uint256 claimId, uint256 payoutAmount);
  event LogRainPayoutExecuted(bytes32 processId, uint256 claimId, uint256 payoutId, uint256 payoutAmount);
  event LogRainRiskDataCreated(bytes32 riskId, bytes32 placeId, uint256 startDate, uint256 endDate);
  event LogRainRiskProcessed(bytes32 riskId, uint256 policies);
  event LogRainPolicyProcessed(bytes32 policyId);
  event LogRainClaimCreated(bytes32 policyId, uint256 claimId, uint256 payoutAmount);
  event LogRainPayoutCreated(bytes32 policyId, uint256 payoutAmount);
  event LogRainRiskDataRequested(
    uint256 requestId,
    bytes32 riskId,
    bytes32 placeId,
    uint256 startDate,
    uint256 endDate
  );
  event LogRainRiskDataRequestCancelled(bytes32 processId, uint256 requestId);
  event LogRainRiskDataReceived(uint256 requestId, bytes32 riskId, uint256 precActual);

  constructor(
    bytes32 productName,
    address registry,
    address token,
    uint256 oracleId,
    uint256 riskpoolId,
    address insurer
  ) Product(productName, token, POLICY_FLOW, riskpoolId, registry) {
    _token = IERC20(token);
    _oracleId = oracleId;

    _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
    _setupRole(INSURER_ROLE, insurer);
  }

  function createRisk(
    uint256 startDate,
    uint256 endDate,
    bytes32 placeId,
    int256 lat,
    int256 long,
    uint256 trigger,
    uint256 exit,
    uint256 precHist
  ) external onlyRole(INSURER_ROLE) returns (bytes32 riskId) {
    _validateRiskParameters(trigger, exit);
    //TODO: uncomment the line below (commented for testing purposes)
    require(startDate > block.timestamp, "ERROR:RAIN-044:RISK_START_DATE_INVALID"); // solhint-disable-line
    require(endDate > startDate, "ERROR:RAIN-045:RISK_END_DATE_INVALID");

    riskId = getRiskId(placeId, startDate, endDate);
    _riskIds.push(riskId);

    Risk storage risk = _risks[riskId];
    require(risk.createdAt == 0, "ERROR:RAIN-001:RISK_ALREADY_EXISTS");

    risk.id = riskId;
    risk.startDate = startDate;
    risk.endDate = endDate;
    risk.placeId = placeId;
    risk.lat = lat;
    risk.long = long;
    risk.trigger = trigger;
    risk.exit = exit;
    risk.precHist = precHist;
    risk.createdAt = block.timestamp; // solhint-disable-line
    risk.updatedAt = block.timestamp; // solhint-disable-line

    emit LogRainRiskDataCreated(risk.id, risk.placeId, risk.startDate, risk.endDate);
  }

  function adjustRisk(bytes32 riskId, uint256 trigger, uint256 exit, uint256 precHist) external onlyRole(INSURER_ROLE) {
    _validateRiskParameters(trigger, exit);

    Risk storage risk = _risks[riskId];
    require(risk.createdAt > 0, "ERROR:RAIN-002:RISK_UNKNOWN");
    require(EnumerableSet.length(_policies[riskId]) == 0, "ERROR:RAIN-003:RISK_WITH_POLICIES_NOT_ADJUSTABLE");

    risk.trigger = trigger;
    risk.exit = exit;
    risk.precHist = precHist;
    risk.updatedAt = block.timestamp; // solhint-disable-line
  }

  function getRiskId(bytes32 placeId, uint256 startDate, uint256 endDate) public pure returns (bytes32 riskId) {
    riskId = keccak256(abi.encode(placeId, startDate, endDate));
  }

  function applyForPolicy(
    address policyHolder,
    uint256 premium,
    uint256 sumInsured,
    bytes32 riskId
  ) external onlyRole(INSURER_ROLE) returns (bytes32 processId) {
    Risk storage risk = _risks[riskId];
    require(risk.createdAt > 0, "ERROR:RAIN-004:RISK_UNDEFINED");
    require(policyHolder != address(0), "ERROR:RAIN-005:POLICY_HOLDER_ZERO");

    bytes memory metaData = "";
    bytes memory applicationData = abi.encode(riskId);

    processId = _newApplication(policyHolder, premium, sumInsured, metaData, applicationData);

    _applications.push(processId);

    // remember for which policy holder this application is
    _processIdsForHolder[policyHolder].push(processId);
    _processesForHolder[policyHolder].push(
      Process(risk.id, processId, risk.startDate, risk.endDate, risk.placeId, risk.precHist, sumInsured)
    );

    emit LogRainPolicyApplicationCreated(processId, policyHolder, premium, sumInsured);

    bool success = _underwrite(processId);

    if (success) {
      EnumerableSet.add(_policies[riskId], processId);

      emit LogRainPolicyCreated(processId, policyHolder, premium, sumInsured);
    }
  }

  function underwrite(bytes32 processId) external onlyRole(INSURER_ROLE) returns (bool success) {
    // ensure the application for processId exists
    _getApplication(processId);
    success = _underwrite(processId);

    if (success) {
      IPolicy.Application memory application = _getApplication(processId);
      IPolicy.Metadata memory metadata = _getMetadata(processId);
      emit LogRainPolicyCreated(processId, metadata.owner, application.premiumAmount, application.sumInsuredAmount);
    }
  }

  function collectPremium(
    bytes32 policyId
  ) external onlyRole(INSURER_ROLE) returns (bool success, uint256 fee, uint256 netPremium) {
    (success, fee, netPremium) = _collectPremium(policyId);
  }

  /* premium collection always moves funds from the customers wallet to the riskpool wallet.
   * to stick to this principle: this method implements a two part transferFrom.
   * the 1st transfer moves the specified amount from the 'from' sender address to the customer
   * the 2nd transfer transfers the amount from the customer to the riskpool wallet (and some
   * fees to the instance wallet)
   */
  function collectPremium(
    bytes32 policyId,
    address from,
    uint256 amount
  ) external onlyRole(INSURER_ROLE) returns (bool success, uint256 fee, uint256 netPremium) {
    IPolicy.Metadata memory metadata = _getMetadata(policyId);

    if (from != metadata.owner) {
      bool transferSuccessful = TransferHelper.unifiedTransferFrom(_token, from, metadata.owner, amount);

      if (!transferSuccessful) {
        return (transferSuccessful, 0, amount);
      }
    }

    (success, fee, netPremium) = _collectPremium(policyId, amount);
  }

  function adjustPremiumSumInsured(
    bytes32 processId,
    uint256 expectedPremiumAmount,
    uint256 sumInsuredAmount
  ) external onlyRole(INSURER_ROLE) {
    _adjustPremiumSumInsured(processId, expectedPremiumAmount, sumInsuredAmount);
  }

  function triggerOracle(
    bytes32 processId,
    bytes calldata secrets,
    string calldata source
  ) external onlyRole(INSURER_ROLE) returns (uint256 requestId) {
    Risk storage risk = _risks[_getRiskId(processId)];
    require(risk.createdAt > 0, "ERROR:RAIN-010:RISK_UNDEFINED");
    require(risk.responseAt == 0, "ERROR:RAIN-011:ORACLE_ALREADY_RESPONDED");

    bytes memory queryData = abi.encode(
      risk.startDate,
      risk.endDate,
      risk.lat,
      risk.long,
      COORD_MULTIPLIER,
      PRECIPITATION_MULTIPLIER,
      secrets,
      source
    );

    requestId = _request(processId, queryData, "oracleCallback", _oracleId);

    risk.requestId = requestId;
    risk.requestTriggered = true;
    risk.updatedAt = block.timestamp; // solhint-disable-line

    emit LogRainRiskDataRequested(risk.requestId, risk.id, risk.placeId, risk.startDate, risk.endDate);
  }

  function cancelOracleRequest(bytes32 processId) external onlyRole(INSURER_ROLE) {
    Risk storage risk = _risks[_getRiskId(processId)];
    require(risk.createdAt > 0, "ERROR:RAIN-012:RISK_UNDEFINED");
    require(risk.requestTriggered, "ERROR:RAIN-013:ORACLE_REQUEST_NOT_FOUND");
    require(risk.responseAt == 0, "ERROR:RAIN-014:EXISTING_CALLBACK");

    _cancelRequest(risk.requestId);

    // reset request id to allow to trigger again
    risk.requestTriggered = false;
    risk.updatedAt = block.timestamp; // solhint-disable-line

    emit LogRainRiskDataRequestCancelled(processId, risk.requestId);
  }

  function oracleCallback(uint256 requestId, bytes32 processId, bytes calldata responseData) external onlyOracle {
    uint256 precActual = abi.decode(responseData, (uint256));

    bytes32 riskId = _getRiskId(processId);

    Risk storage risk = _risks[riskId];
    require(risk.createdAt > 0, "ERROR:RAIN-021:RISK_UNDEFINED");
    require(risk.requestId == requestId, "ERROR:RAIN-022:REQUEST_ID_MISMATCH");
    require(risk.responseAt == 0, "ERROR:RAIN-023:EXISTING_CALLBACK");
    require(precActual >= PRECIPITATION_MIN && precActual < PRECIPITATION_MAX, "ERROR:RAIN-024:AAAY_INVALID");

    // update risk using precActual info
    risk.precActual = precActual;
    risk.payoutPercentage = calculatePayoutPercentage(risk.trigger, risk.exit, risk.precHist, risk.precActual);

    risk.responseAt = block.timestamp; // solhint-disable-line
    risk.updatedAt = block.timestamp; // solhint-disable-line

    emit LogRainRiskDataReceived(requestId, riskId, precActual);
  }

  function processPoliciesForRisk(
    bytes32 riskId,
    uint256 batchSize
  ) external onlyRole(INSURER_ROLE) returns (bytes32[] memory processedPolicies) {
    Risk memory risk = _risks[riskId];
    require(risk.responseAt > 0, "ERROR:RAIN-030:ORACLE_RESPONSE_MISSING");

    uint256 elements = EnumerableSet.length(_policies[riskId]);
    if (elements == 0) {
      emit LogRainRiskProcessed(riskId, 0);
      return new bytes32[](0);
    }

    if (batchSize == 0) {
      batchSize = elements;
    } else {
      batchSize = min(batchSize, elements);
    }

    processedPolicies = new bytes32[](batchSize);
    uint256 elementIdx = elements - 1;

    for (uint256 i = 0; i < batchSize; i++) {
      // grab and process the last policy
      bytes32 policyId = EnumerableSet.at(_policies[riskId], elementIdx - i);
      processPolicy(policyId);
      processedPolicies[i] = policyId;
    }

    emit LogRainRiskProcessed(riskId, batchSize);
  }

  function processPolicy(bytes32 policyId) public onlyRole(INSURER_ROLE) {
    IPolicy.Application memory application = _getApplication(policyId);
    bytes32 riskId = abi.decode(application.data, (bytes32));
    Risk memory risk = _risks[riskId];

    require(risk.id == riskId, "ERROR:RAIN-031:RISK_ID_INVALID");
    require(risk.responseAt > 0, "ERROR:RAIN-032:ORACLE_RESPONSE_MISSING");
    require(EnumerableSet.contains(_policies[riskId], policyId), "ERROR:RAIN-033:POLICY_FOR_RISK_UNKNOWN");

    EnumerableSet.remove(_policies[riskId], policyId);

    uint256 claimAmount = calculatePayout(risk.payoutPercentage, application.sumInsuredAmount);

    uint256 claimId = _newClaim(policyId, claimAmount, "");
    emit LogRainClaimCreated(policyId, claimId, claimAmount);

    if (claimAmount > 0) {
      uint256 payoutAmount = claimAmount;
      _confirmClaim(policyId, claimId, payoutAmount);

      uint256 payoutId = _newPayout(policyId, claimId, payoutAmount, "");
      _processPayout(policyId, payoutId);

      emit LogRainPayoutCreated(policyId, payoutAmount);
    } else {
      _declineClaim(policyId, claimId);
      _closeClaim(policyId, claimId);
    }

    _expire(policyId);
    _close(policyId);

    emit LogRainPolicyProcessed(policyId);
  }

  function calculatePayout(
    uint256 payoutPercentage,
    uint256 sumInsuredAmount
  ) public pure returns (uint256 payoutAmount) {
    payoutAmount = (payoutPercentage * sumInsuredAmount) / PERCENTAGE_MULTIPLIER;
  }

  function calculatePayoutPercentage(
    uint256 trigger, // at and bellow this precipitation no payout is made (%)
    uint256 exit, // at and above this precipitation the max payout is made (%)
    uint256 precHist, // historical precipitation for placeId (mm)
    uint256 precActual // actual precipitation for placeId in the current period (mm)
  ) public pure returns (uint256 payoutPercentage) {
    if (precActual <= precHist) {
      return 0;
    }
    uint256 extra = (PERCENTAGE_MULTIPLIER * (precActual - precHist)) / precHist;
    if (extra <= trigger) {
      return 0;
    }
    // calculated payout between exit and trigger
    payoutPercentage = min(PERCENTAGE_MULTIPLIER, (PERCENTAGE_MULTIPLIER * extra) / exit);
  }

  function getPercentageMultiplier() external pure returns (uint256 multiplier) {
    return PERCENTAGE_MULTIPLIER;
  }

  function getCoordinatesMultiplier() external pure returns (uint256 multiplier) {
    return COORD_MULTIPLIER;
  }

  function getPrecipitationMultiplier() external pure returns (uint256 multiplier) {
    return PRECIPITATION_MULTIPLIER;
  }

  function min(uint256 a, uint256 b) private pure returns (uint256) {
    return a <= b ? a : b;
  }

  // function s2b(string memory input) public pure returns (bytes32 output) {
  //     output = bytes32(abi.encodePacked(input));
  // }

  // function b2s(bytes32 input) public pure returns (string memory output) {
  //     output = string(abi.encodePacked(input));
  // }

  function risks() external view returns (uint256) {
    return _riskIds.length;
  }

  function getRiskId(uint256 idx) external view returns (bytes32 riskId) {
    return _riskIds[idx];
  }

  function getRisk(bytes32 riskId) external view returns (Risk memory risk) {
    return _risks[riskId];
  }

  function applications() external view returns (uint256 applicationCount) {
    return _applications.length;
  }

  function getApplicationId(uint256 applicationIdx) external view returns (bytes32 processId) {
    return _applications[applicationIdx];
  }

  function policies(bytes32 riskId) external view returns (uint256 policyCount) {
    return EnumerableSet.length(_policies[riskId]);
  }

  function getPolicyId(bytes32 riskId, uint256 policyIdx) external view returns (bytes32 processId) {
    return EnumerableSet.at(_policies[riskId], policyIdx);
  }

  function processIdsForHolder(address policyHolder) external view returns (bytes32[] memory) {
    return _processIdsForHolder[policyHolder];
  }

  function processForHolder(address policyHolder, uint256 processIdx) external view returns (Process memory) {
    return _processesForHolder[policyHolder][processIdx];
  }

  function getProcessId(address policyHolder, uint256 idx) external view returns (bytes32 processId) {
    require(_processIdsForHolder[policyHolder].length > 0, "ERROR:RAIN-050:NO_POLICIES");
    return _processIdsForHolder[policyHolder][idx];
  }

  function getOracleId() external view returns (uint256 oracleId) {
    return _oracleId;
  }

  function _validateRiskParameters(uint256 trigger, uint256 exit) internal pure {
    require(trigger <= PERCENTAGE_MULTIPLIER, "ERROR:RAIN-041:RISK_TRIGGER_TOO_LARGE");
    require(exit > trigger, "ERROR:RAIN-042:RISK_EXIT_NOT_LARGER_THAN_TRIGGER");
    //require(precHist >= 0, "ERROR:RAIN-043:RISK_APH_ZERO_INVALID");
  }

  function _getRiskId(bytes32 processId) private view returns (bytes32 riskId) {
    IPolicy.Application memory application = _getApplication(processId);
    (riskId) = abi.decode(application.data, (bytes32));
  }
}
