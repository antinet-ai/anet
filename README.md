# anet

anet is Antinet's engine: edge AI and ML infrastructure that runs language models, decision models and time-series models on machines a site owns, with nothing sent off the machine. It runs as a local service with OpenAI- and Anthropic-compatible APIs.

**These releases are previews.** They run on Linux (x86-64, arm64) with glibc 2.34 or later (RHEL 9, Debian 12, Ubuntu 22.04 and later) and macOS (Apple silicon). Windows, the vision tier and signed model bundles come later.

This repository holds the signed releases and the install script only.

## Install

```bash
curl -fsSLO https://github.com/antinet-ai/anet/releases/latest/download/install.sh && bash install.sh
```

The script downloads the release for this machine, checks its SHA-256, checks with [`gh`](https://cli.github.com) that Antinet's release workflow built it, and checks that the engine carries the release key the script pins. Then:

- **Linux:** it installs the engine as the system service (`sudo anet service install`), or updates the installed one (`sudo anet update`). The engine needs `libgomp.so.1` and `libvulkan.so.1` (Debian and Ubuntu: `libgomp1 libvulkan1`).
- **macOS:** it installs the engine for your account under `~/.local/share/anet` and links `~/.local/bin/anet`. Set up a site once with `anet setup`, then run `anet serve`.

A specific release: `bash install.sh --release <n>`.

## Check a release by hand

```bash
sha256sum -c anet-<n>-<platform>.tar.gz.sha256
gh attestation verify anet-<n>-<platform>.tar.gz --repo antinet-ai/antinet
```

Each release's notes give its source commit and its release key. Once installed, the engine accepts updates signed with that key only, never an older release, and `sudo anet update rollback` goes back one release.

## Install with no network

On a connected machine, download the archive, its `.sha256` and `.sigstore.json` files and `install.sh` from the release page, and save GitHub's trusted root:

```bash
gh attestation trusted-root > trusted-root.jsonl
```

Carry them in, then:

```bash
bash install.sh --archive anet-<n>-<platform>.tar.gz --bundle anet-<n>-<platform>.tar.gz.sigstore.json --trusted-root trusted-root.jsonl
```

## SDKs

| Language | Install | Import |
|---|---|---|
| Python | `pip install antinet` | `import anet` |
| Node | `npm install antinet` | `import { connect } from "antinet"` |
| .NET | `dotnet add package Antinet` | `using Anet;` |
| Rust | `cargo add anet-client` | `use anet_client;` |
| C and C++ | in each release: `anet_client.h`, `anet_client.hpp` and the library | |

SDK version `0.<n>.0` goes with release `<n>`.
