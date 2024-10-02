from brownie.exceptions import VirtualMachineError
from brownie import Sigma, accounts, Contract, project, config
from pathlib import Path

# Execution Command Format:
# `brownie run scripts/mode-mainnet/upgrade-Sigma.py --network=mode-main -I`

# NOTE: This script has been tested on the forked network.

def main(deployer="mainnet-deployer", proxy_admin_owner="mainnet-owner"):
    deps = project.load(Path.home() / ".brownie" / "packages" / config["dependencies"][0])
    TransparentUpgradeableProxy = deps.TransparentUpgradeableProxy
    ProxyAdmin = deps.ProxyAdmin

    # The following two lines of code for forked network testing
#     deployer = accounts.at(accounts[0], True)
#     proxy_admin_owner = accounts.at("0x9251fd3D79522bB2243a58FFf1dB43E25A495aaB", True)

    deployer = accounts.load(deployer)
    proxy_admin_owner = accounts.load(proxy_admin_owner)

    sigma_default_admin = "0x9251fd3D79522bB2243a58FFf1dB43E25A495aaB"

    # ========== Pre-Upgrade Check ==========
    proxy_admin = ProxyAdmin.at("0xb3f925B430C60bA467F7729975D5151c8DE26698")
    sigma_proxy = TransparentUpgradeableProxy.at("0x8Cc6D6135C7088fdb3eBFB39B11e7CB2F9853915")
    sigma_transparent = Contract.from_abi("Sigma", sigma_proxy.address, Sigma.abi)

    assert proxy_admin.owner() == proxy_admin_owner.address
    assert proxy_admin.getProxyAdmin(sigma_proxy) == proxy_admin.address
    assert sigma_transparent.hasRole(sigma_transparent.DEFAULT_ADMIN_ROLE(), sigma_default_admin)
    print("✅ [1/4] Pre-upgrade check done.")

    # ========== Upgrade Sigma ==========
    sigma_impl = Sigma.deploy({'from': deployer})
    print("✅ [2/4] Sigma implementation deployed: ", sigma_impl)

    proxy_admin.upgrade(sigma_proxy.address, sigma_impl, {'from': proxy_admin_owner})
    assert proxy_admin.getProxyImplementation(sigma_proxy) == sigma_impl
    print("✅ [3/4] Sigma proxy upgraded.")

    # ========== Post-Upgrade Check ==========
    # Scenario 1 [revert]: 'totalSupply' should revert if the given leading token not registered yet
    # USR018: NO_POOLS_FOR_LEADING_TOKEN
    fake_unregistered_leading_token = "0x9251fd3D79522bB2243a58FFf1dB43E25A495aaB"
    try:
        sigma_transparent.totalSupply(fake_unregistered_leading_token)
    except VirtualMachineError as e:
        if "USR018" in str(e):
            print("'totalSupply' reverted as expected with 'USR018' error")
        else:
            print(f"❌ 'totalSupply' reverted with an unexpected error: {str(e)}")
    else:
        print("'❌ totalSupply' did not revert as expected")

    # Scenario 2 [success]: 'totalSupply' should return normally for already registered leading tokens
    leading_tokens = [
        "0xcDd475325D6F564d27247D1DddBb0DAc6fA0a5CF",    # WBTC
        "0x59889b7021243dB5B1e065385F918316cD90D46c"     # M-BTC
    ]
    for leading_token in leading_tokens:
        assert len(sigma_transparent.getTokenHolders(leading_token)) > 0
        assert sigma_transparent.totalSupply(leading_token) >= 0

    print("✅ [4/4] Post-upgrade check done.")



