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
    uint256 public saleStart;

    bool public wl_end;
    bool public public_end;
    bool public claimable;

    IERC20 public BUY_TOKEN;
    IERC20 public RAISE_TOKEN;
    IERC20 public WHITELIST_TOKEN;

    uint256 public whitelistedUsers;

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
    @param _owner project owner address (Required)
    @param _whitelistToken token address needed for whitelist
    @param _collectToken token address to be collected (ETH or OTHER) if address == address(0) use native ETH
    @param configs The configs array are the following parameters:
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
        uint256[9] memory configs
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

        require(configs[0] > BARE_MIN, "CF0-P"); // dev: Wrong config on 0 pre actually writting the info
        uint256 interval;
        if (configs[0] >= 0.01 ether) interval = 0.01 ether;
        else interval = BARE_MIN;
        BUY_INTERVAL = interval;
        MIN_BUY = configs[0];
        MAX_BUY = configs[1];
        require(MAX_BUY > MIN_BUY, "CF1"); // dev: Max buy is less than min buy
        tokensToSell = configs[6];
        saleStart = configs[8];
    }

    function buyToken(uint256 _otherAmount) external payable nonReentrant {
        uint256 amount;
        if (address(RAISE_TOKEN) == address(0)) amount = msg.value;
        else {
            require(msg.value == 0);
            amount = _otherAmount;
        }

        UserInfo storage user = userInfo[msg.sender];
        uint256 totalBought = user.bought + user.whitelistBought;
        require(
            amount > 0 &&
                amount % BUY_INTERVAL == 0 &&
                totalBought + amount >= MIN_BUY,
            "Amount or Interval invalid"
        );

        bool isWhitelist = checkTimeLimits();

        require(
            totalBought < MAX_BUY && totalBought + amount <= MAX_BUY,
            "User Cap reached"
        );
        uint256 raised = totalRaised;
        require(
            raised < HARD_CAP && raised + amount <= HARD_CAP,
            "Main cap reached"
        );
        if (isWhitelist) user.whitelistBought += amount;
        else user.bought += amount;
        totalRaised += amount;

        emit BoughtToken(msg.sender, amount, totalRaised);
    }

    function claimToken() external nonReentrant {
        require(claimable, "Sale running");
        require(address(BUY_TOKEN) != address(0), "Token not yet available");
        UserInfo storage user = userInfo[msg.sender];
        require(
            !user.claimed && (user.bought + user.whitelistBought) > 0,
            "Already claimed"
        );
        user.claimed = true;
        uint256 u_claim = user.bought + user.whitelistBought;
        u_claim *= tokenPerRaise;
        BUY_TOKEN.safeTransfer(msg.sender, u_claim);
        emit TokenClaimed(msg.sender, u_claim);
    }

    function startSale(uint256 _startTimestamp) external onlyOwner {
        if (_startTimestamp == 0) {
            saleStart = block.timestamp;
        } else {
            require(saleStart == 0 && _startTimestamp > block.timestamp); // dev: Already set
            saleStart = _startTimestamp;
        }
    }

    function checkTimeLimits() internal returns (bool) {
        require(block.timestamp > saleStart); // dev: Not started yet
        // if no duration of whitelist added
        if (wl_duration == 0) {
            if (wl_end) {
                if (public_duration == 0) {
                    if (public_end) {
                        require(false); // dev: Sale ended
                    }
                } else {
                    require(
                        block.timestamp <
                            saleStart + wl_duration + public_duration
                    ); // dev: Sale over
                }
                return false;
            } else {
                require(getWhitelistStatus(msg.sender)); // dev: Not in whitelist
                return true;
            }
        } else {
            if (block.timestamp < saleStart + wl_duration) {
                require(getWhitelistStatus(msg.sender)); // dev: Not whitelisted
                return true;
            } else {
                if (public_duration == 0) {
                    if (public_end) {
                        require(false); // dev: Sale ended
                    }
                } else {
                    require(
                        block.timestamp <
                            saleStart + wl_duration + public_duration
                    ); // dev: Sale over
                }
                return false;
            }
        }
    }

    function getWhitelistStatus(address _user) internal returns (bool) {
        if (address(WHITELIST_TOKEN) == address(0)) return whitelist[_user];
        uint256 bal = WHITELIST_TOKEN.balanceOf(_user);
        return bal >= whitelistMin;
    }

    function manualEndWhitelist() external onlyOwner {
        require(wl_duration == 0, "Duration set");
        wl_end = true;
    }

    function manualEndPublic() external onlyOwner {
        require(public_duration == 0, "Duration set");
        public_end = true;
    }

    /// @notice Set the token if the token was not set originally
    /// @param _token the address of the new token;
    function setToken(address _token) external onlyOwner {
        require(address(BUY_TOKEN) == address(0), "Token Set");
        BUY_TOKEN = IERC20(_token);
        emit TokenSet(_token);
    }

    function addWhitelist(address _user) external onlyOwner {
        require(!whitelist[_user], "Already whitelisted");
        whitelist[_user] = true;
        whitelistedUsers++;
    }

    function whitelistMultiple(address[] calldata _users) external onlyOwner {
        uint256 len = _users.length;
        require(len > 0, "Non zero");
        for (uint256 i = 0; i < len; i++) {
            whitelist[_users[i]] = true;
        }
        whitelistedUsers += len;
    }

    function tokensClaimable() external onlyOwner {
        require(
            public_end ||
                block.timestamp > saleStart + wl_duration + public_duration
        ); //dev: Sale running
        require(
            address(BUY_TOKEN) != address(0) &&
                BUY_TOKEN.balanceOf(address(this)) > 0
        ); // dev: no tokens here
        uint256 current;
        if (address(RAISE_TOKEN) == address(0)) current = address(this).balance;
        else current = RAISE_TOKEN.balanceOf(address(this));
        tokenPerRaise = BUY_TOKEN.balanceOf(address(this)) / current;
        claimable = true;
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
