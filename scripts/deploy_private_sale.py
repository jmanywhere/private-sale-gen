from brownie import TokenPresale, accounts, interface, chain

from web3 import Web3 as web3


def main():
    dev = accounts.load("stk_dep" if chain.id == 56 else "dev_deploy")
    zero = "0x0000000000000000000000000000000000000000"
    flame = interface.IERC20(
        "0x20D5BA6D5aa2A3dF3A632B493621D760E4c7965E"
        if chain.id == 56
        else "0x7606046228DC445495709fF7DA470a36BB2Bd0ee"
    )
    presale = TokenPresale.deploy(
        zero,
        "0x7F94465c4f87a84B2Fb52eb16c435cb37296f5bc",
        flame,
        zero,
        [
            web3.toWei(0.3, "ether"),
            web3.toWei(5, "ether"),  # MAX BUY
            0,
            web3.toWei(200, "ether"),  # hardcap
            web3.toWei(1500, "ether"),  # wl tokens to hold
            0,
            0,
            12,
            1662645600,
        ],
        True,
        {"from": dev},
        publish_source=True,
    )
