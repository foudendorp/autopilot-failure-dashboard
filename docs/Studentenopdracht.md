# Bouw je eigen Autopilot Failure Dashboard

Nov 6, 2026 · @Frans

Met deze opdracht bouw je met een AI-codeerassistent een lokaal, read-only dashboard dat mislukte Windows Autopilot-deployments in Intune analyseert. Dit is een verdiepingsopdracht voor na de workshop: reken op meerdere uren.

## Wat je nodig hebt

- Een Windows-beheerwerkplek met PowerShell 7.4 of hoger (7.6 aanbevolen)
- Node.js, voor de JavaScript-tests met `node --test`
- Een AI-codeerassistent, die je organisatie heeft goedgekeurd
- Een Intune-testtenant en een testaccount
- Minstens één mislukte testdeployment, om de app met echte data te testen

Gebruik geen productietenant. De app werkt ook zonder tenant in Demo mode, dus daar begin je mee.

## Zo pak je het aan

1. Geef de volledige prompt uit deze handleiding aan je AI-codeerassistent. Pas alleen `authMode` aan als je een eigen app-registratie gebruikt.
2. Laat de assistent in kleine stappen bouwen en test eerst met `./Start-AutopilotDashboard.ps1 -Demo`.
3. Controleer na elke stap welke tests zijn gedraaid en wat ze aantonen.
4. Test daarna zelf met je testtenant en een mislukte deployment.
5. Loop de controlelijst na.

## Regels voor veilig werken

- Gebruik alleen een testtenant, een testaccount en leesrechten.
- Plak geen tokens, tenant-ID's, gebruikersnamen, serienummers of echte logs in je AI-assistent.
- Zet nooit echte diagnostics in een repository. Gebruik opgeschoonde testbestanden.
- Test met echte tenantdata zelf en deel alleen gemaskeerde uitkomsten met de assistent.
- Controleer zelf elke diagnose. Het dashboard stelt een mogelijke oorzaak voor, het bewijs beslist.

## De prompt

Kopieer het hele blok. De prompt is in het Engels, net als de app.

```markdown
# Build: Local Autopilot Failure Dashboard (Microsoft Intune)

You are helping me build a local web app that analyses failed Windows Autopilot deployments in Microsoft Intune. Work in small, testable steps. After each step, run the tests and tell me what you verified. Ask at most three questions when something blocks you; otherwise make a sensible choice and state it. Verify every Microsoft Graph endpoint and every error code against the current Microsoft Learn documentation before you write code for it, and tell me where the documentation differs from this prompt. Documentation can be wrong: treat a real tenant response as stronger evidence.

## Goal
Start the app on a Windows admin workstation, sign in to an Intune tenant, retrieve Autopilot deployment data and diagnostics, and show in a dashboard, for each failed deployment: the phase where it failed, the evidence, the likely or possible causes, a recommended fix and a structural action. The dashboard is also used in live workshops.

## Data safety
- Use only a test tenant, a test account and read-only permissions.
- Never ask me to paste tokens, tenant IDs, user names, serial numbers or real logs into this conversation.
- Never commit real diagnostics. Create sanitized fixtures for tests.
- I run real-tenant tests myself and share only masked results.

## Platform
- Windows, PowerShell 7.4+ (7.6 recommended). Backend: Pode as local web server; explain the choice in the README.
- Node.js for the JavaScript tests. List it as a prerequisite.
- Frontend: plain HTML, CSS and JavaScript. All assets local, no CDN, no inline scripts or styles.
- One command: ./Start-AutopilotDashboard.ps1 with -Demo, -Port, -NoBrowser, -ConfigPath and -InstallDependencies.
- Bind only to 127.0.0.1. Never expose the app to the network.

## Sign-in (interactive, delegated, no secrets)
- OAuth 2.0 authorization code flow with PKCE as a public client. No client secrets, no certificates.
- Two modes via "authMode" in config/settings.json:
  - "custom": your own app registration. Redirect URI http://127.0.0.1:<port>/auth/callback. The portal refuses http loopback URIs with 127.0.0.1, so add it via the app manifest (publicClient.redirectUris) or Microsoft Graph PowerShell.
  - "graphCli": the Microsoft Graph Command Line Tools app (client ID 14d82eec-204b-4c2f-b7e8-296a70dab67e). It only accepts http://localhost (port ignored), so the redirect is http://localhost:<port>. Accept the localhost host name ONLY for that callback and immediately redirect to 127.0.0.1. tenantId is optional ("organizations" authority).
- Validate state (single use, 10 minutes), PKCE, nonce, aud and tid. Show the account, the tenant ID and which sign-in app is used.
- Least-privilege delegated scopes, listed in the README: DeviceManagementManagedDevices.Read.All, DeviceManagementServiceConfig.Read.All, DeviceManagementApps.Read.All, optional DeviceManagementConfiguration.Read.All, plus openid, profile and offline_access.
- Tokens only in memory: never logged, never sent to the browser, never written to disk. Refresh tokens in memory and show an expired session clearly. Sign out clears tokens and tenant data.

## Read-only Graph client
- One central function for every Graph call. Allow only GET to https://graph.microsoft.com, and check the host of every @odata.nextLink too.
- One documented POST exception: .../managedDevices/{id}/logCollectionRequests/{id}/createDownloadUrl, matched by a strict regex and switchable in settings. Block everything else before the request is sent.
- Pagination via @odata.nextLink. Retry 429 and 5xx with Retry-After or exponential backoff; never retry other 4xx. Log Graph's error message and request-id, with tokens and UPNs scrubbed.

## Data retrieval
- GET /beta/deviceManagement/autopilotEvents: all pages and NO server-side $filter. Apply the date range locally: keep a row when ANY of deploymentStartDateTime, enrollmentStartDateTime, eventDateTime or deploymentEndDateTime is in range. Keep rows without a usable date (Graph uses 0001-01-01 for "not set") and show them as "Not available". Reason: a server-side eventDateTime filter drops deployments the Intune portal still shows.
- Do not call GET /beta/deviceManagement/autopilotEvents/{id}. It returned HTTP 400 in a real tenant. Use the list call and select the row locally.
- GET /beta/deviceManagement/windowsAutopilotDeviceIdentities, and per device in scope ?$expand=deploymentProfile,intendedDeploymentProfile. Flag profile drift.
- policyStatusDetails: in the current Graph beta schema, deviceManagementAutopilotEvent has no relationships. Tenants answer 400 "Resource not found for the segment 'policyStatusDetails'" and $expand fails too. Do not call it by default; make it an opt-in setting that stops at the first such answer.
- App evidence:
  - Use the failed event's windows10EnrollmentCompletionPageConfigurationDisplayName to find the matching Enrollment Status Page in GET /beta/deviceManagement/deviceEnrollmentConfigurations.
  - Read selectedMobileAppIds from that configuration.
  - For each app, call GET /beta/deviceAppManagement/mobileApps/{id} and show its rules as evidence.
  - Handle an empty configuration name or app list as "Not available".
  - A failure in additional details must never remove the deployment or fail the refresh.
- Autopilot device preparation deployment status is only available via POST reports/exportJobs (AutopilotV2DeploymentStatus). That is outside the read-only policy: show "Not available" with the reason. Device preparation policies may be listed with GET.
- Default range: the last 30 days. Label beta endpoints. Show progress, the last refresh time and the status of every source (ok, forbidden, unsupported, error).

## Diagnostics and logs
- Read Microsoft's "Collect diagnostics" article. It says diagnostics can't be collected or downloaded through Graph directly, while Graph documents createDownloadUrl. Build a capability test: list logCollectionRequests (GET), try createDownloadUrl only for an existing completed collection, never create a collection. When it fails, explain why and offer manual upload.
- Support uploads of .zip (Intune Collect diagnostics) and .cab (mdmdiagnosticstool -area Autopilot;TPM). The parser must handle real Intune Collect archives. Build sanitized fixtures with these real-world traits; I will test a real archive myself:
  - Intune Collect zips contain nested .cab files and duplicate copies of the same logs.
  - expand.exe renames the output of single-file cabs: extract .cab files with Windows' tar.exe.
  - MDMDiagReport_RegistryDump.reg can be UTF-8 without BOM, with indented values and DWORD:, QWORD: and MULTI_SZ: types, not only regedit's UTF-16 format.
  - Paths can exceed 260 characters: copy .evtx files to a short temp path before Get-WinEvent.
- Safety: magic-byte checks, size limits, zip-slip and zip-bomb protection (entry count, extracted size, actual versus declared size), reject reparse points, extract to a per-upload temp folder and delete it in a finally block. Keep only the parsed summary, in memory.
- Parse: HKLM\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot (TenantMatched, IsAutopilotDisabled, tenant IDs); ESP tracking ONLY under SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking (InstallationState 1 to 4), not the CSP node cache with the same name; EntDMID and serial number for matching; only the ModernDeployment-Diagnostics-Provider/Autopilot event log (other channels reuse the same event IDs); only Intune and Autopilot text logs (IntuneManagementExtension, AppWorkload, AgentExecutor), not Defender or Windows Update logs.
- Match logs to deployments by serial number or Intune device ID. ESP apps in Error from matched logs feed the "failing apps" chart and detail view.
- Get-AutopilotDiagnosticsCommunity may be used as an optional supplement, never as a requirement.

## Analysis rules (rules.json)
- Each rule has: id, phase, signal (eventId, errorCode, registryValue, text, espInstallationState or policyStatus), optional context (flow, phase), likelyCause, recommendedFix, structuralAction, confidence, sourceUrl (learn.microsoft.com only) and verification (date plus what the documentation literally says). Validate at startup and reload on every refresh.
- At least: events 807, 809, 815, 908, 171 and 172; errors 801C0003, 80180018, 0x80180014, 0x80070774, 0x800705b4 and 0x87d1041c; InstallationState = 4; "Another installation is in progress"; IsAutopilotDisabled = 1; TenantMatched = 0.
- When one piece of evidence matches several rules (for example 0x800705B4), show all of them as "Possible cause". Never present a cause as certain, and always show the evidence. Say in verification where a rule goes beyond the documentation.

## Dashboard
- KPIs: total deployments, success rate (success / (success + failed)), failures, median duration. Daily trend. Failures by phase, error code, app or policy, profile and model.
- Filters: date range, flow, status, profile, model and search. Sortable table. Detail view with timeline, evidence, causes, fix and structural action. Ranked list of structural improvements.
- Missing data is "Not available" and never counts as success or failure. Map deploymentState case- and whitespace-insensitively.
- Pipeline diagnostics view: raw Graph rows, rows excluded by the date range, rows without a date, rows after processing (per status), rows after the browser filters (which filter hides how many), raw deploymentState values with their mapping, the last refresh and its errors, the tenant ID and missing scopes, and a lookup by event ID, serial number or device name that says where a row went. No tokens or personal data in this view.

## Presentation mode and anonymization
- Presentation mode: large charts, no navigation chrome, keyboard control (P, arrow keys, PgUp/PgDn, 1-9, Esc).
- Anonymize toggle (key A): masks user names, device names and serial numbers everywhere, including free text and exports, with stable pseudonyms per server run. It must react within one second on a few hundred rows.

## Security
- Treat all Graph and log data as untrusted: render only via textContent and DOM APIs, never innerHTML; no on* or style attributes from data; links only to learn.microsoft.com.
- Strict Content Security Policy (default-src 'none'; script-src 'self'; ...), nosniff and frame-ancestors 'none'. Reject any Host header other than 127.0.0.1:<port> (DNS rebinding). Every POST needs a same-origin Origin header and a CSRF token header.
- Serve static files from an explicit whitelist. Pode serves a folder named "public" automatically, so do not use that name.
- Persist nothing unless the user exports. Show a sensitivity warning with an acknowledgement before export, use single-use short-lived download links, and protect CSV cells against formula injection. Log only operational information.

## PowerShell pitfalls to test explicitly
- A function that returns `, $array` must not be wrapped in @(...) by its caller: that nests the array.
- `$x = if (...) { $list }` turns a one-item list into the item itself. The browser then receives an object instead of an array and shows an empty table. Use @(if (...) { $list }) for expressions, and test with 0, 1 and many rows.
- PowerShell comparisons are case-insensitive by default; use -ceq in tests where case matters.
- Graph beta fields come and go: read every property defensively.

## Testing
- Demo mode with realistic fictional data (Contoso, *.example), with dates relative to today so the default range has data, plus fictional sample diagnostics.
- Pester 5 tests for: rules (including ambiguity and "never certain"), read-only enforcement (blocked methods and hosts, look-alike POST paths, a foreign nextLink), pagination, throttling, missing fields, log parsing (the real-world formats above, zip-slip, zip bomb, nested cabs, long paths), anonymization (including exports), safe rendering (static checks for HTML sinks and CDNs, plus a live server test for Host, Origin, CSRF and CSP), sign-in (state, tenant mismatch, token exchange against a mocked endpoint) and the data pipeline (a row lost by a server-side filter, a tenant with exactly one deployment, case variants of deploymentState, failing app-evidence calls).
- Put the frontend filter logic in a separate pure JavaScript module and test it with node --test.
- Run all tests, and test the UI in Demo mode in a browser at phone and desktop width.

## Deliverables
Source code, Start-AutopilotDashboard.ps1, config/settings.example.json, rules.json, demo data and sample diagnostics, Pester and JavaScript tests, and a README with prerequisites, both sign-in modes with exact setup steps, permissions, the read-only policy and its exception, startup, limitations and troubleshooting.
At the end, state exactly what you tested, which tests ran and passed, and what still needs testing in a real tenant.
```

## Valkuilen uit de eerste bouw

De eerste versie werkte in Demo mode, maar deze problemen kwamen pas aan het licht met een echte tenant en echte logs. De prompt eist voor elk ervan een oplossing of test.

| Valkuil | Wat er misging | Wat de prompt nu eist |
| --- | --- | --- |
| Serverfilter op datum | `$filter=eventDateTime` liet een mislukte deployment weg die de portal wel toonde | Alle pagina's ophalen en lokaal filteren op elke bekende datum |
| Eén rij in de tenant | PowerShell maakte van een lijst met één item het item zelf, waardoor de tabel leeg bleef | `@(if ...)` gebruiken en testen met 0, 1 en veel rijen |
| `@()` om een functie | De lijst werd in een extra lijst verpakt | Expliciete test op geneste arrays |
| `policyStatusDetails` | Pad en `$expand` gaven HTTP 400, ondanks de documentatie | Standaard uit, en app-bewijs ophalen via de ESP en de app |
| Event ophalen op ID | `GET /autopilotEvents/{id}` gaf HTTP 400 | Alleen de lijst-call gebruiken en lokaal selecteren |
| Aanvullende details | Een mislukte detailcall kan een hele Refresh raken | Deployment altijd tonen, details als "Not available" |
| Sign-in zonder app-registratie | Redirect naar 127.0.0.1 werkt niet met de Graph CLI-app | Modus `graphCli` met localhost-callback, alleen voor die route |
| Diagnostics via Graph | Microsoft zegt dat downloaden via Graph niet kan | Capability-test en handmatige upload |
| `.cab` uitpakken | `expand.exe` hernoemt bestanden in cabs met één bestand | `tar.exe` gebruiken |
| Registry-dump | Een echte dump is UTF-8 zonder BOM, ingesprongen en gebruikt `DWORD:` | Echte formaten parsen en testen met opgeschoonde bestanden |
| Lange paden | `Get-WinEvent` kon een `.evtx` op 281 tekens niet openen | Eerst naar een kort tijdelijk pad kopiëren |
| Verkeerde bronnen | Defender-log en CSP-cache gaven valse bevindingen | Alleen relevante logs en registersleutels |
| Anonymize traag | 5 seconden per toggle in de workshop | Reactie binnen 1 seconde |

## Controlelijst

Toon elk punt met een testuitvoer, schermafbeelding of korte demo.

- [ ] `./Start-AutopilotDashboard.ps1 -Demo` start zonder tenant en toont grafieken, tabel en detailweergave
- [ ] Alle Pester-tests en `node --test` slagen, en het aantal staat in de README
- [ ] Een POST, PATCH of DELETE naar Graph wordt geblokkeerd vóór verzending (test)
- [ ] Een tenant met precies één deployment toont die ene rij (test)
- [ ] Een mislukte detailcall laat de deployment zichtbaar en de Refresh werkend (test)
- [ ] Een echte mislukte testdeployment verschijnt in het dashboard
- [ ] De detectieregel van de gevolgde app staat als bewijs bij de deployment
- [ ] Een echte Intune Collect-zip uit je testtenant wordt lokaal geanalyseerd: registry, ESP-status en Autopilot-events komen door
- [ ] Een zip met `../` in een pad wordt geweigerd (test)
- [ ] Anonymize maskeert namen en serienummers ook in de export
- [ ] Pipeline diagnostics laat zien waar een rij blijft, zonder tokens of persoonsgegevens
- [ ] Presentatiemodus werkt volledig met het toetsenbord
- [ ] De README noemt wat getest is en wat nog in een echte tenant getest moet worden
