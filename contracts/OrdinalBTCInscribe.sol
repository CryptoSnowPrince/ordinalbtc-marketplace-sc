// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract OrdinalBTCInscribe is Ownable2StepUpgradeable, PausableUpgradeable {
    enum STATE {
        CREATED,
        COMPLETED,
        CANCELED,
        WITHDRAW
    }

    struct InscribeInfo {
        address erc20Inscriber;
        string btcDestination;
        uint256 satsAmount;
        address token;
        uint256 tokenAmount;
        string inscriptionID;
        STATE state;
    }

    address public constant ETH = address(0xeee);
    uint256 public constant DENOMINATOR = 100_000 ether; // PRICE_DENOMINATOR is 23

    address public WBTC;

    mapping(address => uint256) public priceList;
    mapping(address => bool) public tokenList;
    mapping(address => bool) public adminList;

    mapping(address => mapping(address => uint256)) public inscriberHistory; // inscriber -> token -> amount

    mapping(uint256 => InscribeInfo) public inscribeInfo; // number => inscribeInfo

    uint256 public number = 0; // latest inscribe number, current total numbers of inscribe

    event LogSetWBTC(address indexed WBTC);
    event LogUpdatePriceList(address indexed token, uint256 indexed price);
    event LogUpdateTokenList(address indexed token, bool indexed state);
    event LogUpdateAdminList(address indexed admin, bool indexed state);
    event LogInscribe(address indexed sender, uint256 indexed number);

    function initialize(
        address _WBTC,
        address _USDT,
        address _USDC,
        address _oBTC,
        address _admin
    ) public initializer {
        __Ownable2Step_init();
        __Pausable_init();

        WBTC = _WBTC;

        tokenList[ETH] = true;
        tokenList[WBTC] = true;
        tokenList[_USDT] = true;
        tokenList[_USDC] = true;
        tokenList[_oBTC] = true;

        priceList[ETH] = 2000 * 10 ** (23 - 18); // ETH decimals is 18
        priceList[WBTC] = 25000 * 10 ** (23 - 8); // WBTC decimals is 8
        priceList[_USDT] = 1 * 10 ** (23 - 6); // USDT decimals is 6
        priceList[_USDC] = 1 * 10 ** (23 - 6); // USDC decimals is 6
        priceList[_oBTC] = 0.02 * 10 ** (23 - 18); // oBTC decimals is 18

        adminList[msg.sender] = true;
        adminList[_admin] = true;
    }

    modifier onlyAdmins() {
        require(adminList[msg.sender] == true, "NOT_ADMIN");
        _;
    }

    function setWBTC(address _WBTC) external onlyOwner {
        require(WBTC != _WBTC, "SAME_WBTC");
        WBTC = _WBTC;
        emit LogSetWBTC(_WBTC);
    }

    function updatePriceList(address token, uint256 price) external onlyOwner {
        require(priceList[token] != price, "SAME_PRICE");
        priceList[token] = price;
        emit LogUpdatePriceList(token, price);
    }

    function updateTokenList(address token, bool state) external onlyOwner {
        require(tokenList[token] != state, "SAME_STATE");
        tokenList[token] = state;
        emit LogUpdateTokenList(token, state);
    }

    function updateAdminList(address admin, bool state) external onlyOwner {
        require(adminList[admin] != state, "SAME_STATE");
        adminList[admin] = state;
        emit LogUpdateAdminList(admin, state);
    }

    function setPause() external onlyOwner {
        _pause();
    }

    function setUnpause() external onlyOwner {
        _unpause();
    }

    function inscribeWithETH(
        string calldata btcDestination,
        uint256 satsAmount,
        uint256 deadline
    ) external payable whenNotPaused {
        require(block.timestamp <= deadline, "OVER_TIME");
        require(tokenList[ETH], "NON_ACCEPTABLE_TOKEN");

        uint256 ethAmount = (satsAmount * priceList[WBTC]) / priceList[ETH];

        require(msg.value >= ethAmount, "INSUFFICIENT_AMOUNT");

        number += 1;

        inscriberHistory[msg.sender][ETH] += ethAmount;

        inscribeInfo[number] = InscribeInfo({
            erc20Inscriber: msg.sender,
            btcDestination: btcDestination,
            satsAmount: satsAmount,
            token: ETH,
            tokenAmount: ethAmount,
            inscriptionID: "",
            state: STATE.CREATED
        });

        uint256 remainETH = msg.value - ethAmount;
        if (remainETH > 0) {
            payable(msg.sender).transfer(remainETH);
        }

        emit LogInscribe(msg.sender, number);
    }

    function inscribe(
        string calldata btcDestination,
        uint256 satsAmount,
        address token,
        uint256 deadline
    ) external payable whenNotPaused {
        require(block.timestamp <= deadline, "OVER_TIME");
        require(tokenList[token], "NON_ACCEPTABLE_TOKEN");

        uint256 tokenAmount = (satsAmount * priceList[WBTC]) / priceList[token];

        SafeERC20.safeTransferFrom(
            IERC20(token),
            msg.sender,
            address(this),
            tokenAmount
        );

        number += 1;

        inscriberHistory[msg.sender][token] += tokenAmount;

        inscribeInfo[number] = InscribeInfo({
            erc20Inscriber: msg.sender,
            btcDestination: btcDestination,
            satsAmount: satsAmount,
            token: token,
            tokenAmount: tokenAmount,
            inscriptionID: "",
            state: STATE.CREATED
        });

        emit LogInscribe(msg.sender, number);
    }

    function inscribeCheck(
        uint256 _number,
        string calldata _inscriptionID,
        STATE _state
    ) external whenNotPaused onlyAdmins {
        require(
            (_state == STATE.COMPLETED) || (_state == STATE.CANCELED),
            "UNKNOWN_STATE"
        );

        require(
            inscribeInfo[_number].state == STATE.CREATED,
            "CANNOT_OFFER_CHECk"
        );

        inscribeInfo[_number].state = _state;
        if (_state == STATE.COMPLETED) {
            inscribeInfo[_number].inscriptionID = _inscriptionID;
        }
    }

    function withdrawCancelledInscribe(
        uint256 _number,
        uint256 _amount
    ) external onlyAdmins {
        require(inscribeInfo[_number].state == STATE.CANCELED, "NOT_CANCELED");

        // No Sell Fee because Cancel
        require(
            _amount <= inscribeInfo[_number].tokenAmount,
            "OVERFLOW_AMOUNT"
        );

        address token = inscribeInfo[_number].token;
        address erc20Inscriber = inscribeInfo[_number].erc20Inscriber;

        inscriberHistory[msg.sender][token] -= _amount;
        if (token == ETH) {
            payable(erc20Inscriber).transfer(_amount);
        } else {
            SafeERC20.safeTransfer(IERC20(token), erc20Inscriber, _amount);
        }

        inscribeInfo[_number].state = STATE.WITHDRAW;
    }

    function withdraw(
        address token,
        uint256 amount,
        uint256 ethAmount,
        address treasury
    ) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(token), treasury, amount);
        payable(treasury).transfer(ethAmount);
    }
}
