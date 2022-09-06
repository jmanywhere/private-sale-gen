// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TokenPresale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 bought;
        uint256 whitelistBought;
        bool claimed;
    }

    uint256 public immutable HARD_CAP;
    uint256 public immutable SOFT_CAP;
    uint256 public immutable MIN_BUY; // per wallet
    uint256 public immutable MAX_BUY; // per wallet

    uint256 public tokenPerRaise; // tokens per 1 ETH RAISE_TOKEN
    uint256 public immutable BUY_INTERVAL;
    uint256 public constant BASE_INTERVAL = 0.01 ether;
    uint256 public constant BARE_MIN = 0.0001 ether;

    uint256 public immutable wl_duration;
    uint256 public immutable public_duration;
    uint256 public immutable saleStart; //MAY 2ND 2022 7AM EST

    IERC20 public BUY_TOKEN;
    IERC20 public RAISE_TOKEN;
    IERC20 public WHITELIST_TOKEN;

    uint256 public totalRaised;
    uint256 public whitelistMin;
    uint256 public tokensToSell;

    mapping(address => UserInfo) public userInfo;
    mapping(address => bool) public whitelist;

    event BoughtToken(address indexed _user, uint256 amount, uint256 _raised);
    event TokenClaimed(address indexed _user, uint256 amount);
    event TokenSet(address _token);
    event FundsClaimed(address _to, uint256 _amount);

    receive() external payable {
        // We do nothing... if people send funds directly that's on them... use the function people
    }

    fallback() external payable {
        // We do nothing... if people send funds directly that's on them... use the function people
    }

    /**
    @param _token token address to be distributed. If NO TOKEN YET, send Address(0)
    @param _owner project owner address
    @param _whitelistToken token address needed for whitelist
    @param _collectToken token address to be collected (ETH or OTHER) if address == address(0) use native ETH
    @param _configs The configs array are the following parameters:
    0 - MIN BUY (has to be at least 0.0001 ether, if MIN is larger than 0.01 the min buy threshold is 0.01)
    1 - MAX BUY (if zero there will be no MAX)
    2 - softcap (can be zero for no soft cap)
    3 - hardcap (can be zero for no cap)
    4 - whitelist token amount to hold for whitelist (if zero the whitelist is not created) IF WHITELIST ADDRESS == ADDRESS(0) 
          then whitelist will need to be added to the mapping
    5 - whitelist timelimit IN HOURS (can be zero to make it manual)
    6 - total tokens to be sold (can be zero if number is pending or airdropped)
    7 - public duration IN HOURS (can be zero, owner will have to manually close the public sale duration)
    8 - start time
    **/

    constructor(
        address _token,
        address _owner,
        address _whitelistToken,
        address _collectToken,
        uint256[8] calldata configs
    ) {
        require(_owner != address(0)); // dev:  Need a new owner
        transferOwnership(_owner);
        if (_token != address(0)) BUY_TOKEN = IERC20(_token);
        if (_collectToken != address(0)) RAISE_TOKEN = IERC20(_collectToken);
        if (_whitelistToken != address(0)) {
            WHITELIST_TOKEN = IERC20(_whitelistToken);
            require(configs[4] > 0, "CF4"); // dev: Wrong config on 4, can't add whitelist token and zero requirement.
            whitelistMin = configs[4];
        }
        wl_duration = configs[5] * 1 hours;
        public_duration = configs[7] * 1 hours;
        SOFT_CAP = configs[2];
        HARD_CAP = configs[3];
        require((SOFT_CAP + HARD_CAP) % BASE_INTERVAL == 0, "CF2|3"); //dev: Get good caps, these suck

        require(config[0] > BARE_MIN, "CF0-P"); // dev: Wrong config on 0 pre actually writting the info
        if (config[0] >= 0.01 ether) BUY_INTERVAL = 0.01 ether;
        else BUY_INTERVAL = BARE_MIN;
        MIN_BUY = configs[0];
        MAX_BUY = configs[1];
        require(MAX_BUY > MIN_BUY, "CF1"); // dev: Max buy is less than min buy
        tokensToSell = configs[6];
        saleStart = configs[8];
    }

    function buyToken() external payable nonReentrant {
        uint256 amount = msg.value;
        require(amount > 0, "Need money");
        require(amount % BUY_INTERVAL == 0, "Only intervals of 0.01 BNB");
        require(
            block.timestamp < saleStart + duration &&
                block.timestamp >= saleStart,
            "Sale not running"
        );
        UserInfo storage user = userInfo[msg.sender];
        require(
            user.bought < MAX_BUY && user.bought + amount <= MAX_BUY,
            "User Cap reached"
        );
        uint256 raised = totalRaise();
        require(
            raised < HARD_CAP && raised + amount <= HARD_CAP,
            "Main cap reached"
        );
        user.bought += amount;
        totalRaised += amount;

        emit BoughtToken(msg.sender, amount, totalRaised);
    }

    function claimToken() external nonReentrant {
        require(block.timestamp > saleStart + duration, "Sale running");
        require(address(STAKE) != address(0), "Token not yet available");
        UserInfo storage user = userInfo[msg.sender];
        require(!user.claimed && user.bought > 0, "Already claimed");
        user.claimed = true;
        uint256 claimable = user.bought * tokenPerBNB;
        STAKE.safeTransfer(msg.sender, claimable);
        emit TokenClaimed(msg.sender, claimable);
    }

    function startSale(uint256 _startTimestamp) external onlyOwner {
        if (_startTimestamp == 0) {
            saleStart = block.timestamp;
        } else {
            require(saleStart == 0 && _startTimestamp > block.timestamp); // dev: Already set
            saleStart = _startTimestamp;
        }
    }

    /// @notice Set the token if the token was not set originally
    /// @param _token the address of the new token;
    function setToken(address _token) external onlyOwner {
        require(address(BUY_TOKEN) == address(0), "Token Set");
        BUY_TOKEN = IERC20(_token);
        emit TokenSet(_token);
    }

    /// @notice Withdraw the raised funds
    /// @dev withdraw the raised funds to the owner wallet
    function withdraw() external payable onlyOwner {
        uint256 raised;
        bool succ;
        if (address(RAISE_TOKEN) == address(0)) {
            raised = address(this).balance;
            (succ, ) = payable(msg.sender).call{value: raised}("");
            require(succ, "Unsuccessful, withdraw");
        } else {
            raised = RAISE_TOKEN.balanceOf(address(this));
            succ = RAISE_TOKEN.transfer(msg.sender, raised);
        }
        emit FundsClaimed(msg.sender, raised);
    }
}
