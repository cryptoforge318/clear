// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.11;

import "base64/Base64.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/tokens/ERC1155.sol";
import "./interfaces/IOptionSettlementEngine.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/FixedPointMathLib.sol";
import "./TokenURIGenerator.sol";

/**
 * Valorem Options V1 is a DeFi money lego enabling writing covered call and covered put, physically settled, options.
 * All written options are fully collateralized against an ERC-20 underlying asset and exercised with an
 * ERC-20 exercise asset using a pseudorandom number per unique option type for fair settlement. Options contracts
 * are issued as fungible ERC-1155 tokens, with each token representing a contract. Option writers are additionally issued
 * an ERC-1155 NFT representing a lot of contracts written for claiming collateral and exercise assignment. This design
 * eliminates the need for market price oracles, and allows for permission-less writing, and gas efficient transfer, of
 * a broad swath of traditional options.
 */

/// @notice This settlement protocol does not support rebase tokens, or fee on transfer tokens
contract OptionSettlementEngine is ERC1155, IOptionSettlementEngine {
    /// @notice The protocol fee
    uint8 public immutable feeBps = 5;

    /// @notice The address fees accrue to
    address public feeTo = 0x2dbd50A4Ef9B172698596217b7DB0163D3607b41;

    /// @notice Fee balance for a given token
    mapping(address => uint256) public feeBalance;

    /// @notice Accessor for Option contract details
    mapping(uint160 => Option) internal _option;

    /// @notice Accessor for claim ticket details
    mapping(uint256 => Claim) internal _claim;

    /// @notice Accessor for buckets of claims grouped by day
    /// @dev This is to enable O(constant) time options exercise. When options are written,
    /// the Claim struct in this mapping is updated to reflect the cumulative amount written
    /// on the day in question. write() will add unexercised options into the bucket
    /// corresponding to the # of days after the option type's creation.
    /// exercise() will randomly assign exercise to a bucket <= the current day.
    mapping(uint160 => ClaimBucket[]) internal _claimBucketByOption;

    /// @notice Accessor for mapping a claim id to its ClaimIndices
    mapping(uint256 => ClaimIndex[]) internal _claimIdToClaimIndexArray;

    /// @inheritdoc IOptionSettlementEngine
    function option(uint256 tokenId) external view returns (Option memory optionInfo) {
        (uint160 optionId,) = getDecodedIdComponents(tokenId);
        optionInfo = _option[optionId];
    }

    /// @inheritdoc IOptionSettlementEngine
    function claim(uint256 tokenId) external view returns (Claim memory claimInfo) {
        claimInfo = _claim[tokenId];
    }

    function claimBucket(uint256 optionId, uint16 dayBucket)
        external
        view
        returns (ClaimBucket memory claimBucketInfo)
    {
        (uint160 _optionId,) = getDecodedIdComponents(optionId);
        claimBucketInfo = _claimBucketByOption[_optionId][dayBucket];
    }

    /// @inheritdoc IOptionSettlementEngine
    function tokenType(uint256 tokenId) external pure returns (Type) {
        (, uint96 claimIdx) = getDecodedIdComponents(tokenId);
        if (claimIdx == 0) {
            return Type.Option;
        }
        return Type.Claim;
    }

    /// @inheritdoc IOptionSettlementEngine
    function setFeeTo(address newFeeTo) public {
        if (msg.sender != feeTo) {
            revert AccessControlViolation(msg.sender, feeTo);
        }
        if (newFeeTo == address(0)) {
            revert InvalidFeeToAddress(newFeeTo);
        }
        feeTo = newFeeTo;
    }

    /// @inheritdoc IOptionSettlementEngine
    function sweepFees(address[] memory tokens) public {
        address sendFeeTo = feeTo;
        address token;
        uint256 fee;
        uint256 sweep;
        uint256 numTokens = tokens.length;

        unchecked {
            for (uint256 i = 0; i < numTokens; i++) {
                // Get the token and balance to sweep
                token = tokens[i];

                fee = feeBalance[token];
                // Leave 1 wei here as a gas optimization
                if (fee > 1) {
                    sweep = fee - 1;
                    feeBalance[token] = 1;
                    SafeTransferLib.safeTransfer(ERC20(token), sendFeeTo, sweep);
                    emit FeeSwept(token, sendFeeTo, sweep);
                }
            }
        }
    }

    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        Option memory optionInfo;
        (uint160 optionId, uint96 claimId) = getDecodedIdComponents(tokenId);
        optionInfo = _option[optionId];

        if (optionInfo.underlyingAsset == address(0x0)) {
            revert TokenNotFound(tokenId);
        }

        Type _type = claimId == 0 ? Type.Option : Type.Claim;

        TokenURIGenerator.TokenURIParams memory params = TokenURIGenerator.TokenURIParams({
            underlyingAsset: optionInfo.underlyingAsset,
            underlyingSymbol: ERC20(optionInfo.underlyingAsset).symbol(),
            exerciseAsset: optionInfo.exerciseAsset,
            exerciseSymbol: ERC20(optionInfo.exerciseAsset).symbol(),
            exerciseTimestamp: optionInfo.exerciseTimestamp,
            expiryTimestamp: optionInfo.expiryTimestamp,
            underlyingAmount: optionInfo.underlyingAmount,
            exerciseAmount: optionInfo.exerciseAmount,
            tokenType: _type
        });

        return TokenURIGenerator.constructTokenURI(params);
    }

    /// @inheritdoc IOptionSettlementEngine
    function newOptionType(Option memory optionInfo) external returns (uint256 optionId) {
        // Check that a duplicate option type doesn't exist
        bytes20 optionHash = bytes20(keccak256(abi.encode(optionInfo)));
        uint160 optionKey = uint160(optionHash);
        optionId = uint256(optionKey) << 96;

        // If it does, revert
        if (isOptionInitialized(optionKey)) {
            revert OptionsTypeExists(optionId);
        }

        // Make sure that expiry is at least 24 hours from now
        if (optionInfo.expiryTimestamp < (block.timestamp + 1 days)) {
            revert ExpiryTooSoon(optionId, optionInfo.expiryTimestamp);
        }

        // Ensure the exercise window is at least 24 hours
        if (optionInfo.expiryTimestamp < (optionInfo.exerciseTimestamp + 1 days)) {
            revert ExerciseWindowTooShort();
        }

        // The exercise and underlying assets can't be the same
        if (optionInfo.exerciseAsset == optionInfo.underlyingAsset) {
            revert InvalidAssets(optionInfo.exerciseAsset, optionInfo.underlyingAsset);
        }

        optionInfo.settlementSeed = optionKey;
        optionInfo.nextClaimId = 1;

        // Check that both tokens are ERC20 by instantiating them and checking supply
        ERC20 underlyingToken = ERC20(optionInfo.underlyingAsset);
        ERC20 exerciseToken = ERC20(optionInfo.exerciseAsset);

        // Check total supplies and ensure the option will be exercisable
        if (
            underlyingToken.totalSupply() < optionInfo.underlyingAmount
                || exerciseToken.totalSupply() < optionInfo.exerciseAmount
        ) {
            revert InvalidAssets(optionInfo.underlyingAsset, optionInfo.exerciseAsset);
        }

        _option[optionKey] = optionInfo;

        emit NewOptionType(
            optionId,
            optionInfo.exerciseAsset,
            optionInfo.underlyingAsset,
            optionInfo.exerciseAmount,
            optionInfo.underlyingAmount,
            optionInfo.exerciseTimestamp,
            optionInfo.expiryTimestamp,
            optionInfo.nextClaimId
            );
    }

    /// @inheritdoc IOptionSettlementEngine
    function write(uint256 optionId, uint112 amount) external returns (uint256 claimId) {
        /// supplying claimId as 0 to the overloaded write signifies that a new
        /// claim NFT should be minted for the options lot, rather than being added
        /// as an existing claim.
        return write(optionId, amount, 0);
    }

    /// @inheritdoc IOptionSettlementEngine
    function write(uint256 optionId, uint112 amount, uint256 claimId) public returns (uint256) {
        (uint160 _optionIdU160b, uint96 _optionIdL96b) = getDecodedIdComponents(optionId);

        // optionId must be zero in lower 96b for provided option Id
        if (_optionIdL96b != 0) {
            revert InvalidOption(optionId);
        }

        // claim provided must match the option provided
        if (claimId != 0 && ((claimId >> 96) != (optionId >> 96))) {
            revert EncodedOptionIdInClaimIdDoesNotMatchProvidedOptionId(claimId, optionId);
        }

        if (amount == 0) {
            revert AmountWrittenCannotBeZero();
        }

        Option storage optionRecord = _option[_optionIdU160b];

        uint40 expiry = optionRecord.expiryTimestamp;
        if (expiry == 0) {
            revert InvalidOption(_optionIdU160b);
        }
        if (expiry <= block.timestamp) {
            revert ExpiredOption(uint256(_optionIdU160b) << 96, expiry);
        }

        uint256 rxAmount = amount * optionRecord.underlyingAmount;
        uint256 fee = ((rxAmount / 10000) * feeBps);
        address underlyingAsset = optionRecord.underlyingAsset;

        feeBalance[underlyingAsset] += fee;

        emit FeeAccrued(underlyingAsset, msg.sender, fee);
        emit OptionsWritten(optionId, msg.sender, claimId, amount);

        uint256 mintClaimNft = 0;

        if (claimId == 0) {
            // create new claim
            // Increment the next token ID
            uint96 claimIndex = optionRecord.nextClaimId++;
            claimId = getTokenId(_optionIdU160b, claimIndex);
            // Store info about the claim
            _claim[claimId] = Claim({amountWritten: amount, claimed: false});
            mintClaimNft = 1;
        } else {
            // check ownership of claim
            uint256 balance = balanceOf[msg.sender][claimId];
            if (balance != 1) {
                revert CallerDoesNotOwnClaimId(claimId);
            }

            // retrieve claim
            Claim storage existingClaim = _claim[claimId];

            if (existingClaim.claimed) {
                revert AlreadyClaimed(claimId);
            }

            existingClaim.amountWritten += amount;
        }
        uint16 bucketIndex = _addOrUpdateClaimBucket(_optionIdU160b, amount);
        _addOrUpdateClaimIndex(claimId, bucketIndex, amount);

        // Mint the options contracts and claim token
        uint256[] memory tokens = new uint256[](2);
        tokens[0] = optionId;
        tokens[1] = claimId;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = mintClaimNft;

        bytes memory data = new bytes(0);

        // Send tokens to writer
        _batchMint(msg.sender, tokens, amounts, data);

        // Transfer the requisite underlying asset
        SafeTransferLib.safeTransferFrom(ERC20(underlyingAsset), msg.sender, address(this), (rxAmount + fee));

        return claimId;
    }

    /// @inheritdoc IOptionSettlementEngine
    function exercise(uint256 optionId, uint112 amount) external {
        (uint160 _optionIdU160b, uint96 _optionIdL96b) = getDecodedIdComponents(optionId);

        // option ID should be specified without claim in lower 96b
        if (_optionIdL96b != 0) {
            revert InvalidOption(optionId);
        }

        Option storage optionRecord = _option[_optionIdU160b];

        if (optionRecord.expiryTimestamp <= block.timestamp) {
            revert ExpiredOption(optionId, optionRecord.expiryTimestamp);
        }
        // Require that we have reached the exercise timestamp
        if (optionRecord.exerciseTimestamp >= block.timestamp) {
            revert ExerciseTooEarly(optionId, optionRecord.exerciseTimestamp);
        }

        uint256 rxAmount = optionRecord.exerciseAmount * amount;
        uint256 txAmount = optionRecord.underlyingAmount * amount;
        uint256 fee = ((rxAmount / 10000) * feeBps);
        address exerciseAsset = optionRecord.exerciseAsset;

        _assignExercise(_optionIdU160b, optionRecord, amount);

        feeBalance[exerciseAsset] += fee;

        _burn(msg.sender, optionId, amount);

        // Transfer in the requisite exercise asset
        SafeTransferLib.safeTransferFrom(ERC20(exerciseAsset), msg.sender, address(this), (rxAmount + fee));

        // Transfer out the underlying
        SafeTransferLib.safeTransfer(ERC20(optionRecord.underlyingAsset), msg.sender, txAmount);

        emit FeeAccrued(exerciseAsset, msg.sender, fee);
        emit OptionsExercised(optionId, msg.sender, amount);
    }

    /// @dev Fair assignment is performed here. After option expiry, any claim holder
    /// seeking to redeem their claim for the underlying and exercise assets will claim
    /// amounts proportional to the per-day amounts written on their options lot (i.e.
    /// the ClaimIndex data structions) weighted by the ratio of exercised to unexercised
    /// options on each of those days.
    /// @inheritdoc IOptionSettlementEngine
    function redeem(uint256 claimId) external {
        (uint160 _optionId, uint96 _claimIndex) = getDecodedIdComponents(claimId);

        if (_claimIndex == 0) {
            revert InvalidClaim(claimId);
        }

        uint256 balance = this.balanceOf(msg.sender, claimId);

        if (balance != 1) {
            revert CallerDoesNotOwnClaimId(claimId);
        }

        Claim storage claimRecord = _claim[claimId];

        if (claimRecord.claimed) {
            revert AlreadyClaimed(claimId);
        }

        Option storage optionRecord = _option[_optionId];

        if (optionRecord.expiryTimestamp > block.timestamp) {
            revert ClaimTooSoon(claimId, optionRecord.expiryTimestamp);
        }

        (uint256 exerciseAmount, uint256 underlyingAmount) = _getPositionsForClaim(_optionId, claimId, optionRecord);

        claimRecord.claimed = true;

        _burn(msg.sender, claimId, 1);

        if (exerciseAmount > 0) {
            SafeTransferLib.safeTransfer(ERC20(optionRecord.exerciseAsset), msg.sender, exerciseAmount);
        }

        if (underlyingAmount > 0) {
            SafeTransferLib.safeTransfer(ERC20(optionRecord.underlyingAsset), msg.sender, underlyingAmount);
        }

        emit ClaimRedeemed(
            claimId,
            _optionId,
            msg.sender,
            optionRecord.exerciseAsset,
            optionRecord.underlyingAsset,
            uint96(exerciseAmount),
            uint96(underlyingAmount)
            );
    }

    /// @inheritdoc IOptionSettlementEngine
    function underlying(uint256 tokenId) external view returns (Underlying memory underlyingPositions) {
        (uint160 _tokenIdU160b, uint96 _tokenIdL96b) = getDecodedIdComponents(tokenId);

        if (!isOptionInitialized(_tokenIdU160b)) {
            revert TokenNotFound(tokenId);
        }

        Option storage optionRecord = _option[_tokenIdU160b];

        // token ID is an option
        if (_tokenIdL96b == 0) {
            bool expired = (optionRecord.expiryTimestamp > block.timestamp);
            underlyingPositions = Underlying({
                underlyingAsset: optionRecord.underlyingAsset,
                underlyingPosition: expired ? int256(0) : int256(uint256(optionRecord.underlyingAmount)),
                exerciseAsset: optionRecord.exerciseAsset,
                exercisePosition: expired ? int256(0) : -int256(uint256(optionRecord.exerciseAmount))
            });
        } else {
            // token ID is a claim
            (uint256 amountExerciseAsset, uint256 amountUnderlyingAsset) =
                _getPositionsForClaim(_tokenIdU160b, tokenId, optionRecord);

            underlyingPositions = Underlying({
                underlyingAsset: optionRecord.underlyingAsset,
                underlyingPosition: int256(amountUnderlyingAsset),
                exerciseAsset: optionRecord.exerciseAsset,
                exercisePosition: int256(amountExerciseAsset)
            });
        }
    }

    // **********************************************************************
    //                        INTERNAL HELPERS
    // **********************************************************************
    /**
     * @dev Writes the specified number of options, transferring in the requisite
     * underlying assets, and trasnsferring fungible ERC1155 tokens to caller.
     * Reverts if insufficient underlying assets are not available from caller.
     * @param _optionId The options to write.
     * @param amount The amount of options to write.
     */
    function _writeOptions(uint160 _optionId, uint112 amount) internal returns (Option storage) {
        if (amount == 0) {
            revert AmountWrittenCannotBeZero();
        }

        Option storage optionRecord = _option[_optionId];

        if (optionRecord.expiryTimestamp <= block.timestamp) {
            revert ExpiredOption(uint256(_optionId) << 96, optionRecord.expiryTimestamp);
        }

        uint256 rxAmount = amount * optionRecord.underlyingAmount;
        uint256 fee = ((rxAmount / 10000) * feeBps);
        address underlyingAsset = optionRecord.underlyingAsset;

        // Transfer the requisite underlying asset
        SafeTransferLib.safeTransferFrom(ERC20(underlyingAsset), msg.sender, address(this), (rxAmount + fee));

        feeBalance[underlyingAsset] += fee;

        emit FeeAccrued(underlyingAsset, msg.sender, fee);

        return optionRecord;
    }

    /// @dev Performs fair exercise assignment by pseudorandomly selecting a claim
    /// bucket between the intial creation of the option type and "today". The buckets
    /// are then iterated from oldest to newest (looping if we reach "today") if the
    /// exercise amount overflows into another bucket. The seed for the pseudorandom
    /// index is updated accordingly on the option type.
    function _assignExercise(uint160 optionId, Option storage optionRecord, uint112 amount) internal {
        // A bucket of the overall amounts written and exercised for all claims
        // on a given day
        ClaimBucket[] storage claimBucketArray = _claimBucketByOption[optionId];
        uint16 bucketsMod = uint16(claimBucketArray.length);
        uint16 bucketIndex = uint16(optionRecord.settlementSeed % bucketsMod);
        while (amount > 0) {
            // get the claim bucket to assign
            ClaimBucket storage claimBucketInfo = claimBucketArray[bucketIndex];

            uint112 amountAvailable = claimBucketInfo.amountWritten - claimBucketInfo.amountExercised;
            uint112 amountPresentlyExercised;
            if (amountAvailable < amount) {
                amount -= amountAvailable;
                amountPresentlyExercised = amountAvailable;
            } else {
                amountPresentlyExercised = amount;
                amount = 0;
            }
            claimBucketInfo.amountExercised += amountPresentlyExercised;
            bucketIndex = (bucketIndex + 1) % bucketsMod;
        }

        // update settlement seed
        optionRecord.settlementSeed = uint160(uint256(keccak256(abi.encode(optionRecord.settlementSeed, bucketIndex))));
    }

    function _getDaysBucket() internal view returns (uint16) {
        return uint16(block.timestamp / 1 days);
    }

    function _getAmountExercised(ClaimIndex storage claimIndex, ClaimBucket storage claimBucketInfo)
        internal
        view
        returns (uint256 _exercised, uint256 _unexercised)
    {
        // The ratio of exercised to written options in the bucket multiplied by the
        // number of options actaully written in the claim.
        _exercised = FixedPointMathLib.mulDivDown(
            claimBucketInfo.amountExercised, claimIndex.amountWritten, claimBucketInfo.amountWritten
        );

        // The ration of unexercised to written options in the bucket multiplied by the
        // number of options actually written in the claim.
        _unexercised = FixedPointMathLib.mulDivDown(
            claimBucketInfo.amountWritten - claimBucketInfo.amountExercised,
            claimIndex.amountWritten,
            claimBucketInfo.amountWritten
        );
    }

    function _getPositionsForClaim(uint160 optionId, uint256 claimId, Option storage optionRecord)
        internal
        view
        returns (uint256 exerciseAmount, uint256 underlyingAmount)
    {
        ClaimIndex[] storage claimIndexArray = _claimIdToClaimIndexArray[claimId];
        for (uint256 i = 0; i < claimIndexArray.length; i++) {
            ClaimIndex storage claimIndex = claimIndexArray[i];
            ClaimBucket storage claimBucketInfo = _claimBucketByOption[optionId][claimIndex.bucketIndex];
            (uint256 amountExercised, uint256 amountUnexercised) = _getAmountExercised(claimIndex, claimBucketInfo);
            exerciseAmount += optionRecord.exerciseAmount * amountExercised;
            underlyingAmount += optionRecord.underlyingAmount * amountUnexercised;
        }
    }

    function _addOrUpdateClaimBucket(uint160 optionId, uint112 amount) internal returns (uint16) {
        ClaimBucket[] storage claimBucketsInfo = _claimBucketByOption[optionId];
        ClaimBucket storage currentBucket;
        uint16 daysAfterEpoch = _getDaysBucket();
        if (claimBucketsInfo.length == 0) {
            // add a new bucket none exist
            claimBucketsInfo.push(ClaimBucket(amount, 0, daysAfterEpoch));
            return uint16(claimBucketsInfo.length - 1);
        }

        currentBucket = claimBucketsInfo[claimBucketsInfo.length - 1];
        if (currentBucket.daysAfterEpoch < daysAfterEpoch) {
            claimBucketsInfo.push(ClaimBucket(amount, 0, daysAfterEpoch));
        } else {
            // Update claim bucket for today
            currentBucket.amountWritten += amount;
        }

        return uint16(claimBucketsInfo.length - 1);
    }

    function _addOrUpdateClaimIndex(uint256 claimId, uint16 bucketIndex, uint112 amount) internal {
        ClaimIndex storage lastIndex;
        ClaimIndex[] storage claimIndexArray = _claimIdToClaimIndexArray[claimId];
        uint256 arrayLength = claimIndexArray.length;

        // if no indices have been created previously, create one
        if (arrayLength == 0) {
            claimIndexArray.push(ClaimIndex({amountWritten: amount, bucketIndex: bucketIndex}));
            return;
        }

        lastIndex = claimIndexArray[arrayLength - 1];

        // create a new claim index if we're writing to a new index
        if (lastIndex.bucketIndex < bucketIndex) {
            claimIndexArray.push(ClaimIndex({amountWritten: amount, bucketIndex: bucketIndex}));
            return;
        }

        // update the amount written on the existing bucket index
        lastIndex.amountWritten += amount;
    }

    // **********************************************************************
    //                    TOKEN ID ENCODING HELPERS
    // **********************************************************************
    /**
     * @dev Claim and option type ids are encoded as follows:
     * (MSb)
     * [160b hash of option data structure]
     * [96b encoding of claim id]
     * (LSb)
     * This function decodes a supplied id.
     * @return optionId claimId The decoded components of the id as described above,
     * padded as required.
     */
    function getDecodedIdComponents(uint256 id) public pure returns (uint160 optionId, uint96 claimId) {
        // grab lower 96b of id for claim id
        uint256 claimIdMask = 0xFFFFFFFFFFFFFFFFFFFFFFFF;

        // move hash to LSB to fit into uint160
        optionId = uint160(id >> 96);
        claimId = uint96(id & claimIdMask);
    }

    function getOptionFromEncodedId(uint256 id) public view returns (Option memory) {
        (uint160 optionId,) = getDecodedIdComponents(id);
        return _option[optionId];
    }

    function getTokenId(uint160 optionId, uint96 claimIndex) public pure returns (uint256 claimId) {
        claimId |= (uint256(optionId) << 96);
        claimId |= uint256(claimIndex);
    }

    function isOptionInitialized(uint160 optionId) public view returns (bool) {
        return _option[optionId].underlyingAsset != address(0x0);
    }
}
