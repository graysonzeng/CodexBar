---
summary: "CLIProxyAPI provider setup and management-API quota source."
read_when:
  - Configuring CLIProxyAPI usage tracking
  - Debugging Codex/Gemini/Antigravity/Grok quota fetched through a local CLIProxyAPI
---

# CLIProxyAPI

CodexBar reads remaining quota from a running [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) instance.
It does not read the git checkout. The local management API (default `http://127.0.0.1:8317`) is the data source.

This is a port of [baicai-1145/CodexBar #335](https://github.com/steipete/CodexBar/pull/335) onto the current
descriptor architecture: one provider instead of three icons, with Codex, Gemini, Antigravity, and Grok accounts shown as
extra quota rows.

## Setup

Store the management key (CLIProxyAPI `remote-management.secret-key`):

```bash
printf '%s' "$CLIPROXYAPI_MANAGEMENT_KEY" | codexbar config set-api-key --provider cliproxyapi --stdin
```

Optional base URL via `CLIPROXYAPI_BASE_URL`, or `enterpriseHost` in the provider config:

```json
{
  "id": "cliproxyapi",
  "enabled": true,
  "apiKey": "<REDACTED>",
  "enterpriseHost": "http://127.0.0.1:8317",
  "workspaceID": ""
}
```

`workspaceID` maps to CLIProxyAPI `auth_index`. Leave it empty to scan every enabled Codex, Gemini, Antigravity, and
Grok credential (up to 12 per refresh). Grok is the CLIProxyAPI `xai` OAuth type.

The base URL must use HTTPS unless it names a loopback or private-network address, or a `.local` mDNS host,
and must not embed credentials. Plain HTTP remains available for self-hosted proxies on loopback, RFC 1918,
link-local, and IPv6 unique-local networks.

## Menu display

- Primary: highest used session/Pro window among fetched accounts.
- Secondary: highest used weekly/Flash window when present.
- Extra rows: one named window per account (`Codex`, `Antigravity`, `Grok`). Account emails stay off the menu.

## Spend tracking

- Off by default. Enable **Track CLIProxyAPI spend** in Providers, or set `CLIPROXYAPI_SPEND_TRACKING=1`.
- CLIProxyAPI `usage-statistics-enabled` also defaults to **false**. Set it `true` in the proxy config or the queue never fills.
- CodexBar pops `GET /v0/management/usage-queue?count=200` every 5s while the provider is enabled. GET is destructive; there is no ack. Do not also run CPA-Manager as a consumer of the same queue.
- Events persist under `Application Support/CodexBar/cliproxyapi-spend/cliproxyapi-spend.sqlite`. Usage & Spend shows an observed-cost row that is **not** added to billed Codex/Claude totals.
- `api_key` from queue records is discarded after decode.

GitHub Copilot and other CLIProxyAPI auth types are listed by the management API but are not probed.

## Notes

CLIProxyAPI itself does not store 5-hour/weekly remaining percent. CodexBar asks it to call upstream usage APIs with
the stored credential (`POST /v0/management/api-call`). The management key is required even on localhost.
Spend history is a local list-price estimate of requests the proxy observed, not a vendor bill.
