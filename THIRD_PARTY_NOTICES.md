# Third-Party Notices

MauQuota does not bundle Codex CLI, Codex App Server, Node.js, Electron, or other third-party runtime binaries.

The native OAuth implementation currently reuses the public OAuth client identifier and authorization-code/PKCE flow used by Codex CLI. The client identifier is not a client secret. This reuse is an implementation detail, not an endorsement or a guarantee that OpenAI will maintain compatibility for third-party applications.

MauQuota directly calls ChatGPT web-backend endpoints for Codex usage and reset-credit operations. These endpoints are not documented as a stable public API and may change or become unavailable without notice.

MauQuota is an independent third-party project and is not affiliated with, endorsed by, or sponsored by OpenAI.
