// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";

import {IPvPGamesStore} from "./IPvPGamesStore.sol";

// import "hardhat/console.sol";

/// @title PvPGame base contract
/// @author BetSwirl.eth
/// @notice This should be parent contract of each games.
/// It defines all the games common functions and state variables.
/// @dev All rates are in basis point. Chainlink VRF v2 is used.
abstract contract PvPGame is
    Pausable,
    Multicall,
    VRFConsumerBaseV2,
    ReentrancyGuard,
    Ownable
{
    using SafeERC20 for IERC20;

    /// @notice Bet information struct.
    /// @param token Address of the token.
    /// @param resolved Whether the bet has been resolved.
    /// @param canceled Whether the bet has been canceled.
    /// @param id Bet ID.
    /// @param vrfRequestTimestamp Block timestamp of the VRF request used to refund in case.
    /// @param houseEdge House edge that'll be charged.
    /// @param opponents Addresses of the opponents.
    /// @param seats Players addresses of each seat.
    /// @param vrfRequestId Request ID generated by Chainlink VRF.
    /// @param amount The buy-in amount.
    /// @param payout The total paid amount, minus fees if applied.
    /// @param pot The current prize pool is the sum of all buy-ins from players.
    struct Bet {
        address token;
        bool resolved;
        bool canceled;
        uint24 id;
        uint32 vrfRequestTimestamp;
        uint16 houseEdge;
        address[] opponents;
        address[] seats;
        uint256 vrfRequestId;
        uint256 amount;
        uint256 payout;
        uint256 pot;
    }
    /// @notice stores the NFTs params
    struct NFTs {
        IERC721 nftContract;
        uint256[] tokenIds;
        address[] to;
    }

    /// @notice Maps bet ID -> NFTs struct.
    mapping(uint24 => NFTs[]) public betNFTs;

    /// @notice Maps bet ID -> NFT contract -> token ID for claimed NFTs
    mapping(uint24 => mapping(IERC721 => mapping(uint256 => bool)))
        public claimedNFTs;

    /// @notice Token's house edge allocations struct.
    /// The games house edge is split into several allocations.
    /// The allocated amounts stays in the contract until authorized parties withdraw.
    /// NB: The initiator allocation is stored on the `payouts` mapping.
    /// @param dividendAmount The number of tokens to be sent as staking rewards.
    /// @param treasuryAmount The number of tokens to be sent to the treasury.
    /// @param teamAmount The number of tokens to be sent to the team.
    struct HouseEdgeSplit {
        uint256 dividendAmount;
        uint256 treasuryAmount;
        uint256 teamAmount;
    }

    /// @notice Token struct.
    /// @param houseEdge House edge rate.
    /// @param VRFCallbackGasLimit How much gas is needed in the Chainlink VRF callback.
    /// @param VRFFees Chainlink's VRF collected fees amount.
    /// @param houseEdgeSplit House edge allocations.
    struct Token {
        uint16 houseEdge;
        uint32 VRFCallbackGasLimit;
        uint256 VRFFees;
        HouseEdgeSplit houseEdgeSplit;
    }

    /// @notice Maps tokens addresses to token configuration.
    mapping(address => Token) public tokens;

    /// @notice Maximum number of NFTs per game.
    uint16 public maxNFTs;

    /// @notice Chainlink VRF configuration struct.
    /// @param requestConfirmations How many confirmations the Chainlink node should wait before responding.
    /// @param keyHash Hash of the public key used to verify the VRF proof.
    /// @param chainlinkCoordinator Reference to the VRFCoordinatorV2 deployed contract.
    /// @param gasAfterCalculation Gas to be added for VRF cost refund.
    struct ChainlinkConfig {
        uint16 requestConfirmations;
        bytes32 keyHash;
        VRFCoordinatorV2Interface chainlinkCoordinator;
        uint256 gasAfterCalculation;
    }
    /// @notice Chainlink VRF configuration state.
    ChainlinkConfig private _chainlinkConfig;

    /// @notice The PvPGamesStore contract that contains the tokens configuration.
    IPvPGamesStore public pvpGamesStore;

    /// @notice Address allowed to harvest dividends.
    address public harvester;

    /// @notice Maps bets IDs to Bet information.
    mapping(uint24 => Bet) public bets;

    /// @notice Bet ID nonce.
    uint24 public betId = 1;

    /// @notice Maps VRF request IDs to bet ID.
    mapping(uint256 => uint24) internal _betsByVrfRequestId;

    /// @notice Maps user -> token -> amount for due payouts
    mapping(address => mapping(address => uint256)) public payouts;

    /// @notice maps bet id -> player address -> played
    mapping(uint24 => mapping(address => bool)) private _opponentPlayed;

    /// @notice Emitted after the max seats is set.
    event SetMaxNFTs(uint16 maxNFTs);

    /// @notice Emitted after the Chainlink config is set.
    /// @param requestConfirmations How many confirmations the Chainlink node should wait before responding.
    /// @param keyHash Hash of the public key used to verify the VRF proof.
    /// @param gasAfterCalculation Gas to be added for VRF cost refund.
    event SetChainlinkConfig(
        uint16 requestConfirmations,
        bytes32 keyHash,
        uint256 gasAfterCalculation
    );

    /// @notice Emitted after the Chainlink callback gas limit is set for a token.
    /// @param token Address of the token.
    /// @param callbackGasLimit New Chainlink VRF callback gas limit.
    event SetVRFCallbackGasLimit(address token, uint32 callbackGasLimit);

    event AddNFTsPrize(
        uint24 indexed id,
        IERC721 nftContract,
        uint256[] tokenIds
    );
    event WonNFTs(uint24 indexed id, IERC721 nftContract, address[] winners);
    event ClaimedNFT(uint24 indexed id, IERC721 nftContract, uint256 tokenId);

    /// @notice Emitted after the bet amount is transfered to the user.
    /// @param id The bet ID.
    /// @param seats Address of the gamers.
    /// @param amount Number of tokens refunded.
    event BetRefunded(uint24 indexed id, address[] seats, uint256 amount);

    /// @notice Emitted after the bet is canceled.
    /// @param id The bet ID.
    /// @param user Address of the gamer.
    /// @param amount Number of tokens refunded.
    event BetCanceled(uint24 id, address user, uint256 amount);

    /// @notice Emitted after the bet is started.
    /// @param id The bet ID.
    event GameStarted(uint24 indexed id);

    /// @notice Emitted after a player joined seat(s)
    /// @param id The bet ID.
    /// @param player Address of the player.
    /// @param pot total played
    /// @param received Amount received
    /// @param seatsNumber Number of seats.
    event Joined(
        uint24 indexed id,
        address player,
        uint256 pot,
        uint256 received,
        uint16 seatsNumber
    );

    /// @notice Emitted after the house edge is set for a token.
    /// @param token Address of the token.
    /// @param houseEdge House edge rate.
    event SetHouseEdge(address token, uint16 houseEdge);

    /// @notice Emitted when a new harvester is set.
    event HarvesterSet(address newHarvester);

    /// @notice Emitted after the token's treasury and team allocations are distributed.
    /// @param token Address of the token.
    /// @param treasuryAmount The number of tokens sent to the treasury.
    /// @param teamAmount The number of tokens sent to the team.
    event HouseEdgeDistribution(
        address token,
        uint256 treasuryAmount,
        uint256 teamAmount
    );

    /// @notice Emitted after the token's dividend allocation is distributed.
    /// @param token Address of the token.
    /// @param amount The number of tokens sent to the Harvester.
    event HarvestDividend(address token, uint256 amount);

    /// @notice Emitted after the token's house edge is allocated.
    /// @param token Address of the token.
    /// @param dividend The number of tokens allocated as staking rewards.
    /// @param treasury The number of tokens allocated to the treasury.
    /// @param team The number of tokens allocated to the team.
    event AllocateHouseEdgeAmount(
        address token,
        uint256 dividend,
        uint256 treasury,
        uint256 team,
        uint256 initiator
    );

    /// @notice Emitted after a player claimed his payouts.
    /// @param user Address of the token.
    /// @param token The number of tokens allocated as staking rewards.
    /// @param amount The number of tokens allocated to the treasury.
    event PayoutsClaimed(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /// @notice Bet provided doesn't exist or was already resolved.
    error NotPendingBet();

    /// @notice Bet isn't resolved yet.
    error NotFulfilled();

    /// @notice Token is not allowed.
    error ForbiddenToken();

    /// @notice Reverting error when sender isn't allowed.
    error AccessDenied();

    /// @notice Reverting error when provided address isn't valid.
    error InvalidAddress();

    /// @notice Bet amount isn't enough to accept bet.
    /// @param betAmount Bet amount.
    error WrongBetAmount(uint256 betAmount);

    /// @notice User isn't one of the defined bet opponents.
    /// @param user The unallowed opponent address.
    error InvalidOpponent(address user);

    /// @notice Wrong number of seat to launch the game.
    error WrongSeatsNumber();

    /// @notice The maximum of seats is reached
    error TooManySeats();

    /// @notice The maximum of NFTs is reached
    error TooManyNFTs();

    /// @notice Initialize contract's state variables and VRF Consumer.
    /// @param chainlinkCoordinatorAddress Address of the Chainlink VRF Coordinator.
    /// @param pvpGamesStoreAddress The PvPGamesStore address.
    constructor(
        address chainlinkCoordinatorAddress,
        address pvpGamesStoreAddress
    ) VRFConsumerBaseV2(chainlinkCoordinatorAddress) {
        if (
            chainlinkCoordinatorAddress == address(0) ||
            pvpGamesStoreAddress == address(0)
        ) {
            revert InvalidAddress();
        }
        pvpGamesStore = IPvPGamesStore(pvpGamesStoreAddress);
        _chainlinkConfig.chainlinkCoordinator = VRFCoordinatorV2Interface(
            chainlinkCoordinatorAddress
        );
    }

    function setMaxNFTs(uint16 _maxNFTs) external onlyOwner {
        maxNFTs = _maxNFTs;
        emit SetMaxNFTs(_maxNFTs);
    }

    function _transferNFTs(uint24 id, bytes memory nfts) private {
        (IERC721[] memory nftContracts, uint256[][] memory tokenIds) = abi
            .decode(nfts, (IERC721[], uint256[][]));
        uint256 NFTsCount;
        for (uint256 i = 0; i < nftContracts.length; i++) {
            IERC721 nftContract = nftContracts[i];
            uint256[] memory nftContractTokenIds = tokenIds[i];
            betNFTs[id].push();
            betNFTs[id][i].nftContract = nftContract;
            betNFTs[id][i].tokenIds = nftContractTokenIds;
            for (uint256 j = 0; j < nftContractTokenIds.length; j++) {
                nftContract.transferFrom(
                    msg.sender,
                    address(this),
                    nftContractTokenIds[j]
                );
                NFTsCount++;
                if (NFTsCount > maxNFTs) {
                    revert TooManyNFTs();
                }
            }
            emit AddNFTsPrize(id, nftContract, nftContractTokenIds);
        }
    }

    function getBetNFTs(uint24 id) external view returns (NFTs[] memory) {
        return betNFTs[id];
    }

    /// @notice Creates a new bet, transfer the ERC20 tokens to the contract.
    /// @param tokenAddress Address of the token.
    /// @param tokenAmount The number of tokens bet.
    /// @param opponents The defined opponents.
    /// @return A new Bet struct information.
    function _newBet(
        address tokenAddress,
        uint256 tokenAmount,
        address[] memory opponents,
        bytes memory nfts
    ) internal whenNotPaused nonReentrant returns (Bet memory) {
        uint16 houseEdge = tokens[tokenAddress].houseEdge;
        if (houseEdge == 0) {
            revert ForbiddenToken();
        }

        bool isGasToken = tokenAddress == address(0);
        uint256 betAmount = isGasToken ? msg.value : tokenAmount;

        uint256 received = betAmount;
        if (!isGasToken) {
            uint256 balanceBefore = IERC20(tokenAddress).balanceOf(
                address(this)
            );
            IERC20(tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                betAmount
            );
            uint256 balanceAfter = IERC20(tokenAddress).balanceOf(
                address(this)
            );
            received = balanceAfter - balanceBefore;
        }

        // Create bet
        uint24 id = betId++;
        Bet memory newBet = Bet({
            resolved: false,
            canceled: false,
            opponents: opponents,
            seats: new address[](1),
            token: tokenAddress,
            id: id,
            vrfRequestId: 0,
            amount: betAmount,
            vrfRequestTimestamp: 0,
            payout: 0,
            pot: received,
            houseEdge: houseEdge
        });

        newBet.seats[0] = msg.sender;
        bets[id] = newBet;

        _transferNFTs(id, nfts);

        return newBet;
    }

    function betMinSeats(uint24 betId) public view virtual returns (uint256);

    function betMaxSeats(uint24 betId) public view virtual returns (uint256);

    function gameCanStart(uint24) public view virtual returns (bool) {
        return true;
    }

    function _joinGame(uint24 id, uint16 seatsNumber) internal nonReentrant {
        Bet storage bet = bets[id];
        uint256 _maxSeats = betMaxSeats(id);
        if (bet.resolved || bet.vrfRequestId != 0) {
            revert NotPendingBet();
        }
        uint256 seatsLength = bet.seats.length;
        if (seatsLength + seatsNumber > _maxSeats) {
            revert TooManySeats();
        }
        address user = msg.sender;

        address[] memory opponents = bet.opponents;
        uint256 opponentsLength = opponents.length;
        // Only check if player is in the opponent list if there is one.
        if (opponentsLength > 0) {
            bool included = false;
            for (uint256 i = 0; i < opponentsLength; i++) {
                if (opponents[i] == user) {
                    included = true;
                    break;
                }
            }
            if (!included) {
                revert InvalidOpponent(user);
            }
            if (!_opponentPlayed[id][user]) {
                _opponentPlayed[id][user] = true;
            }
        }

        address tokenAddress = bet.token;
        uint256 received = 0;
        if (tokenAddress == address(0)) {
            received = msg.value;
            if (received != bet.amount * seatsNumber) {
                revert WrongBetAmount(msg.value);
            }
        } else {
            uint256 balanceBefore = IERC20(tokenAddress).balanceOf(
                address(this)
            );
            IERC20(tokenAddress).safeTransferFrom(
                user,
                address(this),
                bet.amount * seatsNumber
            );
            uint256 balanceAfter = IERC20(tokenAddress).balanceOf(
                address(this)
            );
            received = balanceAfter - balanceBefore;
        }

        for (uint16 i = 0; i < seatsNumber; i++) {
            bet.seats.push(user);
        }
        seatsLength = bet.seats.length;

        bet.pot += received;

        if (
            seatsLength == _maxSeats ||
            (opponentsLength > 0 && _allOpponentsHavePlayed(id, opponents))
        ) {
            _launchGame(id);
        }
        emit Joined(id, user, bet.pot, received, seatsNumber);
    }

    function _allOpponentsHavePlayed(
        uint24 id,
        address[] memory opponents
    ) private view returns (bool) {
        for (uint256 i = 0; i < opponents.length; i++) {
            if (!_opponentPlayed[id][opponents[i]]) {
                return false;
            }
        }
        return true;
    }

    function _cleanOpponentsList(
        uint24 id,
        address[] memory opponents
    ) private {
        for (uint256 i = 0; i < opponents.length; i++) {
            delete _opponentPlayed[id][opponents[i]];
        }
    }

    function launchGame(uint24 id) external {
        Bet storage bet = bets[id];
        if (bet.seats.length < betMinSeats(id)) {
            revert WrongSeatsNumber();
        }
        if (bet.resolved || bet.vrfRequestId != 0) {
            revert NotPendingBet();
        }
        if (!gameCanStart(id)) {
            revert NotPendingBet();
        }
        _launchGame(id);
    }

    function _launchGame(uint24 id) private {
        Bet storage bet = bets[id];
        address tokenAddress = bet.token;
        IPvPGamesStore.Token memory token = pvpGamesStore.getTokenConfig(
            tokenAddress
        );

        uint256 requestId = _chainlinkConfig
            .chainlinkCoordinator
            .requestRandomWords(
                _chainlinkConfig.keyHash,
                token.vrfSubId,
                _chainlinkConfig.requestConfirmations,
                tokens[tokenAddress].VRFCallbackGasLimit,
                1
            );
        bet.vrfRequestId = requestId;
        bet.vrfRequestTimestamp = uint32(block.timestamp);
        _betsByVrfRequestId[requestId] = id;

        emit GameStarted(id);
    }

    function cancelBet(uint24 id) external {
        Bet storage bet = bets[id];
        if (bet.resolved || bet.id == 0) {
            revert NotPendingBet();
        } else if (bet.seats.length > 1) {
            revert NotFulfilled();
        } else if (bet.seats[0] != msg.sender && owner() != msg.sender) {
            revert AccessDenied();
        }

        bet.canceled = true;
        bet.resolved = true;
        bet.payout = bet.pot;

        if (bet.opponents.length > 0) _cleanOpponentsList(id, bet.opponents);

        address host = bet.seats[0];
        payouts[host][bet.token] += bet.payout;

        NFTs[] storage nfts = betNFTs[bet.id];
        for (uint256 i = 0; i < nfts.length; i++) {
            NFTs storage NFT = nfts[i];
            for (uint256 j = 0; j < NFT.tokenIds.length; j++) {
                NFT.to.push(host);
            }
        }

        emit BetCanceled(id, host, bet.payout);
    }

    function claimNFTs(uint24 _betId) external {
        NFTs[] memory nfts = betNFTs[_betId];
        for (uint256 i = 0; i < nfts.length; i++) {
            for (uint256 j = 0; j < nfts[i].tokenIds.length; j++) {
                claimNFT(_betId, i, j);
            }
        }
    }

    function claimNFT(uint24 _betId, uint256 nftIndex, uint256 tokenId) public {
        NFTs memory nft = betNFTs[_betId][nftIndex];
        if (!claimedNFTs[_betId][nft.nftContract][tokenId]) {
            claimedNFTs[_betId][nft.nftContract][tokenId] = true;
            nft.nftContract.transferFrom(
                address(this),
                nft.to[tokenId],
                nft.tokenIds[tokenId]
            );
            emit ClaimedNFT(_betId, nft.nftContract, tokenId);
        }
    }

    function claimAll(address user) external {
        address[] memory tokensList = pvpGamesStore.getTokensAddresses();
        for (uint256 i = 0; i < tokensList.length; i++) {
            claim(user, tokensList[i]);
        }
    }

    function claim(address user, address token) public {
        uint256 amount = payouts[user][token];
        if (amount > 0) {
            delete payouts[user][token];

            _safeTransfer(payable(user), token, amount);

            emit PayoutsClaimed(user, token, amount);
        }
    }

    /// @notice Refunds the bet to the user if the Chainlink VRF callback failed.
    /// @param id The Bet ID.
    function refundBet(uint24 id) external {
        Bet storage bet = bets[id];
        if (
            bet.resolved ||
            bet.vrfRequestTimestamp == 0 ||
            bet.seats.length < 2
        ) {
            revert NotPendingBet();
        } else if (block.timestamp < bet.vrfRequestTimestamp + 60 * 60 * 24) {
            revert NotFulfilled();
        } else if (bet.seats[0] != msg.sender && owner() != msg.sender) {
            revert AccessDenied();
        }

        bet.resolved = true;
        bet.payout = bet.pot;

        if (bet.opponents.length > 0) _cleanOpponentsList(id, bet.opponents);

        // Refund players
        uint256 refundAmount = bet.pot / bet.seats.length;
        for (uint256 i = 0; i < bet.seats.length; i++) {
            payouts[bet.seats[i]][bet.token] += refundAmount;
        }

        address host = bet.seats[0];
        NFTs[] storage nfts = betNFTs[bet.id];
        for (uint256 i = 0; i < nfts.length; i++) {
            NFTs storage NFT = nfts[i];
            for (uint256 j = 0; j < NFT.tokenIds.length; j++) {
                NFT.to.push(host);
            }
        }

        emit BetRefunded(id, bet.seats, bet.payout);
    }

    /// @notice Resolves the bet based on the game child contract result.
    /// @param bet The Bet struct information.
    /// @param winners List of winning addresses
    /// @return The payout amount per winner.
    function _resolveBet(
        Bet storage bet,
        address[] memory winners,
        uint256 randomWord
    ) internal nonReentrant returns (uint256) {
        if (bet.resolved == true || bet.id == 0) {
            revert NotPendingBet();
        }
        bet.resolved = true;

        address token = bet.token;
        uint256 payout = bet.pot;
        uint256 fee = (bet.houseEdge * payout) / 10000;
        payout -= fee;
        bet.payout = payout;

        _allocateHouseEdge(token, fee, payable(bet.seats[0]));

        if (bet.opponents.length > 0) {
            _cleanOpponentsList(bet.id, bet.opponents);
        }

        uint256 payoutPerWinner = payout / winners.length;
        for (uint256 i = 0; i < winners.length; i++) {
            payouts[winners[i]][token] += payoutPerWinner;
        }

        // Distribute NFTs
        NFTs[] storage nfts = betNFTs[bet.id];
        for (uint256 i = 0; i < nfts.length; i++) {
            NFTs storage NFT = nfts[i];
            for (uint256 j = 0; j < NFT.tokenIds.length; j++) {
                uint256 winnerIndex = uint256(
                    keccak256(abi.encode(randomWord, i, j))
                ) % bet.seats.length;
                NFT.to.push(bet.seats[winnerIndex]);
            }
            if (NFT.to.length != 0) {
                emit WonNFTs(bet.id, NFT.nftContract, NFT.to);
            }
        }

        return payout;
    }

    /// @notice Sets the game house edge rate for a specific token.
    /// @param token Address of the token.
    /// @param houseEdge House edge rate.
    /// @dev The house edge rate couldn't exceed 4%.
    function setHouseEdge(address token, uint16 houseEdge) external onlyOwner {
        tokens[token].houseEdge = houseEdge;
        emit SetHouseEdge(token, houseEdge);
    }

    /// @notice Sets the Chainlink VRF V2 configuration.
    /// @param callbackGasLimit How much gas is needed in the Chainlink VRF callback.
    function setVRFCallbackGasLimit(
        address token,
        uint32 callbackGasLimit
    ) external onlyOwner {
        tokens[token].VRFCallbackGasLimit = callbackGasLimit;
        emit SetVRFCallbackGasLimit(token, callbackGasLimit);
    }

    /// @notice Pauses the contract to disable new bets.
    function pause() external onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
    }

    /// @notice Sets the Chainlink VRF V2 configuration.
    /// @param requestConfirmations How many confirmations the Chainlink node should wait before responding.
    /// @param keyHash Hash of the public key used to verify the VRF proof.
    /// @param gasAfterCalculation Gas to be added for VRF cost refund.
    function setChainlinkConfig(
        uint16 requestConfirmations,
        bytes32 keyHash,
        uint256 gasAfterCalculation
    ) external onlyOwner {
        _chainlinkConfig.requestConfirmations = requestConfirmations;
        _chainlinkConfig.keyHash = keyHash;
        _chainlinkConfig.gasAfterCalculation = gasAfterCalculation;
        emit SetChainlinkConfig(
            requestConfirmations,
            keyHash,
            gasAfterCalculation
        );
    }

    /// @notice Returns the Chainlink VRF config.
    /// @param requestConfirmations How many confirmations the Chainlink node should wait before responding.
    /// @param keyHash Hash of the public key used to verify the VRF proof.
    /// @param chainlinkCoordinator Reference to the VRFCoordinatorV2 deployed contract.
    function getChainlinkConfig()
        external
        view
        returns (
            uint16 requestConfirmations,
            bytes32 keyHash,
            VRFCoordinatorV2Interface chainlinkCoordinator,
            uint256 gasAfterCalculation
        )
    {
        return (
            _chainlinkConfig.requestConfirmations,
            _chainlinkConfig.keyHash,
            _chainlinkConfig.chainlinkCoordinator,
            _chainlinkConfig.gasAfterCalculation
        );
    }

    /// @notice Returns the bet with the seats list included
    /// @return bet The required bet
    function readBet(uint24 id) external view returns (Bet memory bet) {
        return bets[id];
    }

    /// @notice Allows to change the harvester address.
    /// @param newHarvester provides the new address to use.
    function setHarvester(address newHarvester) external onlyOwner {
        harvester = newHarvester;
        emit HarvesterSet(newHarvester);
    }

    /// @notice Harvests tokens dividends.
    function harvestDividends(address tokenAddress) external {
        if (msg.sender != harvester) revert AccessDenied();
        HouseEdgeSplit storage split = tokens[tokenAddress].houseEdgeSplit;
        uint256 dividendAmount = split.dividendAmount;
        if (dividendAmount != 0) {
            delete split.dividendAmount;
            _safeTransfer(harvester, tokenAddress, dividendAmount);
            emit HarvestDividend(tokenAddress, dividendAmount);
        }
    }

    /// @notice Splits the house edge fees and allocates them as dividends, the treasury, and team.
    /// @param token Address of the token.
    /// @param fees Bet amount and bet profit fees amount.
    function _allocateHouseEdge(
        address token,
        uint256 fees,
        address payable initiator
    ) private {
        IPvPGamesStore.HouseEdgeSplit
            memory tokenHouseEdgeConfig = pvpGamesStore
                .getTokenConfig(token)
                .houseEdgeSplit;
        HouseEdgeSplit storage tokenHouseEdge = tokens[token].houseEdgeSplit;

        uint256 treasuryAmount = (fees * tokenHouseEdgeConfig.treasury) / 10000;
        uint256 teamAmount = (fees * tokenHouseEdgeConfig.team) / 10000;
        uint256 initiatorAmount = (fees * tokenHouseEdgeConfig.initiator) /
            10000;
        uint256 dividendAmount = fees -
            initiatorAmount -
            teamAmount -
            treasuryAmount;

        if (teamAmount > 0) tokenHouseEdge.teamAmount += teamAmount;
        if (treasuryAmount > 0) tokenHouseEdge.treasuryAmount += treasuryAmount;
        if (dividendAmount > 0) tokenHouseEdge.dividendAmount += dividendAmount;

        if (initiatorAmount > 0) {
            payouts[initiator][token] += initiatorAmount;
        }

        emit AllocateHouseEdgeAmount(
            token,
            dividendAmount,
            treasuryAmount,
            teamAmount,
            initiatorAmount
        );
    }

    /// @notice Distributes the token's treasury and team allocations amounts.
    /// @param tokenAddress Address of the token.
    function withdrawHouseEdgeAmount(address tokenAddress) public {
        (address treasury, address teamWallet) = pvpGamesStore
            .getTreasuryAndTeamAddresses();
        HouseEdgeSplit storage tokenHouseEdge = tokens[tokenAddress]
            .houseEdgeSplit;
        uint256 treasuryAmount = tokenHouseEdge.treasuryAmount;
        uint256 teamAmount = tokenHouseEdge.teamAmount;
        if (treasuryAmount != 0) {
            delete tokenHouseEdge.treasuryAmount;
            _safeTransfer(treasury, tokenAddress, treasuryAmount);
        }
        if (teamAmount != 0) {
            delete tokenHouseEdge.teamAmount;
            _safeTransfer(teamWallet, tokenAddress, teamAmount);
        }
        if (treasuryAmount != 0 || teamAmount != 0) {
            emit HouseEdgeDistribution(
                tokenAddress,
                treasuryAmount,
                teamAmount
            );
        }
    }

    /// @notice Transfers a specific amount of token to an address.
    /// Uses native transfer or ERC20 transfer depending on the token.
    /// @dev The 0x address is considered the gas token.
    /// @param user Address of destination.
    /// @param token Address of the token.
    /// @param amount Number of tokens.
    function _safeTransfer(
        address user,
        address token,
        uint256 amount
    ) private {
        if (token == address(0)) {
            Address.sendValue(payable(user), amount);
        } else {
            IERC20(token).safeTransfer(user, amount);
        }
    }
}