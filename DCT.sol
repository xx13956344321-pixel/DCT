// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DCT — Dapp Chain Token（ERC20 + 质押）
 * @notice 实现依据：《DCT 代币合约（ERC20+质押系统）详细功能列表》.docx
 * @dev 时间轴一律为 block.number；与「约 12 秒/块」对应的年区块数用于 APY 折算。
 *      OpenZeppelin 建议 5.6.x；Solidity ^0.8.34。
 *
 *      部署角色说明：
 *      - `multiSig_` 与 `timelock_` 允许相同（例如测试网）；生产环境建议不同地址，以便日常治理与 Ownable/紧急救援权限分离。
 *      - 手续费/违约金通过本合约内置 ERC20 `_transfer` 转入 `stakeFeeCollector`（即 MultiSig）。OZ ERC20 仅更新余额映射，
 *        不会对收款地址执行外部调用，因此常见多签（Safe 等）作为 EOA/合约地址接收 DCT 不会因「收款方执行代码 revert」而导致质押失败。
 */
contract DCT is ERC20, ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // -------------------------------------------------------------------------
    // 角色（部署时写入，字节码级不可改，避免链下配置错误）
    // -------------------------------------------------------------------------

    address private immutable _multiSig;
    address private immutable _timelock;

    // -------------------------------------------------------------------------
    // 代币参数（文档 2.1）— 注意：所有「枚」在链上均以 10^18 wei 表示
    // -------------------------------------------------------------------------

    string private constant _NAME = "Dapp Chain Token";
    string private constant _SYMBOL = "DCT";

    /// @dev 文档：小数位 18 → 1 DCT = 1e18 单位
    uint8 private constant _DECIMALS = 18;

    /// @dev 总供应：1_000_000_000 * 10^18 wei（与 _DECIMALS=18 一致），部署时一次性 mint，无增发
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // -------------------------------------------------------------------------
    // 手续费 / 违约金（文档 4.2、6.2：固定，不提供链上 setter）
    // -------------------------------------------------------------------------

    /// @dev 分母固定 10_000 = 100%，与 bps 定义一致
    uint256 public constant FEE_DENOMINATOR = 10_000;

    /// @dev 质押手续费 100 bps = 1%，从用户输入的 amount 中扣，再划本金进合约
    uint256 public constant STAKE_FEE_BPS = 100;

    /// @dev 手续费接收方 = MultiSig（immutable）。转入使用标准 ERC20 记账，不调用收款方代码，见合约级 @dev 说明
    address public immutable stakeFeeCollector;

    /// @dev 提前解押违约金 300 bps = 3%，从本金扣，文档要求链上不可改
    uint256 public constant EARLY_UNSTAKE_PENALTY_BPS = 300;

    // -------------------------------------------------------------------------
    // 质押档位与 APY（文档 4.1、4.5）
    // -------------------------------------------------------------------------

    enum StakeDuration {
        SEVEN_DAYS,
        THIRTY_DAYS,
        NINETY_DAYS,
        ONE_EIGHTY_DAYS
    }

    /// @dev 锁仓区块：7d/30d/90d/180d 按 12s/块
    uint256[4] public stakeDurations;

    /// @dev 奖励倍数分子；分母 MULTIPLIER_DENOMINATOR=100 → 1.0x / 1.2x / 1.5x / 2.0x
    uint256[4] public rewardMultipliers;

    /// @dev 基础 APY：1000 bps = 10%，文档要求不可链上修改
    uint256 public constant STAKING_APY_BPS = 1000;

    uint256 public constant CEILING_STAKE_AMOUNT = 10 ** 27;
    uint256 public constant FLOOR_STAKE_AMOUNT = 10 ** 18;

    /// @dev 年区块数 ≈ 365.25 * 24 * 3600 / 12
    uint256 public constant BLOCKS_PER_YEAR = 2_628_000;

    uint256 public constant MAX_TIER_MULTIPLIER = 200;
    uint256 public constant MAX_USER_STAKE_COUNT = 50;
    uint256 public constant MULTIPLIER_DENOMINATOR = 100;

    uint256 private constant ABSOLUTE_MAX_BATCH_UNSTAKE = 50;

    /// @dev 冷却「区块数」上限，防止治理误设极大值导致算术异常或长期锁死用户路径
    uint256 private constant MAX_COOLDOWN_BLOCKS = 10 * 2_628_000;

    uint256 public maxBatchUnstake;

    // -------------------------------------------------------------------------
    // 冷却（存储字段名 *Sec，实际单位为「区块数」，与文档 ABI 描述一致）
    // -------------------------------------------------------------------------

    struct ActionCooldown {
        uint256 unstakeSec;
        uint256 claimRewardSec;
    }

    ActionCooldown private _actionCooldown;
    mapping(address => uint256) private _lastUnstakeAt;
    mapping(address => uint256) private _lastRewardClaimAt;
    mapping(address => uint256) private _openStakeCount;

    // -------------------------------------------------------------------------
    // 质押记录
    // -------------------------------------------------------------------------

    struct StakeInfo {
        uint256 principal;
        uint256 startTime;
        StakeDuration duration;
        bool isFullyClaimed;
        uint256 accruedReward;
        uint256 lastAccrualTime;
        uint256 claimedReward;
        uint256 claimedPrincipal;
        uint256 stakeAPY;
        uint256 stakeMultiplier;
        uint256 stakeLockDuration;
        uint256 stakeMaxReward;
    }

    mapping(address => StakeInfo[]) public userStakes;

    uint256 public unsettledStakingLiability;
    uint256 public constant REWARD_POOL_BUFFER_BPS = 500;

    uint256 public totalPrincipalStaked;
    uint256 public globalStakeCap;

    // -------------------------------------------------------------------------
    // 事件（文档十二；与固定费率相关的 Updated 事件不设 setter 故不触发）
    // -------------------------------------------------------------------------

    event EmergencyTokenRescue(address indexed token, address indexed to, uint256 amount);
    event Staked(address indexed user, uint256 amount, StakeDuration duration);
    event Unstaked(address indexed user, uint256 principal, uint256 reward, uint256 stakeIndex);
    event ClaimedReward(address indexed user, uint256 indexed stakeIndex, uint256 reward);
    event StakingLiabilityUpdated(uint256 oldLiability, uint256 newLiability);
    event TokensBurned(address indexed burner, uint256 amount);
    event RewardMultipliersUpdated(uint256[4] newMultipliers);
    event StakeDurationsUpdated(uint256[4] newDurations);
    event StakeFeeCharged(address indexed user, uint256 fee, address indexed collector);
    event MaxBatchUnstakeUpdated(uint256 oldMax, uint256 newMax);
    event UnstakeCooldownUpdated(uint256 oldSec, uint256 newSec);
    event StakeRewardsSynced(address indexed user, uint256 indexed stakeIndex, uint256 accruedReward);
    event RewardClaimCooldownUpdated(uint256 oldSec, uint256 newSec);
    event EarlyUnstaked(address indexed user, uint256 principal, uint256 forfeitedReward, uint256 stakeIndex);
    event GlobalStakeCapUpdated(uint256 oldCap, uint256 newCap);
    event CompletedStakeSlotRemoved(address indexed user, uint256 removedIndex, uint256 movedFromIndex);

    // -------------------------------------------------------------------------
    // 错误（文档十三）
    // -------------------------------------------------------------------------

    error NotAuthorized();
    error InvalidAmount();
    error InsufficientBalance();
    error InvalidStakeDuration();
    error StakeNotMature();
    error StakeAlreadyClaimed();
    error InvalidStakeIndex();
    error InsufficientPoolBalance();
    error LiabilityUnderflow();
    error TransferToZeroAddress();
    error InvalidAddress();
    error NotERC20Contract();
    error ProtectedFundsCannotBeRescued();
    error NoRewardAvailable();
    error InvalidDurationsOrder();
    error DurationOutOfRange();
    error InvalidMultiplierOrder();
    error MaxStakeCountReached();
    error BatchUnstakeTooLarge();
    error MaxBatchUnstakeHardCapExceeded();
    error UnstakeCooldownActive();
    error RewardClaimCooldownActive();
    error InvalidBatchOrder();
    error GlobalStakeCapExceeded();
    error StakeNotCompleted();
    error GlobalStakeCapBelowPrincipal();
    error OpenStakeInvariantBroken();
    error CooldownTooLarge();
    error InvalidRescueRecipient();
    error OwnershipCannotBeRenounced();
    error StakingParametersNotReady();
    error StakingAccountingInvariant();

    modifier onlyMultiSigOrTimelock() {
        address s = msg.sender;
        if (s != _multiSig && s != _timelock) revert NotAuthorized();
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != _timelock) revert NotAuthorized();
        _;
    }

    function _blockNow() private view returns (uint256) {
        return block.number;
    }

    /**
     * @param multiSig_ 多签地址（手续费/违约金接收方，即 stakeFeeCollector）
     * @param timelock_ 时间锁地址，兼 Ownable2Step 初始 owner；可与 multiSig_ 相同，生产环境建议区分
     */
    constructor(address multiSig_, address timelock_) ERC20(_NAME, _SYMBOL) Ownable(timelock_) {
        if (multiSig_ == address(0) || timelock_ == address(0)) revert InvalidAddress();
        _multiSig = multiSig_;
        _timelock = timelock_;
        stakeFeeCollector = multiSig_;

        _mint(msg.sender, TOTAL_SUPPLY);

        stakeDurations = [uint256(50400), 216000, 648000, 1296000];
        rewardMultipliers = [uint256(100), 120, 150, 200];

        maxBatchUnstake = 20;
    }

    /// @inheritdoc ERC20
    function decimals() public view virtual override returns (uint8) {
        return _DECIMALS;
    }

    /// @dev 禁止放弃所有权：否则 onlyTimelock（含 emergencyTokenRescue）永久不可用
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipCannotBeRenounced();
    }

    function timelock() external view returns (address) {
        return _timelock;
    }

    function multiSigWallet() external view returns (address) {
        return _multiSig;
    }

    function unstakeCooldownSec() external view returns (uint256) {
        return _actionCooldown.unstakeSec;
    }

    function rewardClaimCooldownSec() external view returns (uint256) {
        return _actionCooldown.claimRewardSec;
    }

    function pause() external onlyMultiSigOrTimelock {
        _pause();
    }

    function unpause() external onlyMultiSigOrTimelock {
        _unpause();
    }

    function _validateForeignERC20(address token) internal view {
        if (token == address(0) || token == address(this)) revert InvalidAddress();
        if (token.code.length == 0) revert NotERC20Contract();

        (bool okSupply, bytes memory retSupply) =
            address(token).staticcall(abi.encodeWithSelector(IERC20.totalSupply.selector));
        if (!okSupply || retSupply.length < 32) revert NotERC20Contract();

        (bool okBal, bytes memory retBal) = address(token).staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        if (!okBal || retBal.length < 32) revert NotERC20Contract();
    }

    function burn(uint256 amount) external nonReentrant whenNotPaused returns (bool) {
        if (amount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
        return true;
    }

    function _increaseLiability(uint256 amount) internal {
        uint256 old = unsettledStakingLiability;
        unsettledStakingLiability = old + amount;
        emit StakingLiabilityUpdated(old, unsettledStakingLiability);
    }

    function _decreaseLiability(uint256 amount) internal {
        uint256 old = unsettledStakingLiability;
        if (old < amount) revert LiabilityUnderflow();
        unsettledStakingLiability = old - amount;
        emit StakingLiabilityUpdated(old, unsettledStakingLiability);
    }

    function _checkStakingPoolSufficiency() internal view {
        uint256 liab = unsettledStakingLiability;
        uint256 required = liab + liab.mulDiv(REWARD_POOL_BUFFER_BPS, FEE_DENOMINATOR);
        if (balanceOf(address(this)) < required) revert InsufficientPoolBalance();
    }

    /// @dev DCT 救援时可动用的上限：需与业务校验一致（负债 + 与 _checkStakingPoolSufficiency 相同的 5% 缓冲）
    function _reservedDctForStaking() internal view returns (uint256) {
        uint256 liab = unsettledStakingLiability;
        return liab + liab.mulDiv(REWARD_POOL_BUFFER_BPS, FEE_DENOMINATOR);
    }

    /**
     * @notice 质押 DCT；`amount` 为 wei（18 位），含手续费基数
     * @dev fee = amount * STAKE_FEE_BPS / FEE_DENOMINATOR；本金 = amount - fee。
     *      手续费 `_transfer` 为标准 ERC20：只改本合约 `balances`，不向 `stakeFeeCollector` 发起 call。
     */
    function stake(uint256 amount, StakeDuration duration) external nonReentrant whenNotPaused returns (bool) {
        if (uint256(duration) >= 4) revert InvalidStakeDuration();
        if (amount < FLOOR_STAKE_AMOUNT || amount > CEILING_STAKE_AMOUNT) revert InvalidAmount();
        if (_openStakeCount[msg.sender] >= MAX_USER_STAKE_COUNT) revert MaxStakeCountReached();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();

        uint256 fee = Math.mulDiv(amount, STAKE_FEE_BPS, FEE_DENOMINATOR);
        uint256 stakeAmount = amount - fee;
        if (stakeAmount == 0) revert InvalidAmount();

        uint256 apy = STAKING_APY_BPS;
        uint256 lockDuration = stakeDurations[uint256(duration)];
        uint256 multiplier = rewardMultipliers[uint256(duration)];
        if (lockDuration == 0 || multiplier == 0) revert StakingParametersNotReady();
        uint256 maxReward = _calculateReward(stakeAmount, apy, lockDuration, multiplier);
        if (maxReward > type(uint256).max - stakeAmount) revert InvalidAmount();
        uint256 reservedLiability = stakeAmount + maxReward;

        if (globalStakeCap > 0 && totalPrincipalStaked + stakeAmount > globalStakeCap) {
            revert GlobalStakeCapExceeded();
        }

        _increaseLiability(reservedLiability);
        _checkStakingPoolSufficiency();

        totalPrincipalStaked += stakeAmount;
        uint256 startBlock = _blockNow();
        unchecked {
            _openStakeCount[msg.sender]++;
        }

        userStakes[msg.sender].push(
            StakeInfo({
                principal: stakeAmount,
                startTime: startBlock,
                duration: duration,
                isFullyClaimed: false,
                accruedReward: 0,
                lastAccrualTime: startBlock,
                claimedReward: 0,
                claimedPrincipal: 0,
                stakeAPY: apy,
                stakeMultiplier: multiplier,
                stakeLockDuration: lockDuration,
                stakeMaxReward: maxReward
            })
        );

        if (fee > 0) {
            _transfer(msg.sender, stakeFeeCollector, fee);
        }
        _transfer(msg.sender, address(this), stakeAmount);
        if (fee > 0) {
            emit StakeFeeCharged(msg.sender, fee, stakeFeeCollector);
        }
        emit Staked(msg.sender, stakeAmount, duration);
        return true;
    }

    function syncStakeRewards(uint256 stakeIndex) external nonReentrant whenNotPaused returns (bool) {
        if (stakeIndex >= userStakes[msg.sender].length) revert InvalidStakeIndex();
        StakeInfo storage s = userStakes[msg.sender][stakeIndex];
        if (s.isFullyClaimed) revert StakeAlreadyClaimed();
        _accrueReward(s);
        emit StakeRewardsSynced(msg.sender, stakeIndex, s.accruedReward);
        return true;
    }

    /// @dev 与 batchUnstake 相同：任一笔失败则整笔交易回滚。
    function batchSyncStakeRewards(uint256[] calldata indexes) external nonReentrant whenNotPaused {
        uint256 len = indexes.length;
        if (len == 0) revert InvalidAmount();
        if (len > maxBatchUnstake) revert BatchUnstakeTooLarge();
        _batchSyncRewardIndices(msg.sender, indexes, len);
    }

    function _batchSyncRewardIndices(address user, uint256[] calldata indexes, uint256 len) private {
        uint256 m = userStakes[user].length;
        for (uint256 i; i < len;) {
            uint256 idx = indexes[i];
            if (idx >= m) revert InvalidStakeIndex();
            if (i != 0 && idx <= indexes[i - 1]) revert InvalidBatchOrder();
            StakeInfo storage st = userStakes[user][idx];
            if (!st.isFullyClaimed) {
                _accrueReward(st);
                emit StakeRewardsSynced(user, idx, st.accruedReward);
            }
            unchecked {
                ++i;
            }
        }
    }

    function claimReward(uint256 stakeIndex) external nonReentrant whenNotPaused returns (bool) {
        _enforceRewardClaimCooldown();
        if (stakeIndex >= userStakes[msg.sender].length) revert InvalidStakeIndex();
        StakeInfo storage s = userStakes[msg.sender][stakeIndex];
        if (s.isFullyClaimed) revert StakeAlreadyClaimed();
        if (_blockNow() < s.startTime + s.stakeLockDuration) revert StakeNotMature();

        _accrueReward(s);
        if (s.claimedReward > s.accruedReward) revert StakingAccountingInvariant();
        uint256 available = s.accruedReward - s.claimedReward;
        if (available == 0) revert NoRewardAvailable();
        if (balanceOf(address(this)) < available) revert InsufficientPoolBalance();
        _checkStakingPoolSufficiency();

        s.claimedReward += available;
        _decreaseLiability(available);
        _checkStakingPoolSufficiency();

        _touchRewardClaimCooldown();
        _transfer(address(this), msg.sender, available);
        emit ClaimedReward(msg.sender, stakeIndex, available);
        return true;
    }

    function unstakeToken(uint256 stakeIndex) external nonReentrant whenNotPaused returns (bool) {
        _unstakeTokenInternal(stakeIndex, true);
        _touchUnstakeCooldown();
        return true;
    }

    function _cooldownCheck(bool unstakeSide) private view {
        uint256 sec = unstakeSide ? _actionCooldown.unstakeSec : _actionCooldown.claimRewardSec;
        if (sec == 0) return;
        uint256 last = unstakeSide ? _lastUnstakeAt[msg.sender] : _lastRewardClaimAt[msg.sender];
        if (last != 0 && _blockNow() < last + sec) {
            if (unstakeSide) revert UnstakeCooldownActive();
            revert RewardClaimCooldownActive();
        }
    }

    function _enforceUnstakeCooldown() internal view {
        _cooldownCheck(true);
    }

    function _enforceRewardClaimCooldown() internal view {
        _cooldownCheck(false);
    }

    function _touchCooldownMap(mapping(address => uint256) storage m, uint256 sec) private {
        if (sec != 0) m[msg.sender] = _blockNow();
    }

    function _touchUnstakeCooldown() internal {
        _touchCooldownMap(_lastUnstakeAt, _actionCooldown.unstakeSec);
    }

    function _touchRewardClaimCooldown() internal {
        _touchCooldownMap(_lastRewardClaimAt, _actionCooldown.claimRewardSec);
    }

    /// @dev 单独函数以降低 `_finalizeUnstakePayout` 栈深度（避免 Remix / 旧 pipeline 报 Stack too deep）
    function _emitEarlyUnstaked(uint256 principal, uint256 stakeMaxReward, uint256 accruedReward, uint256 stakeIndex) private {
        uint256 forfeited = stakeMaxReward > accruedReward ? stakeMaxReward - accruedReward : 0;
        emit EarlyUnstaked(msg.sender, principal, forfeited, stakeIndex);
    }

    function _finalizeUnstakePayout(
        StakeInfo storage s,
        uint256 stakeIndex,
        bool matured,
        uint256 principal,
        uint256 reward,
        uint256 payoutPrincipal,
        uint256 penalty,
        uint256 total
    ) private {
        uint256 liabilityToRelease;
        if (matured) {
            liabilityToRelease = principal + reward;
        } else {
            if (s.claimedReward > s.stakeMaxReward) revert StakingAccountingInvariant();
            liabilityToRelease = principal + (s.stakeMaxReward - s.claimedReward);
        }
        _decreaseLiability(liabilityToRelease);
        _checkStakingPoolSufficiency();

        s.isFullyClaimed = true;
        s.claimedPrincipal = s.principal;
        if (matured) {
            s.claimedReward = s.accruedReward;
        } else {
            s.claimedReward = s.stakeMaxReward;
        }

        uint256 oc = _openStakeCount[msg.sender];
        if (oc == 0) revert OpenStakeInvariantBroken();
        unchecked {
            _openStakeCount[msg.sender] = oc - 1;
        }
        uint256 principalLocked = s.principal;
        totalPrincipalStaked -= principalLocked;

        if (penalty > 0) {
            _transfer(address(this), stakeFeeCollector, penalty);
        }
        _transfer(address(this), msg.sender, total);
        if (penalty > 0) {
            emit StakeFeeCharged(msg.sender, penalty, stakeFeeCollector);
        }
        emit Unstaked(msg.sender, payoutPrincipal, reward, stakeIndex);
        if (!matured) {
            _emitEarlyUnstaked(principal, s.stakeMaxReward, s.accruedReward, stakeIndex);
        }
    }

    function _unstakeTokenInternal(uint256 stakeIndex, bool enforceCooldown) internal {
        if (enforceCooldown) _enforceUnstakeCooldown();
        StakeInfo[] storage stakesRef = userStakes[msg.sender];
        if (stakeIndex >= stakesRef.length) revert InvalidStakeIndex();
        StakeInfo storage s = stakesRef[stakeIndex];
        if (s.isFullyClaimed) revert StakeAlreadyClaimed();

        bool matured = _blockNow() >= s.startTime + s.stakeLockDuration;
        if (matured) {
            _accrueReward(s);
            if (s.claimedReward > s.accruedReward) revert StakingAccountingInvariant();
        }

        uint256 principal = s.principal - s.claimedPrincipal;
        uint256 reward = matured ? (s.accruedReward - s.claimedReward) : 0;
        uint256 penalty;
        uint256 payoutPrincipal = principal;
        if (!matured) {
            penalty = principal.mulDiv(EARLY_UNSTAKE_PENALTY_BPS, FEE_DENOMINATOR);
            payoutPrincipal = principal - penalty;
        }
        uint256 total = payoutPrincipal + reward;
        if (total == 0) revert InvalidAmount();
        if (balanceOf(address(this)) < total) revert InsufficientPoolBalance();

        _finalizeUnstakePayout(s, stakeIndex, matured, principal, reward, payoutPrincipal, penalty, total);
    }

    /// @dev 整笔交易原子：任一笔解押失败则全部回滚（含已循环部分），不会部分成功。
    function batchUnstake(uint256[] calldata indexes) external nonReentrant whenNotPaused {
        uint256 len = indexes.length;
        if (len == 0) revert InvalidAmount();
        if (len > maxBatchUnstake) revert BatchUnstakeTooLarge();
        uint256 stakeLen = userStakes[msg.sender].length;
        for (uint256 j; j < len;) {
            uint256 ix = indexes[j];
            if (ix >= stakeLen) revert InvalidStakeIndex();
            if (j != 0 && ix <= indexes[j - 1]) revert InvalidBatchOrder();
            unchecked {
                ++j;
            }
        }
        _enforceUnstakeCooldown();
        for (uint256 k; k < len;) {
            _unstakeTokenInternal(indexes[k], false);
            unchecked {
                ++k;
            }
        }
        _touchUnstakeCooldown();
    }

    function setMaxBatchUnstake(uint256 newMax) external onlyMultiSigOrTimelock {
        if (newMax == 0) revert InvalidAmount();
        if (newMax > ABSOLUTE_MAX_BATCH_UNSTAKE) revert MaxBatchUnstakeHardCapExceeded();
        uint256 oldMax = maxBatchUnstake;
        maxBatchUnstake = newMax;
        emit MaxBatchUnstakeUpdated(oldMax, newMax);
    }

    function setUnstakeCooldown(uint256 newSeconds) external onlyMultiSigOrTimelock {
        if (newSeconds > MAX_COOLDOWN_BLOCKS) revert CooldownTooLarge();
        uint256 oldSec = _actionCooldown.unstakeSec;
        _actionCooldown.unstakeSec = newSeconds;
        emit UnstakeCooldownUpdated(oldSec, newSeconds);
    }

    function setRewardClaimCooldown(uint256 newSeconds) external onlyMultiSigOrTimelock {
        if (newSeconds > MAX_COOLDOWN_BLOCKS) revert CooldownTooLarge();
        uint256 oldSec = _actionCooldown.claimRewardSec;
        _actionCooldown.claimRewardSec = newSeconds;
        emit RewardClaimCooldownUpdated(oldSec, newSeconds);
    }

    function setRewardMultipliers(uint256[4] calldata newMultipliers) external onlyMultiSigOrTimelock whenNotPaused {
        if (
            newMultipliers[0] <= 10 ||
            newMultipliers[0] > MAX_TIER_MULTIPLIER ||
            newMultipliers[1] <= 10 ||
            newMultipliers[1] > MAX_TIER_MULTIPLIER ||
            newMultipliers[2] <= 10 ||
            newMultipliers[2] > MAX_TIER_MULTIPLIER ||
            newMultipliers[3] <= 10 ||
            newMultipliers[3] > MAX_TIER_MULTIPLIER
        ) revert InvalidAmount();
        if (
            !(newMultipliers[0] < newMultipliers[1] &&
                newMultipliers[1] < newMultipliers[2] &&
                newMultipliers[2] < newMultipliers[3])
        ) revert InvalidMultiplierOrder();

        rewardMultipliers = newMultipliers;
        emit RewardMultipliersUpdated(newMultipliers);
    }

    function setStakeDurations(uint256[4] calldata newDurations) external onlyMultiSigOrTimelock whenNotPaused {
        if (
            !(newDurations[0] < newDurations[1] &&
                newDurations[1] < newDurations[2] &&
                newDurations[2] < newDurations[3])
        ) revert InvalidDurationsOrder();
        if (newDurations[0] < 7200 || newDurations[3] > 2_628_000) revert DurationOutOfRange();

        stakeDurations = newDurations;
        emit StakeDurationsUpdated(newDurations);
    }

    function setGlobalStakeCap(uint256 newCap) external onlyMultiSigOrTimelock {
        if (newCap != 0 && newCap < totalPrincipalStaked) revert GlobalStakeCapBelowPrincipal();
        uint256 oldCap = globalStakeCap;
        globalStakeCap = newCap;
        emit GlobalStakeCapUpdated(oldCap, newCap);
    }

    function removeCompletedStake(uint256 stakeIndex) external nonReentrant {
        StakeInfo[] storage stakes = userStakes[msg.sender];
        uint256 stakeCount = stakes.length;
        if (stakeIndex >= stakeCount) revert InvalidStakeIndex();
        if (!stakes[stakeIndex].isFullyClaimed) revert StakeNotCompleted();
        uint256 lastSlot = stakeCount - 1;
        if (stakeIndex != lastSlot) {
            stakes[stakeIndex] = stakes[lastSlot];
        }
        stakes.pop();
        emit CompletedStakeSlotRemoved(msg.sender, stakeIndex, lastSlot);
    }

    /**
     * @dev 文档公式：
     *      reward = principal * (APY * elapsed * multiplier)
     *               / (FEE_DENOMINATOR * BLOCKS_PER_YEAR * MULTIPLIER_DENOMINATOR)
     */
    function _calculateReward(
        uint256 principal,
        uint256 apyBps,
        uint256 elapsedBlocks,
        uint256 multiplierNumerator
    ) internal pure returns (uint256) {
        if (principal == 0 || elapsedBlocks == 0) return 0;
        uint256 num = apyBps * elapsedBlocks * multiplierNumerator;
        uint256 denom = uint256(FEE_DENOMINATOR) * BLOCKS_PER_YEAR * MULTIPLIER_DENOMINATOR;
        return Math.mulDiv(principal, num, denom);
    }

    function _accrueReward(StakeInfo storage s) internal {
        if (s.isFullyClaimed || s.principal == 0) return;

        uint256 endTime = s.startTime + s.stakeLockDuration;
        uint256 nowB = _blockNow();
        uint256 currentTime = nowB > endTime ? endTime : nowB;
        if (currentTime <= s.lastAccrualTime) return;

        uint256 maxR = s.stakeMaxReward;
        if (s.accruedReward >= maxR) {
            s.lastAccrualTime = currentTime;
            return;
        }

        uint256 elapsed = currentTime - s.lastAccrualTime;
        uint256 addedReward = _calculateReward(s.principal, s.stakeAPY, elapsed, s.stakeMultiplier);

        uint256 room = maxR - s.accruedReward;
        if (addedReward > room) {
            addedReward = room;
        }

        s.accruedReward += addedReward;
        s.lastAccrualTime = currentTime;
    }

    function _projectedAccruedReward(StakeInfo memory s) internal view returns (uint256) {
        if (s.isFullyClaimed || s.principal == 0) return s.accruedReward;

        uint256 maxR = s.stakeMaxReward;
        if (s.accruedReward >= maxR) return maxR;

        uint256 endTime = s.startTime + s.stakeLockDuration;
        uint256 nowB = _blockNow();
        uint256 currentTime = nowB > endTime ? endTime : nowB;
        if (currentTime <= s.lastAccrualTime) return s.accruedReward;

        uint256 elapsed = currentTime - s.lastAccrualTime;
        uint256 addedReward = _calculateReward(s.principal, s.stakeAPY, elapsed, s.stakeMultiplier);

        uint256 room = maxR - s.accruedReward;
        if (addedReward > room) {
            addedReward = room;
        }
        return s.accruedReward + addedReward;
    }

    function transfer(address to, uint256 amount) public override nonReentrant whenNotPaused returns (bool) {
        if (to == address(0)) revert TransferToZeroAddress();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override nonReentrant whenNotPaused returns (bool) {
        if (to == address(0)) revert TransferToZeroAddress();
        return super.transferFrom(from, to, amount);
    }

    function emergencyTokenRescue(address token, address to, uint256 amount) external onlyTimelock nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (to == address(this)) revert InvalidRescueRecipient();
        if (amount == 0) revert InvalidAmount();

        uint256 held = IERC20(token).balanceOf(address(this));
        uint256 reserved;

        if (token == address(this)) {
            reserved = _reservedDctForStaking();
        } else {
            _validateForeignERC20(token);
            reserved = 0;
        }

        if (held <= reserved) revert ProtectedFundsCannotBeRescued();
        uint256 headroom = held - reserved;
        if (amount > headroom) revert ProtectedFundsCannotBeRescued();

        if (token == address(this)) {
            _transfer(address(this), to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit EmergencyTokenRescue(token, to, amount);
    }

    function getWithdrawableAmount(address user, uint256 idx) external view returns (uint256 principal, uint256 reward) {
        uint256 n = userStakes[user].length;
        if (idx >= n) revert InvalidStakeIndex();
        StakeInfo memory s = userStakes[user][idx];
        if (s.isFullyClaimed) return (0, 0);

        uint256 grossPrincipal = s.principal - s.claimedPrincipal;
        bool matured = _blockNow() >= s.startTime + s.stakeLockDuration;

        if (!matured) {
            uint256 penalty = grossPrincipal.mulDiv(EARLY_UNSTAKE_PENALTY_BPS, FEE_DENOMINATOR);
            principal = grossPrincipal - penalty;
            reward = 0;
            return (principal, reward);
        }

        uint256 finalReward = _projectedAccruedReward(s);
        principal = grossPrincipal;
        uint256 claimed = s.claimedReward;
        reward = finalReward > claimed ? finalReward - claimed : 0;
    }

    function getStakingPoolStatus() external view returns (uint256 poolBalance, uint256 minimumRequired, bool healthy) {
        uint256 liability = unsettledStakingLiability;
        poolBalance = balanceOf(address(this));
        minimumRequired = liability + liability.mulDiv(REWARD_POOL_BUFFER_BPS, FEE_DENOMINATOR);
        healthy = poolBalance >= minimumRequired;
    }

    function getUserStakeCount(address user) external view returns (uint256) {
        return userStakes[user].length;
    }

    function getLastUnstakeAt(address user) external view returns (uint256) {
        return _lastUnstakeAt[user];
    }

    function getLastRewardClaimAt(address user) external view returns (uint256) {
        return _lastRewardClaimAt[user];
    }
}
