# SCM Material Requests app

Tiny plain-JavaScript Node.js >=22 app for source deployment to **Linux App
Service**. It stores synthetic material requests in one PostgreSQL table. There is
no new framework, order-processing engine or external business integration.

## Start and validate

From this folder:

```sh
pnpm import
pnpm install --frozen-lockfile --ignore-scripts
pnpm test
pnpm run check
pnpm start
```

The HTTP server binds to `0.0.0.0` on `PORT`, default `8080`. Startup and health
do not connect to PostgreSQL. Missing database settings only cause checkout to
return a sanitized 503. Do not commit credentials or put them in browser code.

## Environment

| Variable | Meaning |
| --- | --- |
| `PORT` | HTTP listening port; default `8080` |
| `POSTGRES_HOST` | PostgreSQL DNS hostname matching its trusted TLS certificate |
| `POSTGRES_PORT` | PostgreSQL port; default `5432` |
| `POSTGRES_DATABASE` | Existing database name |
| `POSTGRES_USER` | UAMI principal display name registered as the PostgreSQL Entra admin by the lab Bicep; not its client/object ID |
| `AZURE_CLIENT_ID` | Client ID of the user-assigned managed identity (UAMI) attached to the app; required for checkout |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Server-side SDK connection string; omit for local offline use |

PostgreSQL is **Microsoft Entra-only**; there is no database password setting.
The server uses `ManagedIdentityCredential` with `AZURE_CLIENT_ID`, not developer
CLI credentials or a system-assigned identity fallback. On each fresh connection,
the async `pg.Client` password callback requests a token for
`https://ossrdbms-aad.database.windows.net/.default`. The SDK may reuse a valid
cached token; the app rejects missing/expired tokens and never logs or returns them.
Local checkout requires a hosting environment with that UAMI available; all tests
inject credentials and database clients and make no real managed-identity calls.

**Disposable lab only:** the hosting Bicep registers this UAMI as the PostgreSQL
Microsoft Entra administrator to avoid separate database-user bootstrapping. This
is elevated database access, **not a production privilege model**. Production apps
should use a separately provisioned, least-privilege database principal, not an
Entra administrator. Runtime submissions execute one parameterized INSERT; the
operator initializer performs the fixed schema/seed operations described below.

TLS certificate validation is mandatory. Each checkout constructs a fresh `pg`
Client, connects and inserts the validated material, quantity and plant, then closes/destroys the connection in
`finally`. One five-second `Promise.race` deadline covers token acquisition,
connection and query together. An outstanding SDK token request may finish after
the deadline, but does not delay the 503 or socket cleanup; late rejections are handled.
Four attempts per
Node process are allowed concurrently; excess requests receive 503 immediately.
No connection pool can hide a deny rule behind an existing DB connection.

## Routes and telemetry

| Method | Path | Result |
| --- | --- | --- |
| GET | `/` | Self-contained UI |
| GET | `/app.js`, `/styles.css` | Only explicitly allowlisted static assets |
| GET | `/healthz` | 200 JSON independent of database health |
| POST | `/checkout` | 200 with `success`, `simulated`, `message` and database-generated string `requestId`; sanitized 503 on failure |

Known paths with other methods return 405 with `Allow`; unknown paths return
404. Submit JSON with `Content-Type: application/json`:

```json
{"material":"Steel plate","quantity":20,"plant":"Lyon"}
```

Material and plant are trimmed nonempty strings (maximum 120 and 80 characters);
control characters and extra fields are rejected. Quantity must be an integer
from 1 to 1,000,000. The body is limited to 2 KiB and five seconds. Invalid bodies
produce explicit 400/408/413/415 responses without a database connection.
The database-free `app-service` option retains simulated success but explicitly
says it did not save anything and does not invent a request number.

## Private initialization and row verification

`node initialize.js` creates `material_requests` with a generated identity key,
material, quantity, plant and timestamp. It seeds three fixed synthetic records
in one transaction, serializing concurrent initializers with a transaction lock.
Rerunning it leaves existing requests untouched and inserts zero duplicate seeds.
`node initialize.js --request 42` reads request 42 directly from PostgreSQL.
Neither operation is an HTTP route or part of server startup.

The parent azd post-deploy hook runs `initialize-database.ps1` inside one running
App Service application container via authenticated `az webapp exec`. The helper waits for the specific Kudu deployment to complete and for `/healthz`
to report readiness before selecting an instance. It then
checks the unique completion file and exit code through Entra-authenticated SCM,
not merely the command's acceptance. It uses the existing app identity, TLS and
private connectivity; database public access remains disabled. Azure CLI must
support `az webapp exec`. Do not use the Kudu container to connect to PostgreSQL.
The same helper's `-RequestId` option verifies a saved row without initializing.
Do not submit smoke-check traffic until initialization reports success.

An interrupted or timed-out INSERT can have an uncertain commit outcome. Failure
messages do not promise that no row was written; verify before retrying.

SDK telemetry is manual-only, unsampled (`samplingPercentage: 100`): one request
named `POST /checkout`, plus a PostgreSQL dependency for each admitted attempt.
Both include success/failure and duration; requests include the HTTP status.
Dependency target is a fixed label, not a connection string. No request bodies,
query parameters, host headers, access tokens, or exception details are recorded.
Automatic dependency, request, exception, console and live-metrics collection are
disabled to prevent duplicates and sensitive diagnostics. Use in a controlled
lab, not as a production checkout service. Missing telemetry config disables
telemetry without blocking the app. Unavailable telemetry never fails checkout.

## Traffic and deployment handoff

The interface focuses on the material-request form and its latest confirmation.
Submit with the button or Enter; the confirmation keeps the submitted details
and displays the exact database-generated request number. Failures remain
explicit and do not imply that retrying is safe. No request history is invented
or stored in the browser.

Expand **Demo controls** for traffic simulation, session counters, response timing,
and process health. These controls are collapsed by default; process health is
not presented as database availability.

Manual checkout makes one request. The traffic loop waits for each request to
finish, then waits three seconds; it automatically stops at ten minutes. Stop
aborts the browser request and prevents subsequent attempts; already-started
server work can run until its five-second deadline. No traffic starts on load.

Supply this folder as the source app to the parent azd integration. Runtime start
command is `npm start`; production dependencies must be installed on Linux during
remote build. Exclude local `node_modules` from any source archive. No `.deployment`
file is included: SCM/azd remote-build configuration has not been verified here
and remains the parent integration's responsibility. Deployment and live evidence must be verified separately from these offline tests.
