// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/OwnableInterface.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title The ConfirmedOwnerUpgradeable contract
 * @notice An upgrade compatible contract with helpers for basic contract ownership.
 */
contract ConfirmedOwnerUpgradeable is Initializable, OwnableInterface {
  address private s_owner;
  address private s_pendingOwner;

  event OwnershipTransferRequested(address indexed from, address indexed to);
  event OwnershipTransferred(address indexed from, address indexed to);

  /**
   * @dev Initializes the contract in unpaused state.
   */
  function __ConfirmedOwner_initialize(address newOwner, address pendingOwner) internal onlyInitializing {
    if (newOwner == address(0)) {
      revert("ERROR:OwnerMustBeSet");
    }

    s_owner = newOwner;
    if (pendingOwner != address(0)) {
      _transferOwnership(pendingOwner);
    }
  }

  /**
   * @notice Allows an owner to begin transferring ownership to a new address,
   * pending.
   */
  function transferOwnership(address to) public override onlyOwner {
    _transferOwnership(to);
  }

  /**
   * @notice Allows an ownership transfer to be completed by the recipient.
   */
  function acceptOwnership() external override {
    if (msg.sender != s_pendingOwner) {
      revert("ERROR:NotProposedOwner");
    }

    address oldOwner = s_owner;
    s_owner = msg.sender;
    s_pendingOwner = address(0);

    emit OwnershipTransferred(oldOwner, msg.sender);
  }

  /**
   * @notice Get the current owner
   */
  function owner() public view override returns (address) {
    return s_owner;
  }

  /**
   * @notice validate, transfer ownership, and emit relevant events
   */
  function _transferOwnership(address to) private {
    if (to == msg.sender) {
      revert("ERROR:CannotSelfTransfer");
    }

    s_pendingOwner = to;

    emit OwnershipTransferRequested(s_owner, to);
  }

  /**
   * @notice validate access
   */
  function _validateOwnership() internal view {
    if (msg.sender != s_owner) {
      revert("ERROR:OnlyCallableByOwner");
    }
  }

  /**
   * @notice Reverts if called by anyone other than the contract owner.
   */
  modifier onlyOwner() {
    _validateOwnership();
    _;
  }
}
