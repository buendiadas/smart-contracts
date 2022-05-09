// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.9;

import "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import "../../interfaces/IPool.sol";
import "../../interfaces/IGovernance.sol";
import "../../interfaces/IMemberRoles.sol";
import "../../interfaces/IQuotationData.sol";
import "../../interfaces/ITokenController.sol";
import "../../interfaces/ICover.sol";
import "../../interfaces/INXMToken.sol";
import "../../interfaces/IStakingPool.sol";
import "../../abstract/LegacyMasterAware_sol0_8.sol";
import "./external/Governed.sol";

contract MemberRoles is IMemberRoles, Governed, LegacyMasterAware {
  uint public constant joiningFee = 2000000000000000; // 0.002 Ether

  ITokenController public tc;
  address payable public poolAddress;
  address public kycAuthAddress;
  ICover internal cover;
  IGovernance internal gv;
  address internal _unused1;
  INXMToken public tk;

  struct MemberRoleDetails {
    uint memberCounter;
    mapping(address => bool) memberActive;
    address[] memberAddress;
    address authorized;
  }

  MemberRoleDetails[] internal memberRoleData;
  bool internal constructorCheck;
  uint public maxABCount;
  bool public launched;
  uint public launchedOn;

  // This slot was previously used as a mapping (address => address payable)
  mapping(address => address payable) public _unused2;
  mapping(address => bool) public refundEligible;
  mapping(address => address payable) public approvedMembership;

  modifier checkRoleAuthority(uint _memberRoleId) {
    if (memberRoleData[_memberRoleId].authorized != address(0))
      require(msg.sender == memberRoleData[_memberRoleId].authorized);
    else
      require(isAuthorizedToGovern(msg.sender), "Not Authorized");
    _;
  }

  /**
   * @dev to swap advisory board member
   * @param _newABAddress is address of new AB member
   * @param _removeAB is advisory board member to be removed
   */
  function swapABMember(
    address _newABAddress,
    address _removeAB
  )
  external
  checkRoleAuthority(uint(Role.AdvisoryBoard)) {

    _updateRole(_newABAddress, uint(Role.AdvisoryBoard), true);
    _updateRole(_removeAB, uint(Role.AdvisoryBoard), false);

  }

  /**
   * @dev to change max number of AB members allowed
   * @param _val is the new value to be set
   */
  function changeMaxABCount(uint _val) external onlyInternal {
    maxABCount = _val;
  }

  /**
   * @dev to set address of kyc authentication
   * @param _add is the new address
   */
  function setKycAuthAddress(address _add) external onlyGovernance {
    kycAuthAddress = _add;
  }

  /**
   * @dev Iupgradable Interface to update dependent contract address
   */
  function changeDependentContractAddress() public {
    if (kycAuthAddress == 0x1776651F58a17a50098d31ba3C3cD259C1903f7A) {
      kycAuthAddress = IQuotationData(0x1776651F58a17a50098d31ba3C3cD259C1903f7A).kycAuthAddress();
    }
    gv = IGovernance(ms.getLatestAddress("GV"));
    tk = INXMToken(ms.tokenAddress());
    tc = ITokenController(ms.getLatestAddress("TC"));
    poolAddress = payable(ms.getLatestAddress("P1"));
    cover = ICover(ms.getLatestAddress("CO"));
  }

  /**
   * @dev to change the master address
   * @param _masterAddress is the new master address
   */
  function changeMasterAddress(address _masterAddress) public override {

    if (masterAddress != address(0)) {
      require(masterAddress == msg.sender);
    }

    masterAddress = _masterAddress;
    ms = INXMMaster(_masterAddress);
    nxMasterAddress = _masterAddress;
  }

  /**
   * @dev to initiate the member roles
   * @param _firstAB is the address of the first AB member
   * @param memberAuthority is the authority (role) of the member
   */
  function memberRolesInitiate(address _firstAB, address memberAuthority) public {
    require(!constructorCheck);
    _addInitialMemberRoles(_firstAB, memberAuthority);
    constructorCheck = true;
  }

  /// @dev Adds new member role
  /// @param _roleName New role name
  /// @param _roleDescription New description hash
  /// @param _authorized Authorized member against every role id
  function addRole(//solhint-disable-line
    bytes32 _roleName,
    string memory _roleDescription,
    address _authorized
  )
  public
  onlyAuthorizedToGovern {
    _addRole(_roleName, _roleDescription, _authorized);
  }

  /// @dev Assign or Delete a member from specific role.
  /// @param _memberAddress Address of Member
  /// @param _roleId RoleId to update
  /// @param _active active is set to be True if we want to assign this role to member, False otherwise!
  function updateRole(//solhint-disable-line
    address _memberAddress,
    uint _roleId,
    bool _active
  )
  public
  checkRoleAuthority(_roleId) {
    _updateRole(_memberAddress, _roleId, _active);
  }

  /// Finalises the sign up process for the user address by allowing the joining fee to be paid.
  ///
  /// @param _userAddress  The address of the user for whom the joining fee is paid.
  function payJoiningFee(address _userAddress) public override payable {
    require(_userAddress != address(0));
    require(!ms.isPause(), "MemberRoles: Emergency Pause Applied");
    require(!checkRole(_userAddress, uint(Role.Member)));
    require(
      msg.value == joiningFee,
      "MemberRoles: The transaction value should equal to the joining fee"
    );
    require(approvedMembership[_userAddress], "MemberRoles: Membership not approved");
    tc.addToWhitelist(_userAddress);
    _updateRole(_userAddress, uint(Role.Member), true);
    (bool ok, /* data */) = poolAddress.call{value: joiningFee}("");
    require(ok, "MemberRoles: Joining fee pool transfer failed");
  }

  /// Approves the user's address membership.
  ///
  /// @dev It's used to perform KYC by kycAuthAddress. After aproval, the user address will be
  /// allowed to call the payJoiningFee function.
  ///
  /// @param _userAddress  The address of the user whose membership should be approved.
  function signUpMember(address payable _userAddress) public override {
    require(msg.sender == kycAuthAddress);
    require(!ms.isPause(), "MemberRoles: Emergency Pause Applied");
    require(_userAddress != address(0), "MemberRoles: Invalid user address");
    require(!ms.isMember(_userAddress), "MemberRoles: Already a member");
    approvedMembership[_userAddress] = true;
  }

  /**
   * @dev withdraws membership for msg.sender if currently a member.
   */
  function withdrawMembership() public {

    require(!ms.isPause() && ms.isMember(msg.sender));
    // No locked tokens for Member/Governance voting
    require(block.timestamp > tk.isLockedForMV(msg.sender));

    gv.removeDelegation(msg.sender);
    tc.burnFrom(msg.sender, tk.balanceOf(msg.sender));
    _updateRole(msg.sender, uint(Role.Member), false);
    tc.removeFromWhitelist(msg.sender); // need clarification on whitelist

    // [todo] Should we also remove the user from the approvedMembership mapping? In case they
    // want to rejoin I wouldn't see the need for kycAuthAddress to make that transaction again
    // as long as the user was already KYCed.

  }

  /**
   * @dev switches membership for msg.sender to the specified address.
   * @param newAddress address of user to forward membership.
   */
  function switchMembership(address newAddress) external override {
    _switchMembership(msg.sender, newAddress);
    tk.transferFrom(msg.sender, newAddress, tk.balanceOf(msg.sender));
  }

  /// Switches membership for msg.sender to the specified address and transfers the senders'
  /// assets in a single transaction.
  ///
  /// @param newAddress    Address of user to forward membership.
  /// @param coverIds      Array of cover ids to transfer to the new address.
  /// @param stakingPools  Array of staking pool addresses where the user has LP tokens.
  function switchMembershipAndAssets(
    address newAddress,
    uint[] calldata coverIds,
    address[] calldata stakingPools
  ) external override {
    _switchMembership(msg.sender, newAddress);
    tk.transferFrom(msg.sender, newAddress, tk.balanceOf(msg.sender));

    // Transfer the cover NFTs to the new address, if any were given
    cover.transferCovers(msg.sender, newAddress, coverIds);

    stakingPools;
    // [todo] Transfer staking pool NFTS to newAddress
    /*
    // Transfer the staking LP tokens to the new address, if any were given
    for (uint256 i = 0; i < stakingPools.length; i++) {
      IStakingPool stakingLPToken = IStakingPool(stakingPools[i]);
      uint fullAmount = stakingLPToken.balanceOf(msg.sender);
      stakingLPToken.operatorTransferFrom(msg.sender, newAddress, fullAmount);
    }
    */
  }

  function switchMembershipOf(address member, address newAddress) external override onlyInternal {
    _switchMembership(member, newAddress);
  }

  function storageCleanup() external {
    _unused1 = 0x0000000000000000000000000000000000000000;
    _unused2[0x181Aea6936B407514ebFC0754A37704eB8d98F91] = payable(0x0000000000000000000000000000000000000000);
  }

  /**
   * @dev switches membership for member to the specified address.
   * @param newAddress address of user to forward membership.
   */
  function _switchMembership(address member, address newAddress) internal {

    require(!ms.isPause(), "System is paused");
    require(ms.isMember(member), "The current address is not a member");
    require(!ms.isMember(newAddress), "The new address is already a member");
    require(block.timestamp > tk.isLockedForMV(member), "Locked for governance voting"); // No locked tokens for Governance voting

    gv.removeDelegation(member);
    tc.addToWhitelist(newAddress);
    _updateRole(newAddress, uint(Role.Member), true);
    _updateRole(member, uint(Role.Member), false);
    tc.removeFromWhitelist(member);

    emit switchedMembership(member, newAddress, block.timestamp);
  }

  /// @dev Return number of member roles
  function totalRoles() public override view returns (uint256) {//solhint-disable-line
    return memberRoleData.length;
  }

  /// @dev Change Member Address who holds the authority to Add/Delete any member from specific role.
  /// @param _roleId roleId to update its Authorized Address
  /// @param _newAuthorized New authorized address against role id
  function changeAuthorized(
    uint _roleId,
    address _newAuthorized
  ) public override checkRoleAuthority(_roleId) {//solhint-disable-line
    memberRoleData[_roleId].authorized = _newAuthorized;
  }

  /// @dev Gets the member addresses assigned by a specific role
  /// @param _memberRoleId  Member role id
  /// @return roleId        Role id
  /// @return memberArray   Member addresses of specified role id
  function members(
    uint _memberRoleId
  ) public override view returns (uint, address[] memory memberArray) {//solhint-disable-line
    uint length = memberRoleData[_memberRoleId].memberAddress.length;
    uint i;
    uint j = 0;
    memberArray = new address[](memberRoleData[_memberRoleId].memberCounter);
    for (i = 0; i < length; i++) {
      address member = memberRoleData[_memberRoleId].memberAddress[i];
      if (memberRoleData[_memberRoleId].memberActive[member] && !_checkMemberInArray(member, memberArray)) {//solhint-disable-line
        memberArray[j] = member;
        j++;
      }
    }

    return (_memberRoleId, memberArray);
  }

  /// @dev Gets all members' length
  /// @param _memberRoleId Member role id
  /// @return memberRoleData[_memberRoleId].memberCounter Member length
  function numberOfMembers(
    uint _memberRoleId
  ) public override view returns (uint) {//solhint-disable-line
    return memberRoleData[_memberRoleId].memberCounter;
  }

  /// @dev Return member address who holds the right to add/remove any member from specific role.
  function authorized(
    uint _memberRoleId
  ) public override view returns (address) {//solhint-disable-line
    return memberRoleData[_memberRoleId].authorized;
  }

  /// @dev Get All role ids array that has been assigned to a member so far.
  function roles(
    address _memberAddress
  ) public override view returns (uint[] memory) {//solhint-disable-line
    uint length = memberRoleData.length;
    uint[] memory assignedRoles = new uint[](length);
    uint counter = 0;
    for (uint i = 1; i < length; i++) {
      if (memberRoleData[i].memberActive[_memberAddress]) {
        assignedRoles[counter] = i;
        counter++;
      }
    }
    return assignedRoles;
  }

  /// @dev Returns true if the given role id is assigned to a member.
  /// @param _memberAddress Address of member
  /// @param _roleId Checks member's authenticity with the roleId.
  /// i.e. Returns true if this roleId is assigned to member
  function checkRole(
    address _memberAddress,
    uint _roleId
  ) public override view returns (bool) {//solhint-disable-line
    if (_roleId == uint(Role.UnAssigned))
      return true;
    else
      if (memberRoleData[_roleId].memberActive[_memberAddress]) //solhint-disable-line
        return true;
      else
        return false;
  }

  /// @dev Return total number of members assigned against each role id.
  /// @return totalMembers Total members in particular role id
  function getMemberLengthForAllRoles() public override view returns (
    uint[] memory totalMembers
  ) {//solhint-disable-line
    totalMembers = new uint[](memberRoleData.length);
    for (uint i = 0; i < memberRoleData.length; i++) {
      totalMembers[i] = numberOfMembers(i);
    }
  }

  /**
   * @dev to update the member roles
   * @param _memberAddress in concern
   * @param _roleId the id of role
   * @param _active if active is true, add the member, else remove it
   */
  function _updateRole(address _memberAddress,
    uint _roleId,
    bool _active) internal {
    // require(_roleId != uint(Role.TokenHolder), "Membership to Token holder is detected automatically");
    if (_active) {
      require(!memberRoleData[_roleId].memberActive[_memberAddress]);
      memberRoleData[_roleId].memberCounter = memberRoleData[_roleId].memberCounter + 1;
      memberRoleData[_roleId].memberActive[_memberAddress] = true;
      memberRoleData[_roleId].memberAddress.push(_memberAddress);
    } else {
      require(memberRoleData[_roleId].memberActive[_memberAddress]);
      memberRoleData[_roleId].memberCounter = memberRoleData[_roleId].memberCounter - 1;
      delete memberRoleData[_roleId].memberActive[_memberAddress];
    }
  }

  /// @dev Adds new member role
  /// @param _roleName New role name
  /// @param _roleDescription New description hash
  /// @param _authorized Authorized member against every role id
  function _addRole(
    bytes32 _roleName,
    string memory _roleDescription,
    address _authorized
  ) internal {
    emit MemberRole(memberRoleData.length, _roleName, _roleDescription);
    MemberRoleDetails storage newMemberRoleData = memberRoleData.push();
    newMemberRoleData.memberCounter = 0;
    newMemberRoleData.memberAddress = new address[](0);
    newMemberRoleData.authorized = _authorized;
  }

  /// @dev Checks if a member address is in the given members array
  /// @param _memberAddress  The address that's checked against memberArray
  /// @param memberArray     Array of member addresses
  /// @return memberExists   True if the member exists
  function _checkMemberInArray(
    address _memberAddress,
    address[] memory memberArray
  )
  internal
  pure
  returns (bool memberExists)
  {
    uint i;
    for (i = 0; i < memberArray.length; i++) {
      if (memberArray[i] == _memberAddress) {
        memberExists = true;
        break;
      }
    }
  }

  /**
   * @dev to add initial member roles
   * @param _firstAB is the member address to be added
   * @param memberAuthority is the member authority(role) to be added for
   */
  function _addInitialMemberRoles(address _firstAB, address memberAuthority) internal {
    maxABCount = 5;
    _addRole("Unassigned", "Unassigned", address(0));
    _addRole(
      "Advisory Board",
      "Selected few members that are deeply entrusted by the dApp. An ideal advisory board should be a mix of skills of domain, governance, research, technology, consulting etc to improve the performance of the dApp.", //solhint-disable-line
      address(0)
    );
    _addRole(
      "Member",
      "Represents all users of Mutual.", //solhint-disable-line
      memberAuthority
    );
    _addRole(
      "Owner",
      "Represents Owner of Mutual.", //solhint-disable-line
      address(0)
    );
    // _updateRole(_firstAB, uint(Role.AdvisoryBoard), true);
    _updateRole(_firstAB, uint(Role.Owner), true);
    // _updateRole(_firstAB, uint(Role.Member), true);
    launchedOn = 0;
  }

  function memberAtIndex(
    uint _memberRoleId,
    uint index
  ) external override view returns (address, bool) {
    address memberAddress = memberRoleData[_memberRoleId].memberAddress[index];
    return (memberAddress, memberRoleData[_memberRoleId].memberActive[memberAddress]);
  }

  function membersLength(
    uint _memberRoleId
  ) external override view returns (uint) {
    return memberRoleData[_memberRoleId].memberAddress.length;
  }
}
