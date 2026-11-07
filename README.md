# Autopilot Failure Dashboard

**Repository:** https://github.com/foudendorp/autopilot-failure-dashboard

A local, read-only web app for analysing failed Windows Autopilot deployments in Microsoft Intune.
It signs in to your tenant with your own (delegated) account, retrieves Autopilot deployment data
from Microsoft Graph, optionally parses diagnostics (`.cab` / `.zip`), and shows for each failed
deployment the **phase**, the **evidence**, the **likely or possible cause**, a **recommended fix** and a
**structural action**. A presentation mode is included for workshops.

- Runs on `http://127.0.0.1:<port>` only. Never bound to the network.
- Read-only: the Graph client only sends `GET` (one documented exception, see below).
- Tokens and tenant data are kept in memory only. Nothing is written to disk unless you export.
- Works without a tenant in **Demo mode** (fictional Contoso data).

## Two ways to use this repository

| You want to… | Start here |
| --- | --- |
| **Run the dashboard** | [Get the code](#get-the-code), then [Quick start](#quick-start) with `-Demo`. |
| **Build it yourself** (students, workshops) | [docs/Studentenopdracht.md](docs/Studentenopdracht.md) (Dutch). It has the full English prompt to rebuild this dashboard with an AI coding assistant, the pitfalls found during the first build and a checklist for handing it in. Use this repository as the reference solution. |

---

## Get the code

```powershell
git clone https://github.com/foudendorp/autopilot-failure-dashboard.git
cd autopilot-failure-dashboard
```

If you downloaded the ZIP from GitHub instead, unblock the scripts once so PowerShell will run them:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

---

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Windows 10 1803+ / Windows 11 | Diagnostics parsing uses the built-in `tar.exe` (cab/zip) and `Get-WinEvent` (evtx). |
| PowerShell 7.6 (7.4+ works) | `winget install Microsoft.PowerShell` |
| [Pode](https://github.com/Badgerati/Pode) 2.10+ | `Install-PSResource -Name Pode -Scope CurrentUser`, or start with `-InstallDependencies`. Tested with 2.14.2. |
| Pester 5.5+ (tests only) | `Install-PSResource -Name Pester -Scope CurrentUser`. Windows ships Pester 3.4, which is too old. |
| Node.js 18+ (tests only) | Runs the front-end filter tests with `node --test`. Without Node those tests are skipped. |
| A modern browser | Edge or Chrome. No CDN or internet resources are loaded by the UI. |

### Why Pode

Pode was kept as the web server: it is a mature, pure-PowerShell module, binds to a specific address
(`127.0.0.1`), has a runspace pool so the UI stays responsive while Graph data is retrieved, and has
middleware and multipart upload handling built in. The alternative, a hand-written
`System.Net.HttpListener` loop, would remove one dependency but means reimplementing routing,
multipart parsing and concurrency. That isn't a clear improvement, so it wasn't chosen.

The app deliberately does **not** use Pode's automatic `/public` static folder or Pode sessions.
Assets are served from a fixed whitelist, so the app's security middleware applies to every request.

---

## Quick start

```powershell
# Demo mode, no tenant needed
./Start-AutopilotDashboard.ps1 -Demo

# Normal start (after the sign-in setup below)
./Start-AutopilotDashboard.ps1
```

The browser opens at `http://127.0.0.1:8765/`. Stop the server with **Ctrl+C**.

| Parameter | Purpose |
| --- | --- |
| `-Demo` | Load fictional demo data at startup (you can also use the **Demo mode** button). |
| `-Port 9000` | Override the port in `config\settings.json`. **The redirect URI in your app registration must use the same port.** |
| `-NoBrowser` | Don't open the browser. |
| `-InstallDependencies` | Install Pode for the current user if it is missing. |

On first start, `config\settings.json` is created from `config\settings.example.json`.

---

## Sign-in setup

The app uses the **OAuth 2.0 authorization code flow with PKCE** as a **public client**. There is no
client secret and no certificate. Choose one of two sign-in apps with `authMode` in
`config\settings.json`.

### Option A: Microsoft Graph Command Line Tools (no app registration)

```json
{ "authMode": "graphCli", "tenantId": "<optional: tenant GUID or contoso.onmicrosoft.com>" }
```

This signs in with Microsoft's first-party public client used by Microsoft Graph PowerShell
(`Connect-MgGraph`, client ID `14d82eec-204b-4c2f-b7e8-296a70dab67e`). Any `clientId` in the file is
ignored. Without `tenantId` the `organizations` endpoint is used and the tenant is taken from your
account.

- **Redirect URI:** that app accepts `http://localhost` (port ignored), so the redirect URI is
  `http://localhost:<port>`. The server still listens on `127.0.0.1` only. It accepts the
  `localhost` host name **only** for the sign-in callback (`GET /` with `state`/`error`), then
  redirects you to `http://127.0.0.1:<port>/`. Every other request on `localhost` is rejected.
- **Consent:** the permissions below need admin consent. Consenting here consents them for the
  Graph Command Line Tools app, so they then also apply to anyone using `Connect-MgGraph` in your
  tenant. If your admins have already consented these permissions for Graph PowerShell, sign-in just
  works. Otherwise an admin can consent in the sign-in prompt.
- **Policy:** Conditional Access or "assignment required" on *Microsoft Graph Command Line Tools*
  applies here too, and sign-in logs show that app name instead of the dashboard.
- Microsoft recommends your own app registration for custom tools, so Option B stays the default.

### Option B: your own app registration (default, `"authMode": "custom"`)

1. **Entra admin center** > **Identity** > **Applications** > **App registrations** > **New registration**
   - Name: `Autopilot Dashboard (local)`
   - Supported account types: **Accounts in this organizational directory only**
   - Redirect URI: leave empty for now. Select **Register**.
2. **Redirect URI**: the app uses `http://127.0.0.1:8765/auth/callback`. Microsoft recommends
   `127.0.0.1` over `localhost` for loopback redirects, but the portal's Redirect URI box doesn't accept
   `http://127.0.0.1`. Add it in the **Manifest** instead (Microsoft Graph app manifest format):
   ```json
   "publicClient": {
       "redirectUris": [ "http://127.0.0.1:8765/auth/callback" ]
   },
   ```
   Or use Microsoft Graph PowerShell:
   ```powershell
   Connect-MgGraph -Scopes 'Application.ReadWrite.All'
   Update-MgApplication -ApplicationId <object-id> -PublicClient @{ RedirectUris = @('http://127.0.0.1:8765/auth/callback') }
   ```
   It must be a **public client / Mobile and desktop** redirect URI, not *Web* or *SPA* (see
   Troubleshooting). If you change `port`, register the matching URI.
3. **API permissions** > **Add a permission** > **Microsoft Graph** > **Delegated permissions**. Add the
   permissions below, then select **Grant admin consent for <tenant>**.
4. Copy the **Directory (tenant) ID** and **Application (client) ID** into `config\settings.json`:
   ```json
   { "tenantId": "<tenant GUID>", "clientId": "<application GUID>" }
   ```
5. Optional hardening: on the enterprise application set **Assignment required = Yes** and assign only
   the people who should use the dashboard.

### Permissions (delegated, least privilege, read-only)

| Permission | Used for |
| --- | --- |
| `DeviceManagementManagedDevices.Read.All` | `autopilotEvents`, listing `logCollectionRequests`, and `policyStatusDetails` when opted in |
| `DeviceManagementServiceConfig.Read.All` | `windowsAutopilotDeviceIdentities` and their deployment / intended deployment profiles |
| `DeviceManagementConfiguration.Read.All` *(optional)* | Least-privileged permission documented for `createDownloadUrl` (diagnostics download), and listing device preparation policies. Turn off with `"requestConfigurationReadScope": false`. |
| `openid`, `profile`, `offline_access` | Sign-in, showing account and tenant, and in-memory token refresh |

All are delegated, so the signed-in user's **Intune RBAC role** also applies. A read-only Intune role
is enough for deployment data. Listing and downloading diagnostics additionally requires an Intune
role with **Remote tasks / Collect diagnostics** plus managed device read (for example Help Desk
Operator).

---

## Read-only enforcement

All Graph calls go through `Invoke-AdGraphRequest` (`src/Private/10-GraphClient.ps1`), which checks
every request **before** it is sent:

- Host must be `https://graph.microsoft.com` (default port, no user info). This also applies to
  `@odata.nextLink`, so the token can never be sent to another host.
- Method must be `GET`.
- **One documented exception (POST):**
  `POST /beta/deviceManagement/managedDevices/{guid}/logCollectionRequests/{id}/createDownloadUrl`
  ([docs](https://learn.microsoft.com/en-us/graph/api/intune-devices-devicelogcollectionresponse-createdownloadurl?view=graph-rest-beta)).
  It returns a short-lived download URL for a diagnostics collection that **already exists** and
  changes nothing in the tenant. The path is matched with a strict regex (GUID device ID, no query, no
  encoded or relative segments). Disable it with `"allowDiagnosticsDownloadPost": false`.
- The app never calls `createDeviceLogCollectionRequest`. It never starts a collection on a device.

Other outbound requests (not Graph, and no Graph token involved):

- `login.microsoftonline.com/<tenant>/oauth2/v2.0/token`: sign-in and token refresh (POST, required by OAuth).
- `*.blob.core.windows.net`: downloading a diagnostics archive from the pre-signed URL returned by
  `createDownloadUrl` (GET, https only, no Authorization header, redirects disabled, size-capped).

---

## Data retrieved

| Data | Endpoint | Notes |
| --- | --- | --- |
| Deployments | `GET /beta/deviceManagement/autopilotEvents` (all pages, **no `$filter`**) | The date range is applied locally. A row is kept when **any** of its dates (deployment start, enrollment start, event, end) is in range. Rows without any date are kept and shown as Not available. A server-side `eventDateTime` filter is deliberately not used: it drops deployments whose `eventDateTime` is empty or differs from the deployment date, while the Intune portal still shows them. |
| Apps/policies per deployment | `GET /beta/deviceManagement/autopilotEvents/{id}/policyStatusDetails` | **Not requested by default.** Microsoft removed it: the current Graph beta schema of `deviceManagementAutopilotEvent` documents no relationships, and tenants answer 400 *Resource not found for the segment 'policyStatusDetails'*. Failing apps come from uploaded diagnostics instead (ESP-tracked Win32 apps with `InstallationState = 4`). With `"tryPolicyStatusDetails": true` the app tries it anyway and stops at the first "segment not found" answer, or after 3 consecutive 400s. |
| Autopilot devices | `GET /beta/deviceManagement/windowsAutopilotDeviceIdentities` | Model, manufacturer, group tag. |
| Profiles per device | `GET .../windowsAutopilotDeviceIdentities/{id}?$expand=deploymentProfile,intendedDeploymentProfile` | Devices that appear in the date range (capped by `maxProfileLookups`). Profile drift is flagged. |
| Device preparation policies | `GET /beta/deviceManagement/configurationPolicies` (filtered locally) | Best-effort identification. |

All endpoints are **beta** and labelled as such in the UI (**Data sources & rules** tab). Paging follows
`@odata.nextLink`. 429/5xx responses are retried with `Retry-After` or exponential backoff
(`graphMaxRetries`). The date range defaults to the last 30 days (`defaultDays`, max `maxDays`). The
time of the last refresh is shown in the header.

**Autopilot device preparation deployments are shown as "Not available".** Microsoft exposes their
status (report `AutopilotV2DeploymentStatus`) only through `POST /beta/deviceManagement/reports/exportJobs`,
which is outside the read-only policy. Use the Intune admin center for those deployments.

---

## Diagnostics and logs

Microsoft's [Collect diagnostics](https://learn.microsoft.com/en-us/intune/device-management/actions/collect-diagnostics)
article states that *diagnostics can't be collected or downloaded by calling Microsoft Graph
directly*, while Graph separately documents `createDownloadUrl`. The app therefore tests instead of
assuming:

1. **Diagnostics & logs** > **Run capability test** lists `logCollectionRequests` for a device from a
   failed deployment (GET). If a completed collection exists, it requests a download URL (the POST
   exception).
2. If that works, the deployment detail view lists collections with **Download** (after a sensitivity
   warning) and **Analyze** (parsed in a temp folder, then deleted).
3. If Graph returns 403, an error, or "unsupported", the app explains why and offers **manual upload**.
   In the Intune admin center, open the device and use Monitor > Device diagnostics, or Diagnostics >
   Download after an Autopilot failure. Then upload the `.zip` here.

**Manual upload** accepts:

- `.cab` from `mdmdiagnosticstool.exe -area Autopilot;TPM -cab C:\temp\ap.cab` (or `-area Autopilot`, `-area DeviceProvisioning`)
- `.zip` from Intune Collect diagnostics (nested `mdmlogs-*.cab` files are extracted too, up to depth 3)

**What is parsed**

- `MDMDiagReport_RegistryDump.Reg`:
  - `HKLM\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot`: `TenantMatched`, `IsAutopilotDisabled`, `CloudAssignedTenantDomain`/`Id`, `AadTenantId`
  - ESP tracking under `...\Windows\Autopilot\EnrollmentStatusTracking`: `InstallationState` per Win32 app (1 NotInstalled, 2 InProgress, 3 Completed, 4 Error) and the Sidecar device preparation state
  - Serial number and `EntDMID` (Intune device ID) for matching
- Autopilot event log (`*Autopilot*.evtx`, ModernDeployment-Diagnostics-Provider): event IDs, levels, messages
- Text logs (`*.log`, `*.txt`, e.g. `IntuneManagementExtension.log`): lines matching rule text patterns or rule error codes

Logs are matched to a deployment by **serial number** or **Intune device ID**. Unmatched archives are
still analysed on their own.

**Safety:** files are checked for type (magic bytes) and size (`maxUploadMB`). Extraction guards
against zip-slip (absolute paths, `..`, invalid characters), zip bombs (`maxExtractedMB`, entry count
`maxArchiveEntries`, actual vs declared size) and reparse points. Everything is extracted to
`%TEMP%\AutopilotDashboard\<random>` and deleted in a `finally` block. Only the parsed summary stays
in memory, at most 25 analyses.

**Optional:** with `"useCommunityDiagnosticsScript": true` and the community script installed
(`Install-Script Get-AutopilotDiagnosticsCommunity`), its output for uploaded `.cab` files is shown as
a supplement. The app never requires it.

---

## Analysis rules (`rules.json`)

Rules are data and can be changed without code changes. They are validated at startup and reloaded on
every refresh, demo load or upload. If the file is invalid, the last valid rules stay in use and a
warning is shown. Each rule has:

| Field | Meaning |
| --- | --- |
| `id`, `phase` | Unique ID. Phase is one of the phases in `src/Private/30-Analysis.ps1`. |
| `signal` | `eventId` (values), `errorCode` (values, any notation), `registryValue` (name, equals), `text` (regex pattern), `espInstallationState` (equals), `policyStatus` (equals) |
| `context` *(optional)* | `flowTags` (`userDriven`, `selfDeploying`, `preProvisioned`, `entra`, `hybrid`) and/or `phases`. A known, mismatching context excludes the rule. A matching context ranks it higher. |
| `likelyCause`, `recommendedFix`, `structuralAction` | Shown in the detail view. Structural actions are ranked on the **Structural improvements** tab. |
| `confidence` | `high`, `medium` or `low` |
| `sourceUrl` | Must be a `https://learn.microsoft.com/` page |
| `verification` | Date and note of the documentation check |
| `generic` *(optional)* | Catch-all rule, ranked below specific explanations |

**How findings are presented:** nothing is presented as certain. A finding is labelled **Likely
cause** or **Possible cause** (possible when confidence is low or the signal is ambiguous), always
with its evidence and source. When the same evidence matches several rules (for example
`0x800705B4`, `0x80070774`, `0x80180014`, `0x87D1041C`, `IsAutopilotDisabled = 1`), all candidates
are shown and marked **Ambiguous signal**.

All rules were checked against Microsoft Learn on 2026-11-02 (Autopilot troubleshooting FAQ,
Windows enrollment errors, ESP troubleshooting, Entra join troubleshooting, app install error codes,
Win32 system error codes). Where a rule goes beyond the literal documentation (for example mapping
`0x800705B4` to an ESP timeout, or `0x80070652` to the documented LOB/Win32 conflict), the
`verification.note` says so and confidence is lowered.

---

## Dashboard

- **Overview:** total deployments, success rate (`success / (success + failed)`), failures, median
  duration, daily trend, and failures by phase, error code, app/policy, profile and model. Select a
  bar to drill down.
- **Deployments:** sortable table with filters for date range, flow, status, profile, model and
  search text. Select a row for the detail view: timeline, evidence, causes, fix, structural action,
  failing apps/policies, matched diagnostics.
- **Structural improvements:** ranked by failed deployments × confidence (ambiguous and generic
  findings weigh less).
- **Diagnostics & logs:** capability test, upload, analysed archives.
- **Data sources & rules:** endpoint status (BETA labels), device preparation notice, read-only
  policy, requested scopes, rules with sources.

**Missing data** is shown as **Not available**. Deployments without a known status are counted
separately and are excluded from the success rate and from failure charts.

### Presentation mode and anonymization

- **P** toggles presentation mode: large charts, no navigation chrome. **←/→**, **PgUp/PgDn** or
  **Space** move between slides, **1–9** jump to a slide, **Home/End**, **Esc** exits. The slides
  are overview, phase, error codes, apps/policies, model, profile, structural improvements and the
  selected deployment.
- **A** (or the toggle) anonymizes user names, device names and serial numbers **everywhere**,
  including free-text failure details, log lines, the presentation and **exports**. Masking happens
  on the server with stable per-session pseudonyms (`user-1A2B3C`, `device-…`, `SN-…`, HMAC with a
  random key per server run), so values can be correlated in the session but not reversed.
- Outside presentation mode, **1–5** switch views.

---

## Security

- Bound to `127.0.0.1`. Requests with any other `Host` header are rejected (DNS rebinding protection).
  The only exception is `authMode: graphCli`, where `localhost:<port>` is accepted for the sign-in
  callback alone, which immediately redirects to `127.0.0.1`.
- State-changing requests (POST) require a same-origin `Origin` header, `Sec-Fetch-Site:
  same-origin` (when sent) and a per-run **CSRF token** header. No cookies are used, so there is no
  cookie to steal or ride.
- Strict **CSP**: `default-src 'none'; script-src 'self'; style-src 'self'; …; frame-ancestors 'none'`,
  plus `nosniff`, `X-Frame-Options: DENY`, `no-referrer` and `no-store`. No inline scripts or styles,
  no CDN.
- All Graph and log data is treated as untrusted. The UI only renders through `textContent`/DOM
  APIs (`web/assets/dom.js`). `innerHTML` is never used, `on*`/`style` attributes are refused and
  links are restricted to Microsoft Learn and same-origin download tickets.
- Tokens (access and refresh) live only in the in-memory app state. They are never logged, written
  to disk or sent to the browser. Sign out clears tokens and tenant data from memory.
- Sign-in validates `state` (single use, 10-minute lifetime), PKCE, `nonce`, `aud` and `tid`.
- Exports and diagnostics downloads require acknowledging a sensitivity warning. They are built in
  memory and served once via a random, 2-minute, single-use ticket. CSV cells are protected against
  formula injection.
- Console logging is operational only. Tokens, codes and UPNs are scrubbed (`Protect-AdLogText`).
  Pode request logging is not enabled, so query strings such as the authorization code are never logged.

---

## Tests

```powershell
Invoke-Pester ./tests -Output Detailed
node --test tests/js/filters.test.mjs   # also run from Pipeline.Tests.ps1 when Node is installed
```

Current result: **168 Pester tests pass, 0 fail** (including the Node filter tests), on PowerShell 7.6
with Pode 2.14.2 and Pester 5.

| File | Covers |
| --- | --- |
| `Rules.Tests.ps1` | rules.json validation, required signals, ambiguity, context exclusion, ranking, "never certain" |
| `GraphClient.Tests.ps1` | Read-only enforcement (methods, hosts, POST exception look-alikes), pagination, foreign nextLink, 429/503 retry, 403, filter fallback, log redaction |
| `Analysis.Tests.ps1` | Missing fields → Not available, phase/flow/error-code derivation, profile drift, improvements, durations |
| `LogParser.Tests.ps1` | .reg parsing, ESP states, serial/EntDMID matching, sample zip, nested cab-in-zip, zip-slip, zip bomb, entry limit, fake archives, temp cleanup |
| `Anonymize.Tests.ps1` | Masking in fields and free text, stable pseudonyms, exports, CSV injection |
| `SafeRendering.Tests.ps1` | No HTML sinks or CDN in the front end, plus a live server test: 127.0.0.1-only binding, CSP, Host/Origin/CSRF checks, single-use exports, asset whitelist, uploads |
| `Auth.Tests.ps1` | PKCE, state (single use, expiry), tenant mismatch, consent errors, token exchange against a mocked endpoint, both sign-in modes |
| `Pipeline.Tests.ps1` | Regression for a deployment lost by a server-side date filter, a tenant with exactly one deployment, `deploymentState` case variants, pipeline diagnostics without tokens or personal data |
| `js/filters.test.mjs` | Front-end filter logic (`web/assets/filters.js`) with `node --test` |

**Tested in a real tenant:** sign-in with `graphCli`, refresh, a real failed deployment shown
with its phase and evidence, and analysis of a real Intune Collect diagnostics zip. **Not yet tested
in a real tenant:** the `createDownloadUrl` download path, pre-provisioned and self-deploying flows,
hybrid join, and large tenants (throttling over many pages).

---

## Configuration (`config\settings.json`)

| Setting | Default | |
| --- | --- | --- |
| `authMode` | `custom` | `custom` = own app registration, `graphCli` = Microsoft Graph Command Line Tools |
| `tenantId`, `clientId` | – | Both required for `custom`. For `graphCli`, `tenantId` is optional and `clientId` is ignored. |
| `port` | 8765 | Must match the registered redirect URI |
| `defaultDays` / `maxDays` | 30 / 90 | Date range |
| `maxUploadMB` / `maxExtractedMB` / `maxArchiveEntries` | 250 / 2048 / 10000 | Upload and extraction limits (the Pode body limit in `server.psd1` is 300 MB) |
| `maxProfileLookups` | 300 | Per-device profile lookups per refresh |
| `tryPolicyStatusDetails` | false | Try the removed `policyStatusDetails` endpoint anyway |
| `policyDetailsForAllEvents` | false | With `tryPolicyStatusDetails`, also request it for successful deployments |
| `graphMaxRetries` | 5 | Throttling and transient error retries |
| `allowDiagnosticsDownloadPost` | true | The single POST exception |
| `requestConfigurationReadScope` | true | Request `DeviceManagementConfiguration.Read.All` |
| `useCommunityDiagnosticsScript` | false | Optional community supplement |
| `openBrowser` | true | Open the browser on start |

---

## Limitations

- All Autopilot Graph endpoints are **beta** and can change. Field names are read defensively and
  missing fields show as Not available.
- Device preparation (Autopilot v2) deployment data isn't retrieved (export API requires POST).
- Diagnostics download through Graph may be refused even with the right roles, per Microsoft's
  documentation. Manual upload is the supported fallback.
- Apps and policies per deployment aren't available from Graph (`policyStatusDetails` was removed).
  Failing apps come from uploaded diagnostics. `autopilotEvents` is read in full without a server-side
  filter, so very large tenants take longer to refresh.
- `autopilotEvents` doesn't carry a device model. It is joined from Autopilot device identities by
  serial number.
- Event log messages are rendered by the local machine's event providers. On a workstation without
  the Autopilot provider, messages fall back to raw event properties.
- Tokens are refreshed in memory. Closing the PowerShell window ends the session.
- Single-user local tool: there is one sign-in per running server.

---

## Pipeline diagnostics

**Data sources & rules** > **Data pipeline diagnostics** shows where rows go between Graph and the
screen. It shows counts, enum values, tenant ID and scope names only: no tokens and no user names,
device names or serial numbers.

- Raw rows from Graph (endpoint, pages), rows excluded by the refreshed date range, rows without any
  date, rows after processing (per status), and rows after the browser filters (which filter hides
  how many, with a reset button).
- `deploymentState` values exactly as Graph returned them (casing kept) and what each maps to.
  Unknown values are flagged. Status mapping is case- and whitespace-insensitive, and `failed` counts
  as a failure too.
- Last refresh start, finish and error. When a refresh failed, it says that older data is shown.
- Signed-in tenant ID, configured tenant, authority, sign-in app and missing Graph permissions.
- **Find a deployment**: enter the exact event ID, serial number, device name or Intune device ID. It
  checks the raw Graph rows of the last refresh and returns the verdict: shown, outside the date
  range, or dropped in processing (a bug). It also says whether the current browser filters hide it.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| A deployment visible in the Intune portal is missing | Open **Data pipeline diagnostics** and use **Find a deployment** with its serial number. The verdict says whether Graph returned it, whether the date range excluded it, or whether a browser filter hides it. |
| **Sign in** is disabled | Set `"authMode": "graphCli"`, or `tenantId` + `clientId`, in `config\settings.json`. Restart after editing. |
| `graphCli`: AADSTS50011 or "can't reach localhost" | The browser must be able to open `http://localhost:<port>`. Check that nothing else maps `localhost` (hosts file, proxy). The server answers on 127.0.0.1. |
| `graphCli`: AADSTS65001 / "need admin approval" | The Graph Command Line Tools app has no consent for these permissions in your tenant. Ask an admin to sign in once and consent on behalf of the organisation, or use Option B. |
| `graphCli`: AADSTS50105 / AADSTS53003 | Assignment or Conditional Access on *Microsoft Graph Command Line Tools* blocks you. |
| `AADSTS50011` reply URL mismatch | Register exactly `http://127.0.0.1:<port>/auth/callback` (manifest, public client). Check `port`. |
| `AADSTS7000218` client_assertion or client_secret required | The redirect URI was added under **Web**. Move it to public client / Mobile and desktop (manifest `publicClient.redirectUris`). |
| `AADSTS9002327` / cross-origin errors | The redirect URI was added as **SPA**. Use the public client platform instead. |
| `AADSTS65001` consent required | Grant admin consent for the delegated permissions. |
| "account belongs to a different tenant" | You signed in with an account from another tenant than `tenantId`. |
| Refresh shows sources as **forbidden** | Missing consent for that permission, or your Intune role lacks read access. The **Data sources** tab shows which call failed. |
| Session expired banner | The refresh token expired or was revoked (sign-in frequency, CA). Sign in again. |
| Capability test: 403 | Your account can't list or download diagnostics through Graph. Download from the Intune admin center and upload. |
| Upload rejected | Only `.zip`/`.cab`, within the size limits. Real archives are required (magic bytes are checked). |
| "Forbidden: unexpected Host header" | Open the app at `http://127.0.0.1:<port>`, not `localhost` or a machine name. |
| Port already in use | Start with `-Port 9000` and register the matching redirect URI. |
| Pode not found | `Install-PSResource -Name Pode -Scope CurrentUser` or start with `-InstallDependencies`. |

Set `$env:AUTOPILOT_DASHBOARD_DEBUG = 1` before starting for debug-level console output. It is still
scrubbed of tokens and UPNs.

---

## Project layout

```
Start-AutopilotDashboard.ps1   entry point
rules.json                     analysis rules
server.psd1                    Pode server limits
config/settings.example.json   configuration template (settings.json is git-ignored)
src/AutopilotDashboard.psm1    module loader
src/Private/*.ps1              logging, config, Graph client, auth, data, analysis, logs, diagnostics,
                               anonymization, export, demo data, app state, pipeline diagnostics
src/Server.ps1                 Pode routes and security middleware
web/                           index.html + assets (JS, CSS, SVG), no external resources
web/assets/filters.js          pure front-end filter logic (tested with node --test)
demo/sample-diagnostics/       fictional diagnostics for demo and tests
tests/                         Pester 5 tests, tests/js/ for the Node tests
docs/Studentenopdracht.md      student brief: prompt, pitfalls and checklist (Dutch)
.gitattributes                 keeps the sample diagnostics byte-exact (encoding is part of the tests)
```

---

## Contributing and data safety

Issues and pull requests are welcome. Before you open one:

- Use a **test tenant** only. Never include tokens, tenant IDs, user names, device names, serial
  numbers or real logs in an issue, a commit or a test.
- Never commit real diagnostics. Add sanitized fixtures under `demo/sample-diagnostics/` or build
  them inside the test. `.gitignore` already blocks `config/settings.json`, exports, `.cab` files and
  `IntuneDiagnostics-*.zip`.
- Run `Invoke-Pester ./tests` and make sure every test passes.
- Keep the read-only policy: no new Graph methods besides `GET`, and new rules need a
  `learn.microsoft.com` source and a `verification` note.

---

## License

[MIT](LICENSE). This is a community tool, not a Microsoft product. Diagnoses are suggestions: always
check the evidence yourself.
