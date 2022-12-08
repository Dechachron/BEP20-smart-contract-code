// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "github.com/Dechachron/IBEP20-Interface/blob/main/IBEP20.sol";
import "github.com/Dechachron/Abstract/blob/main/abstract.sol";
import "github.com/Dechachron/Ownable/blob/main/Ownable.sol";
import "github.com/Dechachron/Library-SafeMath/blob/main/Library%20safemath.sol";
import "github.com/Dechachron/context-IBEP20-IBEP20Metadata/blob/main/context-ibep20-ibep20metadata.sol";
import "github.com/Dechachron/Dividend/blob/main/Dividend.sol";
import "github.com/Dechachron/IterableMapping/blob/main/IterableMapping.sol";
import "github.com/Dechachron/uniswap-router-Interface/blob/main/Uniswap%20liquidity%20router.sol";
import "github.com/Dechachron/Locktoken-is-ownable/blob/main/Locktoken%20is%20ownable.sol";

contract Dechachron is BEP20, LockToken {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public  uniswapV2Pair;

    bool private swapping;

    DechachronDividendTracker public dividendTracker;

    address public deadWallet = 0x000000000000000000000000000000000000dEaD;

    address public immutable BUSD = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56); //BUSD

    uint256 public _totalSupply = 200_000_000 * (10**18);
    uint256 public swapTokensAtAmount = 20_000_000 * (10**18); //20 millions. 
    uint256 public _maxTxAmount = _totalSupply.mul(2).div(100);//2%

    uint256 public BUSDRewardsFee = 5;
    uint256 public liquidityFee = 2;
    uint256 public marketingFee = 1;
    uint256 public DeveloperFundProgramFee = 1;
    
    uint256 public totalFees = BUSDRewardsFee.add(liquidityFee).add(marketingFee).add(DeveloperFundProgramFee);

    address payable public _marketingWalletAddress = payable(0x675c82790C1B9910334f306408dd3b8B04c72F3A);
    address payable public _DeveloperFundProgramWalletAddress = payable(0x038AD631521D4130A7d016986EE6B73093AB850c);

    uint256 public gasForProcessing = 300000;
    mapping (address => bool) private _isExcludedFromFees;
    mapping (address => bool) public automatedMarketMakerPairs;
    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);
    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);
    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);
    event SendDividends(uint256 tokensSwapped, uint256 amount);
    event ProcessedDividendTracker(uint256 iterations, uint256 claims,uint256 lastProcessedIndex, bool indexed automatic, uint256 gas, address indexed processor);
    
    constructor() BEP20("Dechachron", "DCN") 
    {
        dividendTracker = new DechachronDividendTracker();
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
         
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());
        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;
        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);
        
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(deadWallet);
        dividendTracker.excludeFromDividends(address(_uniswapV2Router));
        
        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        excludeWalletsFromWhales();
        _mint(owner(), _totalSupply);
    }
    
    receive() external payable { }


    function updateDividendTracker(address newAddress) public onlyOwner 
    {
        require(newAddress != address(dividendTracker), "Dechachron: The dividend tracker already has that address");
        DechachronDividendTracker newDividendTracker = DechachronDividendTracker(payable(newAddress));
        require(newDividendTracker.owner() == address(this), "Dechachron: The new dividend tracker must be owned by the Dechachron token contract");
        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));
        emit UpdateDividendTracker(newAddress, address(dividendTracker));
        dividendTracker = newDividendTracker;
    }

    function updateUniswapV2Router(address newAddress) public onlyOwner {
        require(newAddress != address(uniswapV2Router), "Dechachron: The router already has that address");
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
        address _uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());
        uniswapV2Pair = _uniswapV2Pair;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "Dechachron: Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }
        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setBUSDRewardsFee(uint256 value) external onlyOwner{
        BUSDRewardsFee = value;
        totalFees = BUSDRewardsFee.add(liquidityFee).add(marketingFee).add(DeveloperFundProgramFee);
        require(totalFees<=30, "To High Fee");
    }

    function setLiquidityFee(uint256 value) external onlyOwner{
        liquidityFee = value;
        totalFees = BUSDRewardsFee.add(liquidityFee).add(marketingFee).add(DeveloperFundProgramFee);
        require(totalFees<=30, "To High Fee");
    }

    function setMarketingFee(uint256 value) external onlyOwner{
        marketingFee = value;
        totalFees = BUSDRewardsFee.add(liquidityFee).add(marketingFee).add(DeveloperFundProgramFee);
        require(totalFees<=30, "To High Fee");
    }


    function setDeveloperFundProgramFee(uint256 value) external onlyOwner {
        DeveloperFundProgramFee = value;
        totalFees = BUSDRewardsFee.add(liquidityFee).add(marketingFee).add(DeveloperFundProgramFee);
        require(totalFees<=30, "To High Fee");
    } 

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(pair != uniswapV2Pair, "Dechachron: The PanBUSDSwap pair cannot be removed from automatedMarketMakerPairs");
        _setAutomatedMarketMakerPair(pair, value);
    }
    

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(automatedMarketMakerPairs[pair] != value, "Dechachron: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;

        if(value) {
            dividendTracker.excludeFromDividends(pair);
        }
        emit SetAutomatedMarketMakerPair(pair, value);
    }


    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(newValue >= 200000 && newValue <= 500000, "Dechachron: gasForProcessing must be between 200,000 and 500,000");
        require(newValue != gasForProcessing, "Dechachron: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getClaimWait() external view returns(uint256) {
        return dividendTracker.claimWait();
    }

    function setSwapTokensAtAmount(uint256 _value) external onlyOwner
    {
        swapTokensAtAmount = _value;
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account) public view returns(uint256) {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function dividendTokenBalanceOf(address account) public view returns (uint256) {
        return dividendTracker.balanceOf(account);
    }

    function excludeFromDividends(address account) external onlyOwner{
        dividendTracker.excludeFromDividends(account);
    }

    function getAccountDividendsInfo(address account)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return dividendTracker.getAccount(account);
    }

    function getAccountDividendsInfoAtIndex(uint256 index)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return dividendTracker.getAccountAtIndex(index);
    }

    function _transfer(address from, address to, uint256 amount) internal open(from, to) override 
    {
        require(from != address(0), "BEP20: transfer from the zero address");
        require(to != address(0), "BEP20: transfer to the zero address");
        
        if(from != owner() && to != owner()) {
            require(amount <= _maxTxAmount, "Transfer amount exceeds the maxTxAmount.");
        }

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        uint256 contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if( canSwap && !swapping && swapAndLiquifyEnabled &&
        !automatedMarketMakerPairs[from] && from != owner()) 
        {
            swapping = true;

            uint256 swapableFees = totalFees.sub(BUSDRewardsFee); // marketingFee+DeveloperFundProgramFee+liquidityFee.
            uint256 swapTokens = contractTokenBalance.mul(swapableFees).div(totalFees);
            swapAndLiquify(swapTokens);

            uint256 sellTokens = balanceOf(address(this));
            swapAndSendDividends(sellTokens);
            swapping = false;

        }

        bool takeFee = !swapping;

        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) 
        {
            takeFee = false;
        }

        if(takeFee) 
        {
            uint256 fees = amount.mul(totalFees).div(100);
            amount = amount.sub(fees);
            super._transfer(from, address(this), fees);
        }

        checkForWhale(from, to, amount);
        super._transfer(from, to, amount);
        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if(!swapping) 
        {
            uint256 gas = gasForProcessing;
            try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
            }
            catch {

            }
        }
    }

    function swapAndLiquify(uint256 tokens) private 
    {
       uint256 swapableFee = totalFees.sub(BUSDRewardsFee);
        uint256 halfLiquidityTokens = tokens.mul(liquidityFee).div(swapableFee).div(2);
        uint256 swapableTokens = tokens.sub(halfLiquidityTokens);
        uint256 initialBalance = address(this).balance;
        swapTokensForEth(swapableTokens); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered
        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);
        uint256 bnbForLiquidity = newBalance.mul(liquidityFee).div(swapableFee).div(2);
        // add liquidity to uniswap
        addLiquidity(halfLiquidityTokens, bnbForLiquidity);
        emit SwapAndLiquify(halfLiquidityTokens, bnbForLiquidity, halfLiquidityTokens);
        uint256 bnbForMarketing = newBalance.mul(marketingFee).div(swapableFee);
        uint256 bnbForDeveloperFundProgram = newBalance.sub(bnbForLiquidity).sub(bnbForMarketing);
        _marketingWalletAddress.transfer(bnbForMarketing);
        _DeveloperFundProgramWalletAddress.transfer(bnbForDeveloperFundProgram);
    }
    
    function swapTokensForEth(uint256 tokenAmount) private 
    {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function swapTokensForBUSD(uint256 tokenAmount) private 
    {
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        path[2] = BUSD;
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0),
            block.timestamp
        );

    }

    function swapAndSendDividends(uint256 tokens) private{
        swapTokensForBUSD(tokens);
        uint256 dividends = IBEP20(BUSD).balanceOf(address(this));
        bool success = IBEP20(BUSD).transfer(address(dividendTracker), dividends);

        if (success) {
            dividendTracker.distributeBUSDDividends(dividends);
            emit SendDividends(tokens, dividends);
        }
    }

    function setMaxTxAmount(uint256 _amount) external onlyOwner
    {
        _maxTxAmount = _amount;
    }
    
    bool public swapAndLiquifyEnabled = false;
    event SwapAndLiquifyEnabledUpdated(bool enabled);

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner 
    {
      swapAndLiquifyEnabled = _enabled;
      emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    mapping (address => bool) private _isExcludedFromWhale;
    uint256 public _walletHoldingMaxLimit = _totalSupply.div(100).mul(2); //2%
    uint256 public _amountDueForSaleLimit = _totalSupply.div(1000000); //0.0000001%

    uint256 maxAllowedSalePercentage = 50;

    function excludeWalletsFromWhales() private 
    {
        _isExcludedFromWhale[owner()]=true;
        _isExcludedFromWhale[address(this)]=true;
        _isExcludedFromWhale[address(0)]=true;
        _isExcludedFromWhale[uniswapV2Pair]=true;
    }

    function checkForWhale(address from, address to, uint256 amount) 
    private view
    {
        uint256 newBalance = balanceOf(to).add(amount);
        if(!_isExcludedFromWhale[from] && !_isExcludedFromWhale[to]) 
        { 
            require(newBalance <= _walletHoldingMaxLimit, "Exceeding max tokens limit in the wallet"); 
        } 
        if(automatedMarketMakerPairs[from] && !_isExcludedFromWhale[to]) 
        { 
            require(newBalance <= _walletHoldingMaxLimit, "Exceeding max tokens limit in the wallet"); 
        } 

        if(automatedMarketMakerPairs[to] && !_isExcludedFromWhale[from]) 
        { 
            uint256 _balance = balanceOf(from);
            if(_balance>_amountDueForSaleLimit)
            {
                uint256 allowedToSell = _balance.mul(maxAllowedSalePercentage).div(100);
                require(amount <= allowedToSell, "Exceeding Allowed Sale Limit"); 
            }

        }
    }

    function setExcludedFromWhale(address account, bool _enabled) external onlyOwner 
    {
        _isExcludedFromWhale[account] = _enabled;
    } 

    function  setWalletMaxHoldingLimit(uint256 _amount) external onlyOwner 
    {
            _walletHoldingMaxLimit = _amount;
    } 

}

contract DechachronDividendTracker is Ownable, DividendPayingToken {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;

    mapping (address => bool) public excludedFromDividends;

    mapping (address => uint256) public lastClaimTimes;

    uint256 public claimWait;
    uint256 public immutable minimumTokenBalanceForDividends;

    event ExcludeFromDividends(address indexed account);
    event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event Claim(address indexed account, uint256 amount, bool indexed automatic);

    constructor() DividendPayingToken("Dechachron_Dividend_Tracker", "Dechachron_Dividend_Tracker") {
        claimWait = 3600;
        minimumTokenBalanceForDividends = 2 * (10**18); //must hold 2 Two+ tokens
    }
    
    function _transfer(address, address, uint256) internal pure override {
        require(false, "Dechachron_Dividend_Tracker: No transfers allowed");
    }

    function withdrawDividend() public pure override {
        require(false, "Dechachron_Dividend_Tracker: withdrawDividend disabled. Use the 'claim' function on the main Dechachron contract.");
    }

    function excludeFromDividends(address account) external onlyOwner {
        require(!excludedFromDividends[account]);
        excludedFromDividends[account] = true;

        _setBalance(account, 0);
        tokenHoldersMap.remove(account);

        emit ExcludeFromDividends(account);
    }

    function updateClaimWait(uint256 newClaimWait) external onlyOwner {
        require(newClaimWait >= 3600 && newClaimWait <= 86400, "Dechachron_Dividend_Tracker: claimWait must be updated to between 1 and 24 hours");
        require(newClaimWait != claimWait, "Dechachron_Dividend_Tracker: Cannot update claimWait to same value");
        emit ClaimWaitUpdated(newClaimWait, claimWait);
        claimWait = newClaimWait;
    }
    
    function getLastProcessedIndex() external view returns(uint256) {
        return lastProcessedIndex;
    }

    function getNumberOfTokenHolders() external view returns(uint256) {
        return tokenHoldersMap.keys.length;
    }

    function getAccount(address _account)
        public view returns (
            address account,
            int256 index,
            int256 iterationsUntilProcessed,
            uint256 withdrawableDividends,
            uint256 totalDividends,
            uint256 lastClaimTime,
            uint256 nextClaimTime,
            uint256 secondsUntilAutoClaimAvailable) {
        account = _account;

        index = tokenHoldersMap.getIndexOfKey(account);

        iterationsUntilProcessed = -1;

        if(index >= 0) {
            if(uint256(index) > lastProcessedIndex) {
                iterationsUntilProcessed = index.sub(int256(lastProcessedIndex));
            }
            else {
                uint256 processesUntilEndOfArray = tokenHoldersMap.keys.length > lastProcessedIndex ?
                                                        tokenHoldersMap.keys.length.sub(lastProcessedIndex) :
                                                        0;


                iterationsUntilProcessed = index.add(int256(processesUntilEndOfArray));
            }
        }


        withdrawableDividends = withdrawableDividendOf(account);
        totalDividends = accumulativeDividendOf(account);

        lastClaimTime = lastClaimTimes[account];

        nextClaimTime = lastClaimTime > 0 ?
                                    lastClaimTime.add(claimWait) :
                                    0;

        secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp ?
                                                    nextClaimTime.sub(block.timestamp) :
                                                    0;
    }

    function getAccountAtIndex(uint256 index)
        public view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        if(index >= tokenHoldersMap.size()) {
            return (0x0000000000000000000000000000000000000000, -1, -1, 0, 0, 0, 0, 0);
        }

        address account = tokenHoldersMap.getKeyAtIndex(index);

        return getAccount(account);
    }

    function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
        if(lastClaimTime > block.timestamp)  {
            return false;
        }

        return block.timestamp.sub(lastClaimTime) >= claimWait;
    }

    function setBalance(address payable account, uint256 newBalance) external onlyOwner {
        if(excludedFromDividends[account]) {
            return;
        }

        if(newBalance >= minimumTokenBalanceForDividends) {
            _setBalance(account, newBalance);
            tokenHoldersMap.set(account, newBalance);
        }
        else {
            _setBalance(account, 0);
            tokenHoldersMap.remove(account);
        }

        processAccount(account, true);
    }

    function process(uint256 gas) public returns (uint256, uint256, uint256) {
        uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

        if(numberOfTokenHolders == 0) {
            return (0, 0, lastProcessedIndex);
        }

        uint256 _lastProcessedIndex = lastProcessedIndex;

        uint256 gasUsed = 0;

        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        uint256 claims = 0;

        while(gasUsed < gas && iterations < numberOfTokenHolders) {
            _lastProcessedIndex++;

            if(_lastProcessedIndex >= tokenHoldersMap.keys.length) {
                _lastProcessedIndex = 0;
            }

            address account = tokenHoldersMap.keys[_lastProcessedIndex];

            if(canAutoClaim(lastClaimTimes[account])) {
                if(processAccount(payable(account), true)) {
                    claims++;
                }
            }

            iterations++;

            uint256 newGasLeft = gasleft();

            if(gasLeft > newGasLeft) {
                gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
            }

            gasLeft = newGasLeft;
        }

        lastProcessedIndex = _lastProcessedIndex;

        return (iterations, claims, lastProcessedIndex);
    }

    function processAccount(address payable account, bool automatic) public onlyOwner returns (bool) {
        uint256 amount = _withdrawDividendOfUser(account);

        if(amount > 0) {
            lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount, automatic);
            return true;
        }

        return false;
    }
}