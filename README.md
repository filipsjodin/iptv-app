# iptv-app

IPTV client for tvOS and iOS 27. Swift 6 with the shared `IPTVKit` package.

## Local setup

- Windows: `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`
- Install the secret-scanning hook: `bash scripts/install-hooks.sh` (needs `gitleaks`, `winget install gitleaks`)

## Security

This repository is public. Never commit playlist URLs, credentials, or real playlist/EPG files.
Fixtures must use `REDACTED` for usernames and passwords. Private data lives outside the repo.
