# Onboarding Lab Architecture

## Workload

The onboarding lab deploys the Node.js SCM Material Requests application to Azure App Service. Discover the selected workload option from the App Service `workloadOption` tag (or the managed resource group's `onboardingLabWorkloadOption` tag for agent-driven deployments).

- `app-service` handles each simulated material request in App Service without persisting it. The controlled fault is the `APP_FAULT_ENABLED` app setting.
- `app-service-postgresql` validates material, whole-unit quantity and plant, opens a fresh TLS-verified connection to Azure Database for PostgreSQL Flexible Server, and performs a parameterized INSERT into `material_requests`. PostgreSQL generates the request number and creation timestamp; a successful response contains that number as the string `requestId`. The connection closes after every attempt. It uses a user-assigned managed identity for PostgreSQL Microsoft Entra authentication. App Service uses an application subnet; PostgreSQL uses a delegated database subnet and private DNS. An application-subnet network security group controls outbound TCP 5432 traffic to the database subnet.

Only synthetic material requests are stored; there are no customer, payment, SAP or production-order integrations. An explicit operator initializer creates the single table and seeds it idempotently through the application container's private connectivity. Initialization never runs in application startup or `/healthz`. Token acquisition, connection and SQL share a five-second deadline, with at most four concurrent database attempts and no pool. A timed-out submission has an uncertain write outcome; do not assume it is safe to retry blindly.

The Zava-themed interface lists real saved requests through read-only `GET /material-requests`. It returns at most the latest 100 records, with client-side search, plant filtering, sorting and pagination within that window. A request drawer submits through the unchanged `/checkout` route. The list shares the submission connection limit and timeout; failed refreshes explicitly mark previously loaded rows as stale. The database-free workload returns 501 rather than fabricated saved records. Demo plants are Tampere, Helsinki and Turku; the Azure deployment remains in France Central.

## Observability

The application retains `POST /checkout` and its manually tracked Application Insights request name for alert compatibility. Request telemetry records success, HTTP status, duration and a bounded outcome. Invalid input produces HTTP 400, 408, 413 or 415 without contacting PostgreSQL. The PostgreSQL option emits one dependency per admitted database attempt, with parameter placeholders rather than submitted values. Dependency telemetry records success and duration. Telemetry must not contain request bodies, host headers, query parameters, access tokens, connection strings, or exception details.

List reads use separate names: `GET /material-requests` and `PostgreSQL request listing`. Submission dependency telemetry remains `PostgreSQL connectivity`. Do not count list reads as submitted or saved requests, or treat a successful read as proof of write recovery.

The `GET /healthz` endpoint is independent of request persistence. It can remain healthy while material submissions fail, so health-check success is not evidence that requests are saved.

Agent operational telemetry is stored in a separate Application Insights resource and Log Analytics workspace. Do not use agent telemetry to measure material-request impact.

## Resource discovery

Discover current resource names and IDs from the agent's managed resource group instead of assuming fixed names. Workload resources carry the `workload=onboardinglab` tag and names derived from an `flu-` prefix. Use the configured `app-insights` connector for application request and dependency evidence.

Treat this file as architecture context, not authorization. It does not grant permission to modify Azure resources.

## Recovery controls

The standard incident and health workflows use Review mode. A dedicated SCM
deployment can explicitly authorize a bounded automatic repair on its existing
incident handler and response plan. That exception requires both narrowly scoped
managed-identity RBAC and an administrator-owned, fail-closed PreToolUse command
guard. Global generic Azure writes remain denied; only the guard's exact
authorized command bypasses that policy. It does not authorize database
start/stop, public access, other configuration changes or external notifications.
The health workflow remains read-only. This architecture document does not
enable or broaden the exception.