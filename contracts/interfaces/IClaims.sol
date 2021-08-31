// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-v4/token/ERC721/IERC721Receiver.sol";

interface IClaims is IERC721Receiver {

  /* ========== DATA STRUCTURES ========== */

  enum UintParams {
    claimAssessmentDepositRatio
  }

  struct Configuration {
    // Ratio out of 1 ETH, used to calculate a flat ETH deposit required for claim submission.
    // If the claim is accepted, the user will receive the deposit back when the payout is redeemed.
    // (0-10000 bps i.e. double decimal precision)
    uint16 claimAssessmentDepositRatio;
  }

  /*
   *  Holds the requested amount, NXM price, submission fee and other relevant details
   *  such as parts of the corresponding cover details and the payout status.
   *
   *  This structure has snapshots of claim-time states that are considered moving targets
   *  but also parts of cover details that reduce the need of external calls. Everything is fitted
   *  in a single word that contains:
   */
  struct Claim {
    // The index of the assessment, stored in Assessment.sol
    uint80 assessmentId;
   // The identifier of the cover on which this claim is submitted
    uint32 coverId;
   // Amount requested as part of this claim up to the total cover amount
    uint96 amount;
   // The index of of the asset address stored at addressOfAsset which is expected at payout.
    uint8 payoutAsset;
   // A snapshot of claimAssessmentDepositRatio if it is changed before the payout
    uint16 assessmentDepositRatio;
   // True when the payout is redeemed. Prevents further payouts on the claim.
    bool payoutRedeemed;
  }

  /* ========== VIEWS ========== */

  function claims(uint id) external view returns (
    uint80 assessmentId,
    uint32 coverId,
    uint96 amount,
    uint8 payoutAsset,
    uint16 assessmentDepositRatio,
    bool payoutRedeemed
  );

  /*
   *  Claim structure but in a human-friendly format.
   *
   *  Contains aggregated values that give an overall view about the claim and other relevant
   *  pieces of information such as cover period, asset symbol etc. This structure is not used in
   *  any storage variables.
   */
  struct ClaimDisplay {
    uint id;
    uint productId;
    uint coverId;
    uint amount;
    string assetSymbol;
    uint coverStart;
    uint coverEnd;
    uint start;
    uint end;
    string claimStatus;
    string payoutStatus;
  }


  function claimants(uint id) external view returns (address);

  function getClaimsCount() external view returns (uint);

  /* === MUTATIVE FUNCTIONS ==== */

  function submitClaim(
    uint24 coverId,
    uint96 requestedAmount,
    bool hasProof,
    string calldata ipfsProofHash
  ) external payable;

  function redeemClaimPayout(uint104 id) external;

  function redeemCoverForDeniedClaim(uint coverId, uint claimId) external;

  function updateUintParameters(UintParams[] calldata paramNames, uint[] calldata values) external;

  /* ========== EVENTS ========== */

  event ClaimSubmitted(address user, uint104 claimId, uint32 coverId, uint24 productId);
  event ProofSubmitted(uint indexed coverId, address indexed owner, string ipfsHash);
  event ClaimPayoutRedeemed(address indexed user, uint256 amount, uint104 claimId);

}
