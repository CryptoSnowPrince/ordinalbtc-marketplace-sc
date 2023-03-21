// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

interface IUniswapV3Pool {
    /// @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface IUniswapV2Pool {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

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

    struct PriceInfo {
        address poolWithWETH;
        bool isUniswapV3;
    }

    address public constant ETH = address(0xeee);

    address public WETH;
    address public WBTC;

    mapping(address => bool) public tokenList;
    mapping(address => PriceInfo) public priceInfo;
    mapping(address => bool) public adminList;

    mapping(address => mapping(address => uint256)) public inscriberHistory; // inscriber -> token -> amount

    mapping(uint256 => InscribeInfo) public inscribeInfo; // number => inscribeInfo

    uint256 public number = 0; // latest inscribe number, current total numbers of inscribe

    event LogSetWETH(address indexed WETH);
    event LogSetWBTC(address indexed WBTC);
    event LogUpdateTokenList(address indexed token, bool indexed state);
    event LogUpdateAdminList(address indexed admin, bool indexed state);
    event LogInscribe(address indexed sender, uint256 indexed number);

    function initialize(
        address _WETH,
        address _WBTC,
        address _USDT,
        address _oBTC,
        address _pool_WBTC,
        address _pool_USDT,
        address _pool_oBTC,
        address _admin
    ) public initializer {
        __Ownable2Step_init();
        __Pausable_init();

        WETH = _WETH;
        WBTC = _WBTC;

        updateTokenList(ETH, true);
        updateTokenList(_WBTC, true);
        updateTokenList(_USDT, true);
        updateTokenList(_oBTC, true);

        updatePriceInfoList(_WBTC, _pool_WBTC, true);
        updatePriceInfoList(_USDT, _pool_USDT, true);
        updatePriceInfoList(_oBTC, _pool_oBTC, false);

        adminList[msg.sender] = true;
        adminList[_admin] = true;
    }

    function _getTokenPriceAsETH(
        address token
    ) private view returns (uint256 numerator, uint256 denominator) {
        if (token == WETH) {
            numerator = 1;
            denominator = 1;
        } else if (tokenList[token]) {
            PriceInfo memory _priceInfo = priceInfo[token];
            if (!_priceInfo.isUniswapV3) {
                // Uniswap V2
                (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pool(
                    _priceInfo.poolWithWETH
                ).getReserves();

                (numerator, denominator) = WETH < token
                    ? (reserve0, reserve1)
                    : (reserve1, reserve0);
            } else {
                // Uniswap V3
                (uint256 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(
                    _priceInfo.poolWithWETH
                ).slot0();

                uint256 priceX96;
                uint256 Q192;
                if (sqrtPriceX96 > (2 ** 96 - 1)) {
                    priceX96 = (sqrtPriceX96 >> 64) ** 2;
                    Q192 = 2 ** 64;
                } else {
                    priceX96 = sqrtPriceX96 ** 2;
                    Q192 = 2 ** 192;
                }

                (numerator, denominator) = WETH < token
                    ? (Q192, priceX96)
                    : (priceX96, Q192);
            }
        }
    }

    function getTokenAmounts(
        address token,
        uint256 satsAmount
    ) public view returns (uint256 tokenAmount) {
        (uint256 numeratorBTC, uint256 denominatorBTC) = _getTokenPriceAsETH(
            WBTC
        );
        (uint256 numerator, uint256 denominator) = token == ETH
            ? (1, 1)
            : _getTokenPriceAsETH(token);
        uint256 priceBTC = (numeratorBTC * 10 ** 18) / denominatorBTC;
        uint256 priceToken = (numerator * 10 ** 18) / denominator;
        tokenAmount = (satsAmount * priceBTC) / priceToken;
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

    function setWETH(address _WETH) external onlyOwner {
        require(WETH != _WETH, "SAME_WETH");
        WETH = _WETH;
        emit LogSetWETH(_WETH);
    }

    function updatePriceInfoList(
        address _token,
        address _poolWithWETH,
        bool _isUniswapV3
    ) public onlyOwner {
        priceInfo[_token] = PriceInfo({
            poolWithWETH: _poolWithWETH,
            isUniswapV3: _isUniswapV3
        });
    }

    function updateTokenList(address token, bool state) public onlyOwner {
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

        uint256 ethAmount = getTokenAmounts(ETH, satsAmount);

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
    ) external whenNotPaused {
        require(block.timestamp <= deadline, "OVER_TIME");
        require(tokenList[token], "NON_ACCEPTABLE_TOKEN");

        uint256 tokenAmount = getTokenAmounts(token, satsAmount);

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
