from eth_account import Account

# Anvil's well-known, public, local-devnet-only default account #0. Never
# used on any real network — this key is published in every Foundry/Hardhat
# tutorial and only has funds on throwaway local devnets anvil itself creates.
ANVIL_DEFAULT_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_DEFAULT_ADDRESS = Account.from_key(ANVIL_DEFAULT_PRIVATE_KEY).address
