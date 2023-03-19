// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract OrdinalBTCMarket is Ownable2StepUpgradeable, PausableUpgradeable {
    enum OSTATE {
        NOT_STARTED,
        CREATED,
        ALLOWED,
        CANCELED,
        COMPLETED
    }

    struct OfferInfo {
        address buyer;
        string inscriptionID;
        uint256 btcNFTId;
        string nft_owner;
        string nft_receiver;
        address token;
        uint256 amount;
        address seller;
        OSTATE state;
    }

    address public constant ETH = address(0xeee);
    // 10000: 100%, 100: 1%
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_FEE = 3000;

    mapping(address => uint256) public minFeeAmountList;
    mapping(address => uint256) public buyFeeList;
    mapping(address => uint256) public sellFeeList;
    mapping(address => bool) public acceptedTokenList;
    mapping(address => bool) public adminList;

    mapping(address => uint256) public pendingFees;

    mapping(address => mapping(address => uint256)) public buyerHistory; // buyer -> token -> amount
    mapping(address => mapping(address => uint256)) public sellerHistory; // seller -> token -> amount

    mapping(uint256 => OfferInfo) public offerInfo; // offerNumber => offerInfo
    mapping(uint256 => OSTATE) public offerState; // btcNFTId => offerState

    uint256 public orderNumber = 0; // latest order number, current total numbers of order
    uint256 public checkedOrderNumber = 0; // latest checked order number, current total numbers of checked order

    uint256 public withdrawNumber = 0;
    mapping(uint256 => uint256) public withdrawHistory; // withdrawNumber => OrderNumber

    event LogUpdateMinFeeAmountList(
        address indexed token,
        uint256 indexed minFeeAmount
    );
    event LogUpdateBuyFeeList(address indexed token, uint256 indexed buyFee);
    event LogUpdateSellFeeList(address indexed token, uint256 indexed sellFee);
    event LogUpdateAcceptedTokenList(address indexed token, bool indexed state);
    event LogUpdateAdminList(address indexed admin, bool indexed state);
    event LogWithdrawFee(
        address indexed to,
        IERC20 indexed token,
        uint256 amount,
        uint256 ethAmount
    );
    event LogBuyBTCNFT(
        uint256 indexed orderNumber,
        address indexed buyer,
        uint256 indexed btcNFTId,
        string inscriptionID,
        string nft_owner,
        string nft_receiver,
        address token,
        uint256 amount,
        address seller
    );
    event LogOfferCheck(uint256 indexed orderNumber, OSTATE indexed state);
    event LogWithdrawOrder(uint256 indexed orderNumber);
    event LogWithdrawCancelOrder(uint256 indexed orderNumber);

    function initialize(
        address _USDT,
        address _USDC,
        address _oBTC,
        address _admin
    ) public initializer {
        __Ownable2Step_init();
        __Pausable_init();

        acceptedTokenList[ETH] = true;
        acceptedTokenList[_USDT] = true;
        acceptedTokenList[_USDC] = true;
        acceptedTokenList[_oBTC] = true;

        buyFeeList[ETH] = 250;
        buyFeeList[_USDT] = 250;
        buyFeeList[_USDC] = 250;
        buyFeeList[_oBTC] = 100;

        sellFeeList[ETH] = 250;
        sellFeeList[_USDT] = 250;
        sellFeeList[_USDC] = 250;
        sellFeeList[_oBTC] = 100;

        minFeeAmountList[ETH] = 0.005 ether; // decimals = 18, 0.005 ETH
        minFeeAmountList[_USDT] = 5_000_000; // decimals = 6, 5 USDT
        minFeeAmountList[_USDC] = 5_000_000; // decimals = 6, 5 USDC
        minFeeAmountList[_oBTC] = 100 ether; // decimals = 18, 100 oBTC

        adminList[msg.sender] = true;
        adminList[_admin] = true;
    }

    modifier onlyAdmins() {
        require(adminList[msg.sender] == true, "NOT_ADMIN");
        _;
    }

    function updateMinFeeAmountList(
        address token,
        uint256 _minFeeAmount
    ) external onlyOwner {
        require(minFeeAmountList[token] != _minFeeAmount, "SAME_MIN_FEE");
        minFeeAmountList[token] = _minFeeAmount;
        emit LogUpdateMinFeeAmountList(token, _minFeeAmount);
    }

    function updateBuyFeeList(
        address token,
        uint256 _buyFee
    ) external onlyOwner {
        require(_buyFee < MAX_FEE, "OVER_MAX_FEE");
        require(buyFeeList[token] != _buyFee, "SAME_FEE");
        buyFeeList[token] = _buyFee;
        emit LogUpdateBuyFeeList(token, _buyFee);
    }

    function updateSellFeeList(
        address token,
        uint256 _sellFee
    ) external onlyOwner {
        require(_sellFee < MAX_FEE, "OVER_MAX_FEE");
        require(sellFeeList[token] != _sellFee, "SAME_FEE");
        sellFeeList[token] = _sellFee;
        emit LogUpdateSellFeeList(token, _sellFee);
    }

    function updateAcceptedTokenList(
        address token,
        bool state
    ) external onlyOwner {
        require(acceptedTokenList[token] != state, "SAME_STATE");
        acceptedTokenList[token] = state;
        emit LogUpdateAcceptedTokenList(token, state);
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

    function buyBTCNFTwithETH(
        string calldata inscriptionID,
        uint256 btcNFTId,
        string calldata nft_owner,
        string calldata nft_receiver,
        uint256 ethAmount,
        address seller,
        uint256 deadline
    ) external payable whenNotPaused {
        require(block.timestamp <= deadline, "OVER_TIME");
        require(acceptedTokenList[ETH], "NON_ACCEPTABLE_TOKEN");
        require(offerState[btcNFTId] != OSTATE.CREATED, "DISABLE_CREATE_OFFER");

        uint256 buyFeeAmount = (ethAmount * buyFeeList[ETH]) / FEE_DENOMINATOR;

        // fee check
        if (buyFeeAmount < minFeeAmountList[ETH]) {
            buyFeeAmount = minFeeAmountList[ETH];
        }

        require(
            msg.value >= (ethAmount + buyFeeAmount),
            "INSUFFICIENT_ETH_AMOUNT"
        );
        pendingFees[ETH] += buyFeeAmount;

        orderNumber += 1;

        buyerHistory[msg.sender][ETH] += ethAmount;

        offerInfo[orderNumber] = OfferInfo({
            buyer: msg.sender,
            inscriptionID: inscriptionID,
            btcNFTId: btcNFTId,
            nft_owner: nft_owner,
            nft_receiver: nft_receiver,
            token: ETH,
            amount: ethAmount,
            seller: seller,
            state: OSTATE.CREATED
        });
        offerState[btcNFTId] = OSTATE.CREATED;

        uint256 remainETH = msg.value - (ethAmount + buyFeeAmount);
        if (remainETH > 0) {
            payable(msg.sender).transfer(remainETH);
        }

        emit LogBuyBTCNFT(
            orderNumber,
            msg.sender,
            btcNFTId,
            inscriptionID,
            nft_owner,
            nft_receiver,
            ETH,
            ethAmount,
            seller
        );
    }

    function buyBTCNFT(
        string calldata inscriptionID,
        uint256 btcNFTId,
        string calldata nft_owner,
        string calldata nft_receiver,
        IERC20 token,
        uint256 amount,
        address seller,
        uint256 deadline
    ) external whenNotPaused {
        require(block.timestamp <= deadline, "OVER_TIME");
        require(acceptedTokenList[address(token)], "NON_ACCEPTABLE_TOKEN");
        require(offerState[btcNFTId] != OSTATE.CREATED, "DISABLE_CREATE_OFFER");

        uint256 buyFeeAmount = (amount * buyFeeList[address(token)]) /
            FEE_DENOMINATOR;

        // fee check
        if (buyFeeAmount < minFeeAmountList[address(token)]) {
            buyFeeAmount = minFeeAmountList[address(token)];
        }

        SafeERC20.safeTransferFrom(
            token,
            msg.sender,
            address(this),
            amount + buyFeeAmount
        );
        pendingFees[address(token)] += buyFeeAmount;

        orderNumber += 1;

        buyerHistory[msg.sender][address(token)] += amount;

        offerInfo[orderNumber] = OfferInfo({
            buyer: msg.sender,
            inscriptionID: inscriptionID,
            btcNFTId: btcNFTId,
            nft_owner: nft_owner,
            nft_receiver: nft_receiver,
            token: address(token),
            amount: amount,
            seller: seller,
            state: OSTATE.CREATED
        });
        offerState[btcNFTId] = OSTATE.CREATED;

        emit LogBuyBTCNFT(
            orderNumber,
            msg.sender,
            btcNFTId,
            inscriptionID,
            nft_owner,
            nft_receiver,
            address(token),
            amount,
            seller
        );
    }

    function offerCheck(
        uint256 _orderNumber,
        OSTATE _state
    ) external whenNotPaused onlyAdmins {
        require(
            (_state == OSTATE.ALLOWED) || (_state == OSTATE.CANCELED),
            "UNKNOWN_STATE"
        );

        // Should be check previous order first
        if (_orderNumber > 1) {
            bool cond = (offerInfo[_orderNumber - 1].state == OSTATE.ALLOWED) ||
                (offerInfo[_orderNumber - 1].state == OSTATE.CANCELED) ||
                (offerInfo[_orderNumber - 1].state == OSTATE.COMPLETED);
            require(cond, "PREVIOUS_OFFER_WAS_NOT_CHECK_YET");
        }

        uint256 btcNFTId = offerInfo[_orderNumber].btcNFTId;

        require(
            (offerState[btcNFTId] == OSTATE.CREATED) &&
                (offerInfo[_orderNumber].state == OSTATE.CREATED),
            "CANNOT_OFFER_CHECk"
        );

        offerInfo[_orderNumber].state = _state;
        offerState[btcNFTId] = _state;

        checkedOrderNumber = _orderNumber;

        emit LogOfferCheck(_orderNumber, _state);
    }

    function withdrawOrder(uint256 _orderNumber) external whenNotPaused {
        require(offerInfo[_orderNumber].seller == msg.sender, "NOT_SELLER");
        require(offerInfo[_orderNumber].state == OSTATE.ALLOWED, "NOT_ALLOWED");

        address token = offerInfo[_orderNumber].token;
        uint256 amount = offerInfo[_orderNumber].amount;
        uint256 sellFeeAmount = (amount * sellFeeList[token]) / FEE_DENOMINATOR;

        // fee check
        if (sellFeeAmount < minFeeAmountList[address(token)]) {
            sellFeeAmount = minFeeAmountList[address(token)];
            if (sellFeeAmount > amount) {
                sellFeeAmount = amount;
            }
        }

        pendingFees[token] += sellFeeAmount;

        if (token == ETH) {
            payable(msg.sender).transfer(amount - sellFeeAmount);
        } else {
            SafeERC20.safeTransfer(
                IERC20(token),
                msg.sender,
                amount - sellFeeAmount
            );
        }

        sellerHistory[msg.sender][token] += amount;

        offerInfo[_orderNumber].state = OSTATE.COMPLETED;

        withdrawNumber += 1;
        withdrawHistory[withdrawNumber] = _orderNumber;

        emit LogWithdrawOrder(_orderNumber);
    }

    function withdrawCancelOrder(
        uint256 _orderNumber,
        uint256 _amount
    ) external onlyOwner {
        require(
            offerInfo[_orderNumber].state == OSTATE.CANCELED,
            "NOT_CANCELED"
        );

        // No Sell Fee because Cancel
        require(_amount <= offerInfo[_orderNumber].amount, "OVERFLOW_AMOUNT");

        address token = offerInfo[_orderNumber].token;
        address buyer = offerInfo[_orderNumber].buyer;

        buyerHistory[msg.sender][token] -= offerInfo[_orderNumber].amount;
        if (token == ETH) {
            payable(buyer).transfer(_amount);
        } else {
            SafeERC20.safeTransfer(IERC20(token), buyer, _amount);
        }

        emit LogWithdrawCancelOrder(_orderNumber);
    }

    function withdrawFee(
        IERC20 token,
        uint256 amount,
        uint256 ethAmount
    ) external onlyOwner {
        if (amount <= pendingFees[address(token)]) {
            pendingFees[address(token)] -= amount;
            SafeERC20.safeTransfer(IERC20(token), msg.sender, amount);
        }

        if (ethAmount <= pendingFees[ETH]) {
            pendingFees[ETH] -= ethAmount;
            payable(msg.sender).transfer(ethAmount);
        }

        emit LogWithdrawFee(msg.sender, token, amount, ethAmount);
    }
}
