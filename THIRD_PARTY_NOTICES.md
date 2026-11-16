# Third-party notices

## OpenAI Codex App Server

- Component: official standalone Codex App Server native runtime bundled with MauQuota
- Upstream binary: `codex-app-server`
- Bundled version: `0.169.0`
- Upstream: https://github.com/openai/codex
- License: Apache License 2.0
- License text: included in the application bundle at `Contents/Resources/Codex-LICENSE.txt`
- The official release archive is verified against its published SHA-256 checksum during CI.

MauQuota invokes the bundled App Server only for account, rate-limit, and ChatGPT browser-login RPCs. MauQuota is an independent third-party project and is not affiliated with or endorsed by OpenAI.
