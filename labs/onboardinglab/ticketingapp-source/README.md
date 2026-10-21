# SCM Material Requests source

This folder is the existing Azure Developer CLI project for the onboarding lab,
adapted to SCM Material Requests. Resource names, folders, `/checkout` and workflow
identifiers remain unchanged. It contains the Node.js app, Bicep infrastructure
and deployment parameters required by `azd up`.

## Deploy

Install [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd), and [Node.js 22 or later](https://nodejs.org/en/download). Then run these commands from this directory:

On Windows, PowerShell 7 runs the post-deploy hook. In the full lab checkout,
that hook can opt into agent setup through `ONBOARDING_CONFIGURE_AGENT=true`.
A standalone copy deploys only the workload by default; it does not require
the sibling agent setup files. See the full lab's setup guide before selecting
agent configuration.

```bash
azd auth login
az login
azd env set LAB_WORKLOAD_OPTION app-service
azd up
```

Choose one of two equal workload options before `azd up`:

- `app-service` deploys Linux App Service and shared telemetry.
- `app-service-postgresql` adds PostgreSQL Flexible Server and private networking. Check PostgreSQL 16 / `Standard_B1ms` and SRE Agent availability in the selected subscription and region before deployment.

To select the PostgreSQL option:

```bash
az provider register --namespace Microsoft.DBforPostgreSQL --wait
azd env set LAB_WORKLOAD_OPTION app-service-postgresql
azd up
```

For this fork's dedicated SCM demo, use azd environment `sre-agent-scm`,
`AZURE_LOCATION=francecentral` and `LAB_WORKLOAD_OPTION=app-service-postgresql`.
Use that same location when generating the SRE Agent configuration. The existing
Bicep derives the resource-group name; do not select an unrelated group.

The post-deploy hook runs the idempotent database initializer through the existing
App Service container, then continues optional agent setup. It requires Azure CLI
with `az webapp exec` and PowerShell 7 on both platforms. Startup and `/healthz`
never query PostgreSQL. See [app/README.md](app/README.md) for the JSON payload and
private initialization/read-back helper. Submit smoke traffic only after the
initializer reports completion. No public database endpoint or migration service
is created.

Retrieve the deployed application URL:

```bash
azd env get-value SERVICE_CHECKOUT_ENDPOINT_URL
```

## Validate locally

The tests do not contact Azure:

```bash
cd app
pnpm import
pnpm install --frozen-lockfile --ignore-scripts
pnpm test
pnpm run check
```

## Clean up

```bash
azd down
```