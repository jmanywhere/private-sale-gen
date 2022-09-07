from brownie import (
    interface,
    TokenPresale,
    TestToken,
    accounts,
    chain,
    reverts,
)
from web3 import Web3 as web3
import pytest


@pytest.fixture()
def setup():
    dev = accounts[0]
    wlToken = TestToken.deploy(
        "Whitelist", "WHITELIST", web3.toWei(1_000_000, "ether"), {"from": dev}
    )
    testToken = TestToken.deploy(
        "Test", "TEST", web3.toWei(1_000_000, "ether"), {"from": dev}
    )

    zero = "0x0000000000000000000000000000000000000000"
    return testToken, wlToken, dev, zero


#  SCENARIOS TO TEST
#   a. Configs to test:
#       * MIN BUY < 0.0001 | MIN BUY > 0.01
#       * MAX BUY -> no max, max set
#       * SOFTCAP (this is informational only so it doesn't really matter)
#       * HARDCAP (no cap | Set CAP)
#       * Whitelist Amount (0 for non whitelist, 1000 eth)
#       * Whitelist Time (0 for non whitelist, 24 hours)
#       * Tokens to be sold ( 0 and 10_000 eth )
#       * Public Duration ( 0, 24 hours)
#       * start time (set time for 2 hour from now)
#   1. No token, no whitelist, collect in ETH
#   2. No token, whitelist, collect in ETH
#   3. No token, whitelist, collect in BUSD (or other)
#   4. Token, no whitelist, collect in BUSD (or other)


def test_start(setup):
    (testToken, wlToken, dev, zero) = setup

    presale = TokenPresale.deploy(
        zero,  # token
        accounts[1],  # owner
        zero,  # whitelistToken
        zero,  # token to collect, since zero address use ETH
        [
            web3.toWei(0.3, "ether"),  # MIN BUY
            web3.toWei(15, "ether"),  # MAX BUY
            web3.toWei(50, "ether"),  # softcap
            web3.toWei(200, "ether"),  # hardcap
            web3.toWei(1500, "ether"),  # wl tokens to hold
            12,  # whitelist duration
            0,  # tokens to be sold
            24,  # public duration
            chain.time() + (24 * 60),  # sale start time
        ],
        {"from": dev},
    )
    assert presale.owner() == accounts[1]
    # This fails because the amount is in ERC20 and not in ETH which is what we're requesting
    with reverts("Amount or Interval invalid"):
        presale.buyToken(web3.toWei(10, "ether"), {"from": accounts[2]})
    with reverts("dev: Not started yet"):
        presale.buyToken(0, {"from": accounts[2], "value": web3.toWei(10, "ether")})

    chain.mine(10, timedelta=25 * 60)
    with reverts("dev: Not in whitelist"):
        presale.buyToken(0, {"from": accounts[2], "value": web3.toWei(10, "ether")})
    # Finish whitelist period
    chain.mine(10, timedelta=13 * 60 * 60)
    # Test buy less than min
    with reverts("Amount or Interval invalid"):
        presale.buyToken(0, {"from": accounts[2], "value": web3.toWei(0.1, "ether")})
    presale.buyToken(0, {"from": accounts[2], "value": web3.toWei(10, "ether")})
    # Try to buy more than cap
    with reverts("User Cap reached"):
        presale.buyToken(0, {"from": accounts[2], "value": web3.toWei(10, "ether")})

    assert presale.userInfo(accounts[2])["whitelistBought"] == 0
    assert presale.userInfo(accounts[2])["bought"] == web3.toWei(10, "ether")

    #  Try to buy after public ends
    chain.mine(10, timedelta=24 * 60 * 60)
    with reverts("dev: Sale over"):
        presale.buyToken(0, {"from": accounts[2], "value": web3.toWei(10, "ether")})

    assert presale.balance() == web3.toWei(10, "ether")
    owner_bal = accounts[1].balance()
    presale.withdraw({"from": accounts[1]})
    assert accounts[1].balance() - owner_bal == web3.toWei(10, "ether")
