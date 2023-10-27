# @version 0.3.7
"""
WARNING:
At the moment this contract is unfinished, so not recommended to be used
without understanding.
"""
from vyper.interfaces import ERC20

interface Factory:
    def get_amm(collateral: address, i: uint256) -> address: view

interface LLAMMA:
    def coins(i: uint256) -> address: view

interface VotingEscrowBoost:
    def adjusted_balance_of(_account: address) -> uint256: view

interface CRV20:
    def future_epoch_time_write() -> uint256: nonpayable
    def rate() -> uint256: view

interface GaugeController:
    def period() -> int128: view
    def period_write() -> int128: nonpayable
    def period_timestamp(p: int128) -> uint256: view
    def gauge_relative_weight(addr: address, time: uint256) -> uint256: view
    def voting_escrow() -> address: view
    def checkpoint(): nonpayable
    def checkpoint_gauge(addr: address): nonpayable

interface Minter:
    def token() -> address: view
    def controller() -> address: view
    def minted(user: address, gauge: address) -> uint256: view


event UpdateLiquidityLimit:
    user: address
    original_balance: uint256
    original_supply: uint256
    working_balance: uint256
    working_supply: uint256


MAX_TICKS_UINT: constant(uint256) = 50
MAX_TICKS_INT: constant(int256) = 50
TOKENLESS_PRODUCTION: constant(uint256) = 40
WEEK: constant(uint256) = 604800

amm: public(address)

FACTORY: immutable(Factory)
COLLATERAL_TOKEN: public(immutable(ERC20))
COLLATERAL_INDEX: public(immutable(uint256))
VECRV: public(immutable(ERC20))
CRV: public(immutable(CRV20))
VEBOOST_PROXY: public(immutable(VotingEscrowBoost))
GAUGE_CONTROLLER: public(immutable(GaugeController))
MINTER: public(immutable(Minter))

user_collateral: public(HashMap[address, uint256])
total_collateral: public(uint256)
working_supply: public(uint256)
working_balances: public(HashMap[address, uint256])

collateral_per_share: public(HashMap[int256, uint256])
working_shares_per_band: public(HashMap[int256, uint256])  # This only counts staked shares

working_shares: public(HashMap[address, HashMap[int256, uint256]])
user_band: public(HashMap[address,int256])
user_range_size: public(HashMap[address,int256])

# Tracking of mining period
inflation_rate: public(uint256)
future_epoch_time: public(uint256)

# Running integrals
# ------------------
# Definitions:
#
# r - reward rate
# w - gauge relative weight
# s[i] - shares per band i
# cs[i] - collateral per share in band i
# s[u,i] - shares per user in band
#
# Reward rate per collateral:
# rrpc = (r * w) / sum(s[i] * cs[i])
#
# Rewards per collateral (integral):
# I_rpc = integral(rrpc * dt)
# t_rpc - time of the last I_rpc value

struct IntegralRPC:
    rpc: uint256
    t: uint256

I_rpc: public(IntegralRPC)

# Rewards per share:
# I_rps[i] = integral(cs[i] * rrpc * dt) = sum(cs[i] * delta(I_rpc))

struct IntegralRPS:
    rps: uint256
    rpc: uint256

I_rps: public(HashMap[int256, IntegralRPS])

# Rewards per user:
# I_rpu[u,i] = sum(s[u,i] * delta(I_rps[i]))
# I_rpu[u] = sum_i(I_rpu[u,i])

struct IntegralRPU:
    rpu: uint256
    rps: uint256

I_rpu: public(HashMap[address, HashMap[int256, IntegralRPU]])
integrate_fraction: public(HashMap[address, uint256])


@external
def __init__(factory: Factory, collateral: ERC20, c_index: uint256,
             crv: CRV20, vecrv: ERC20, veboost_proxy: VotingEscrowBoost, gc: GaugeController, minter: Minter):
    # Init is done by deployer but the contract starts operating after creation of the market
    # The actual initialization is done by the vote which creates the market just before
    FACTORY = factory
    COLLATERAL_TOKEN = collateral
    COLLATERAL_INDEX = c_index
    VECRV = vecrv
    VEBOOST_PROXY = veboost_proxy
    CRV = crv
    GAUGE_CONTROLLER = gc
    MINTER = minter


@external
def initialize():
    amm: address = FACTORY.get_amm(COLLATERAL_TOKEN.address, COLLATERAL_INDEX)
    self.amm = amm
    assert COLLATERAL_TOKEN == ERC20(LLAMMA(amm).coins(1))
    self.inflation_rate = CRV.rate()
    self.future_epoch_time = CRV.future_epoch_time_write()


@internal
def _update_liquidity_limit(user: address, collateral_amount: uint256) -> uint256:
    # To be called after totalSupply is updated
    voting_balance: uint256 = VEBOOST_PROXY.adjusted_balance_of(user)
    voting_total: uint256 = VECRV.totalSupply()

    # collateral_amount and total are used to calculate boosts
    old_amount: uint256 = self.user_collateral[user]
    self.user_collateral[user] = collateral_amount
    L: uint256 = self.total_collateral + collateral_amount - old_amount
    self.total_collateral = L

    lim: uint256 = collateral_amount * TOKENLESS_PRODUCTION / 100
    if voting_total > 0:
        lim += L * voting_balance / voting_total * (100 - TOKENLESS_PRODUCTION) / 100
    lim = min(collateral_amount, lim)

    old_bal: uint256 = self.working_balances[user]
    self.working_balances[user] = lim
    _working_supply: uint256 = self.working_supply + lim - old_bal
    self.working_supply = _working_supply

    log UpdateLiquidityLimit(user, collateral_amount, L, lim, _working_supply)

    return lim


@internal
def _checkpoint_collateral_shares(n: int256, collateral_per_share: DynArray[uint256, MAX_TICKS_UINT], size: int256):
    # Read current and new rate; update the new rate if needed
    I_rpc: IntegralRPC = self.I_rpc
    rate: uint256 = self.inflation_rate
    new_rate: uint256 = rate
    prev_future_epoch: uint256 = self.future_epoch_time
    if prev_future_epoch >= I_rpc.t:
        self.future_epoch_time = CRV.future_epoch_time_write()
        new_rate = CRV.rate()
        self.inflation_rate = new_rate

    # * Record the collateral per share values
    # * Record integrals of rewards per share
    working_supply: uint256 = self.working_supply
    delta_rpc: uint256 = 0

    if working_supply > 0 and block.timestamp > I_rpc.t:  # XXX should we not loop when boosted collateral == 0?
        GAUGE_CONTROLLER.checkpoint_gauge(self)
        prev_week_time: uint256 = I_rpc.t
        week_time: uint256 = min((I_rpc.t + WEEK) / WEEK * WEEK, block.timestamp)

        for week_iter in range(500):
            dt: uint256 = week_time - prev_week_time
            w: uint256 = GAUGE_CONTROLLER.gauge_relative_weight(self, prev_week_time / WEEK * WEEK)

            if prev_future_epoch >= prev_week_time and prev_future_epoch < week_time:
                # If we went across one or multiple epochs, apply the rate
                # of the first epoch until it ends, and then the rate of
                # the last epoch.
                # If more than one epoch is crossed - the gauge gets less,
                # but that'd mean it wasn't called for more than 1 year
                delta_rpc += rate * w * (prev_future_epoch - prev_week_time) / working_supply
                rate = new_rate
                delta_rpc += rate * w * (week_time - prev_future_epoch) / working_supply
            else:
                delta_rpc += rate * w * dt / working_supply
            # On precisions of the calculation
            # rate ~= 10e18
            # last_weight > 0.01 * 1e18 = 1e16 (if pool weight is 1%)
            # _working_supply ~= TVL * 1e18 ~= 1e26 ($100M for example)
            # The largest loss is at dt = 1
            # Loss is 1e-9 - acceptable

            if week_time == block.timestamp:
                break
            prev_week_time = week_time
            week_time = min(week_time + WEEK, block.timestamp)

        I_rpc.t = block.timestamp
        I_rpc.rpc += delta_rpc
        self.I_rpc = I_rpc

    # Update working_supply
    for i in range(MAX_TICKS_INT):
        if i == size:
            break
        _n: int256 = n + i
        old_cps: uint256 = self.collateral_per_share[_n]
        cps: uint256 = old_cps
        if len(collateral_per_share) == 0:
            cps = old_cps
        else:
            cps = collateral_per_share[i]
            self.collateral_per_share[_n] = cps
        I_rps: IntegralRPS = self.I_rps[_n]
        I_rps.rps += old_cps * (I_rpc.rpc - I_rps.rpc) / 10**18
        I_rps.rpc = I_rpc.rpc
        self.I_rps[_n] = I_rps
        if cps != old_cps:
            wspb: uint256 = self.working_shares_per_band[_n]
            if wspb > 0:
                # working_supply += wspb * (cps - old_cps) / 10**18
                old_value: uint256 = wspb * old_cps / 10**18
                working_supply = max(working_supply + wspb * cps / 10**18, old_value) - old_value

    self.working_supply = working_supply


@internal
def _checkpoint_user_shares(user: address, n: int256, user_shares: DynArray[uint256, MAX_TICKS_UINT], size: int256):
    # Calculate the amount of real collateral for the user
    collateral_amount: uint256 = 0
    if len(user_shares) == 0:
        collateral_amount = self.user_collateral[user]
    else:
        for i in range(MAX_TICKS_INT):
            if i == n_shares:
                break
            collateral_amount += user_shares[i] * self.collateral_per_share[n + i] / 10**18

    # Get working balance
    working_balance: uint256 = self._update_liquidity_limit(user, collateral_amount)
    rpu: uint256 = self.integrate_fraction[user]

    for j in range(MAX_TICKS_INT):
        if j == size:
            break
        i: int256 = n + j
        old_ws: uint256 = self.working_shares[user][i]
        # Transition from working_balance to working_shares:
        # 1. working_balance * real_shares == real_balance * working_shares
        # 2. collateral_per_share * working_shares = working_balance
        #
        # It's needed to update working supply during soft-liquidation
        if len(user_shares) > 0:
            ws: uint256 = user_shares[j] * working_balance / collateral_amount
            self.working_shares[user][i] = ws
            self.working_shares_per_band[i] = self.working_shares_per_band[i] + ws - old_ws

        I_rpu: IntegralRPU = self.I_rpu[user][i]
        I_rps: uint256 = self.I_rps[i].rps
        d_rpu: uint256 = old_ws * (I_rps - I_rpu.rps) / 10**18
        I_rpu.rpu += d_rpu
        rpu += d_rpu
        I_rpu.rps = I_rps
        self.I_rpu[user][i] = I_rpu

    self.integrate_fraction[user] = rpu


@external
def callback_collateral_shares(n: int256, collateral_per_share: DynArray[uint256, MAX_TICKS_UINT]):
    # It is important that this callback is called every time before callback_user_shares
    assert msg.sender == self.amm
    size: int256 = convert(len(collateral_per_share), int256)
    self._checkpoint_collateral_shares(n, collateral_per_share, size)


@external
def callback_user_shares(user: address, n: int256, user_shares: DynArray[uint256, MAX_TICKS_UINT]):
    assert msg.sender == self.amm
    self.user_band[user] = n
    size: int256 = convert(len(user_shares), int256)
    self.user_range_size[user] = size
    self._checkpoint_user_shares(user, n, user_shares, size)


@external
def user_checkpoint(addr: address) -> bool:
    """
    @notice Record a checkpoint for `addr`
    @param addr User address
    @return bool success
    """
    assert self.amm != empty(address)  # dev: not initialized
    assert msg.sender in [addr, MINTER.address]  # dev: unauthorized
    n: int256 = self.user_band[addr]
    size: int256 = self.user_range_size[addr]
    self._checkpoint_collateral_shares(n, [], size)
    self._checkpoint_user_shares(addr, n, [], size)
    return True


@external
def claimable_tokens(addr: address) -> uint256:
    """
    @notice Get the number of claimable tokens per user
    @dev This function should be manually changed to "view" in the ABI
    @return uint256 number of claimable tokens per user
    """
    assert self.amm != empty(address)  # dev: not initialized
    n: int256 = self.user_band[addr]
    size: int256 = self.user_range_size[addr]
    self._checkpoint_collateral_shares(n, [], size)
    self._checkpoint_user_shares(addr, n, [], size)
    return self.integrate_fraction[addr] - MINTER.minted(addr, self)
