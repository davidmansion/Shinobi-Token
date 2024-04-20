// SPDX-License-Identifier: MIT

pragma solidity 0.8.21;

// OPENZEPPELIN IMPORTS
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// UNISWAP INTERFACES
import {IUniswapRouter02, IUniswapFactory, IUniswapPair} from "./interfaces/IUniswapV2.sol";

/**
 * @title SHINOBI Token
 * @author Semi Invader
 * @notice This is the token for Swap N Go on the BSC chain. It is an ERC20 token with a fixed supply.
 * Total Init Supply: 1,000,000,000 SHO
 * Decimals: 18
 * Symbol: SHO
 * Name: Shinobi Token
 * This contract contains editable taxes for SHO
 * Init Buy Tax: 2%
 * Init Sell Tax: 5%
 * All taxes gathered are sold for SHIDO and sent to the development wallet for team distribution
 * into marketing / dev / etc.
 */
contract SHINOBIToken is ERC20, Ownable {
    //-------------------------------------------------------------------------
    // Errors
    //-------------------------------------------------------------------------
    error SHO__InvalidBuyTax();
    error SHO__InvalidListLength();
    error SHO__OnlyDevWallet();
    error SHO__NativeTransferFailed();
    error SHO__AlreadySwapping();
    //-------------------------------------------------------------------------
    // STATE VARIABLES
    //-------------------------------------------------------------------------
    mapping(address => bool) public isExcludedFromTax;
    // We can add more pairs to tax them when necessary
    mapping(address => bool) public isPair;

    address public devWallet;
    IUniswapRouter02 public router;
    IUniswapPair public pair;

    uint public sellThreshold;

    uint8 public buyTax = 2;
    uint8 public sellTax = 5;

    uint256 private constant _INIT_SUPPLY = 1_000_000_000 ether;
    uint256 private constant PERCENTILE = 100;
    uint8 private swapping = 1;
    //-------------------------------------------------------------------------
    // EVENTS
    //-------------------------------------------------------------------------
    event UpdateSellTax(uint tax);
    event UpdateBuyTax(uint tax);
    event UpdateDevWallet(
        address indexed prevWallet,
        address indexed newWallet
    );
    event UpdateTaxExclusionStatus(address indexed account, bool status);
    event UpdateThreshold(uint threshold);
    event AddedPair(address indexed pair);

    //-------------------------------------------------------------------------
    // CONSTRUCTOR
    //-------------------------------------------------------------------------
    constructor() ERC20("SHINOBI", "SHO") Ownable(msg.sender) {
        // Sell Threshold is 0.25% of the total supply
        sellThreshold = _INIT_SUPPLY / (4 * PERCENTILE);
        // Setup PancakeSwap Contracts
        if (block.chainid == 56) {
            router = IUniswapRouter02(
                0x10ED43C718714eb63d5aA57B78B54704E256024E
            );
        }
        if (block.chainid == 97) {
            router = IUniswapRouter02(
                0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3
            );
        }
        IUniswapFactory factory = IUniswapFactory(router.factory());
        pair = IUniswapPair(factory.createPair(address(this), router.WETH()));
        isPair[address(pair)] = true;
        _approve(address(this), address(router), type(uint256).max);

        isExcludedFromTax[owner()] = true;
        isExcludedFromTax[address(this)] = true;
        devWallet = msg.sender;
        _mint(owner(), _INIT_SUPPLY);
    }

    //-------------------------------------------------------------------------
    // EXTERNAL / PUBLIC FUNCTIONS
    //-------------------------------------------------------------------------
    // Allow contract to receive Native tokens
    receive() external payable {}

    fallback() external payable {}

    //-------------------------------------------------------------------------
    // Owner Functions
    //-------------------------------------------------------------------------
    /**
     * @notice This function is called to edit the buy tax for SHO
     * @param _buyTax The new buy tax to set
     * @dev the tax can only be a max of 10%
     */
    function setBuyTax(uint8 _buyTax) external onlyOwner {
        if (_buyTax > 10) {
            revert SHO__InvalidBuyTax();
        }
        buyTax = _buyTax;
        emit UpdateBuyTax(_buyTax);
    }

    /**
     * @notice This function is called to edit the buy tax for SHO
     * @param _sellTax The new buy tax to set
     * @dev the tax can only be a max of 10%
     */
    function setSellTax(uint8 _sellTax) external onlyOwner {
        if (_sellTax > 10) {
            revert SHO__InvalidBuyTax();
        }
        sellTax = _sellTax;
        emit UpdateBuyTax(_sellTax);
    }

    /**
     * @notice Changes the tax exclusion status for an address
     * @param _address The address to set the tax exclusion status for
     * @param _status The exclusion status, TRUE for excluded, FALSE for not excluded
     */
    function setTaxExclusionStatus(
        address _address,
        bool _status
    ) external onlyOwner {
        isExcludedFromTax[_address] = _status;
        emit UpdateTaxExclusionStatus(_address, _status);
    }

    /**
     * @notice Changes the tax exclusion status for multiple addresses
     * @param addresses The list of addresses to set the tax exclusion status for
     * @param _status The exclusion status, TRUE for excluded, FALSE for not excluded for all addresses
     */
    function setMultipleTaxExclusionStatus(
        address[] calldata addresses,
        bool _status
    ) external onlyOwner {
        if (addresses.length == 0) {
            revert SHO__InvalidListLength();
        }
        for (uint256 i = 0; i < addresses.length; i++) {
            isExcludedFromTax[addresses[i]] = _status;
            emit UpdateTaxExclusionStatus(addresses[i], _status);
        }
    }

    /**
     * @notice Set a different wallet to receive the swapped out funds
     * @param _devWallet The new dev wallet to set
     * @dev ONLY CURRENT DEV WALLET AND OWNER CAN CHANGE THIS
     */
    function updateDevWallet(address _devWallet) external {
        if (msg.sender != devWallet && msg.sender != owner())
            revert SHO__OnlyDevWallet();
        emit UpdateDevWallet(devWallet, _devWallet);
        devWallet = _devWallet;
    }

    /**
     * @notice The sell threshold is the amount of SHO that needs to be collected before a sell for Native happens
     * @param _sellThreshold The new sell threshold to set
     */
    function updateSellThreshold(uint _sellThreshold) external onlyOwner {
        sellThreshold = _sellThreshold;
        emit UpdateThreshold(_sellThreshold);
    }

    /**
     * @notice This function is used to add pairs to the list of pairs to tax
     * @param _pair The pair to add to the list of pairs to tax
     */
    function addPair(address _pair) external onlyOwner {
        isPair[_pair] = true;
        emit AddedPair(_pair);
    }

    function manualSwap() external onlyOwner {
        if (swapping != 1) revert SHO__AlreadySwapping();
        uint balance = balanceOf(address(this));
        _swapAndTransfer(balance);
    }

    //-------------------------------------------------------------------------
    // INTERNAL/PRIVATE FUNCTIONS
    //-------------------------------------------------------------------------
    /**
     * @notice This function overrides the ERC20 `_transfer` function to apply taxes and swap and transfer.
     * @param from Address that is sending tokens
     * @param to Address that is receiving tokens
     * @param amount Amount of tokens being transfered
     * @dev Although this is an override, it still uses the original `_transfer` function from the ERC20 contract to finalize the updatess
     */
    function _update(address from, address to, uint amount) internal override {
        bool isBuy = isPair[from];
        bool isSell = isPair[to];
        bool anyExcluded = isExcludedFromTax[from] || isExcludedFromTax[to];

        uint currentOBIBalance = balanceOf(address(this));
        if (
            !isBuy &&
            currentOBIBalance > sellThreshold &&
            !anyExcluded &&
            swapping == 1
        ) {
            _swapAndTransfer(currentOBIBalance);
        }

        uint fee = 0;
        if (!anyExcluded) {
            if (isBuy) {
                fee = (amount * buyTax) / PERCENTILE;
            } else if (isSell) {
                fee = (amount * sellTax) / PERCENTILE;
            }
            if (fee > 0) {
                amount -= fee;
                super._update(from, address(this), fee);
            }
        }
        super._update(from, to, amount);
    }

    function _swapAndTransfer(uint balance) private {
        swapping <<= 1;
        // Swap SHO for BNB
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            balance,
            0,
            path,
            devWallet,
            block.timestamp
        );
        uint nativeBalance = address(this).balance;
        // Transfer SHIDO to dev wallet
        (bool success, ) = devWallet.call{value: nativeBalance}("");
        if (!success) revert SHO__NativeTransferFailed();
        swapping >>= 1;
    }
}
