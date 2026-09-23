# advsearch-deploy

ARM templates and shell scripts that provision the full Azure infrastructure for a
small-scale advance search application (Django + Cosmos DB + Azure AI Search, with
Azure OpenAI embeddings for semantic search). Everything is idempotent, parameterized,
and deployable with one command.

## What gets deployed

| # | Resource | Template | Notes |
|---|----------|----------|-------|
| 1 | Key Vault | `templates/01-keyvault.json` | Standard tier, soft-delete on, purge protection off (easy to tear down while testing) |
| 2 | Storage Account | `templates/02-storage.json` | StorageV2, LRS, Hot tier; a `documents` blob container and a `backupshare` file share |
| 3 | Log Analytics + Application Insights | `templates/03-monitor.json` | Workspace-based App Insights, 30-day LA retention, 90-day App Insights retention |
| 4 | App Service Plan (P1v2, Linux) + Web App | `templates/04-appservice.json` | `PYTHON\|3.12` runtime, system-assigned identity for Key Vault access |
| 5 | Cosmos DB (NoSQL) | `templates/05-cosmosdb.json` | Manual throughput, 100 RU/s, single region, periodic backup |
| 6 | Azure AI Search | `templates/06-search.json` | Standard S1, 1 replica/1 partition. Billed/provisioned as `Microsoft.Search/searchServices` — this is what shows as "Foundry IQ" on newer Azure cost sheets |
| 7 | Function App | `templates/07-functions.json` | Consumption (Y1) plan, Linux/Python, reuses the Storage Account from step 2 |
| 8 | Azure OpenAI — `text-embedding-3-large` | `templates/09-embedding.json` | Deployed to **East US 2** (see below), same resource group as everything else |
| 9 | Recovery Services Vault | `templates/08-backup.json` | Daily backup policy, protects the `backupshare` file share |
| 10 | Defender for Cloud plans | `subscription/09-defender.json` | Subscription-scope, deployed last with a confirmation prompt |

### Architecture in one paragraph

Django runs on the App Service, backed by Cosmos DB for structured data and Azure AI
Search for search/retrieval. Documents get vectorized using an Azure OpenAI
`text-embedding-3-large` deployment — this is only an embedding model, not a chat
model, so there's no LLM answer-generation step anywhere in this stack. AI Search
returns ranked results with similarity scores directly. Azure Functions handles
background/async processing. Key Vault holds every secret these services generate;
App Service and Functions read them via Key Vault references rather than plaintext
app settings. Monitor, Backup, and Defender for Cloud round out observability,
resilience, and security posture.

### Why the embedding model is in East US 2, not Central India

Azure OpenAI embedding-model region availability isn't as consistently published as
for chat models, and `text-embedding-3-large` wasn't confirmed available in Central
India at the time this was written. AI Search doesn't need to be in the same region
as the embedding resource — cross-region works fine with a small latency cost — so
this one resource deploys to `eastus2` while everything else stays in `centralindia`.
Check current availability before changing this:
https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/concepts/models-sold-directly-by-azure

## Repository layout

```
advsearch-deploy/
├── deploy.sh                    # deploys everything, in order
├── deploy-embedding.sh          # standalone: redeploy just the embedding model
├── README.md
├── templates/                   # resource-group-scope ARM templates
│   ├── 01-keyvault.json
│   ├── 02-storage.json
│   ├── 03-monitor.json
│   ├── 04-appservice.json
│   ├── 05-cosmosdb.json
│   ├── 06-search.json
│   ├── 07-functions.json
│   ├── 08-backup.json
│   └── 09-embedding.json
└── subscription/                # subscription-scope ARM templates
    └── 09-defender.json
```

## Prerequisites

Before you deploy, make sure you have:

1. **An Azure subscription** with permission to create resources (Contributor role
   minimum; Security Admin or Owner if you also want the Defender for Cloud step).
2. **Azure CLI** installed. Check with:
   ```bash
   az --version
   ```
   If it's not installed: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
3. **jq** installed (used to parse deployment outputs). Check with:
   ```bash
   jq --version
   ```
   Install: `sudo apt install jq` (Debian/Ubuntu), `brew install jq` (macOS), or see
   https://jqlang.org/download/
4. **Bash** — the scripts are written for bash and use `set -euo pipefail`. On
   Windows, run them via WSL or Git Bash rather than PowerShell/cmd.

## Step-by-step: deploying from scratch

1. **Clone this repository**
   ```bash
   git clone <your-repo-url>
cd TTNS-Deployments/"Advance search infra scripts"
   ```

2. **Log in to Azure**
   ```bash
   az login
   ```
   If you have more than one subscription, pick the right one:
   ```bash
   az account list -o table
   az account set --subscription "<subscription-id-or-name>"
   ```

3. **Review the configuration block at the top of `deploy.sh`.** Defaults are:
   ```bash
   RESOURCE_GROUP="rg-advsearch-dev"
   LOCATION="centralindia"
   EMBEDDING_LOCATION="eastus2"
   NAME_PREFIX="advsearch"
   ENVIRONMENT="dev"
   ```
   Edit these if you want different naming, a different primary region, or a
   different resource group name. Resource names are generated from
   `NAME_PREFIX` + `ENVIRONMENT` + a uniqueness suffix, so re-running with the
   same values is safe and won't collide with existing resources.

4. **Make the script executable and run it**
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

5. **Follow the prompts.** The script deploys resources 1–9 automatically. Before
   step 10 (Defender for Cloud), it stops and asks for confirmation, because that
   step changes security settings for your *entire subscription*, not just this
   resource group:
   ```
   Continue enabling Defender plans on subscription <id>? [y/N]
   ```
   Type `y` to proceed or `n` to skip it (you can enable it later — see below).

6. **Read the summary at the end.** It lists every resource name, the App Service
   URL, and which secrets were stored in Key Vault under what names.

A full run typically takes 10–20 minutes — Cosmos DB and Azure OpenAI account
creation are usually the slowest steps.

## What to do after deployment

- **Deploy your Django code** to the App Service (`WEB_APP_NAME` from the summary),
  e.g. via `az webapp deploy` or a CI/CD pipeline of your choice — this repo only
  provisions infrastructure, not application code.
- **Configure the AI Search index's vectorizer** to point at the embedding
  deployment. You'll need the `endpoint`, `deploymentName` (`embedding-large`), and
  API key — the key is in Key Vault as `EmbeddingApiKey`, the others print in the
  deployment summary.
- **Upload documents** to the `documents` blob container in the Storage Account, or
  wire your Functions app to do it.

## Redeploying or updating a single piece

Because every resource has its own template, you can redeploy just one thing without
touching the rest. Example — redeploy only the embedding model:
```bash
./deploy-embedding.sh
```
Or redeploy any other single template directly:
```bash
     az deployment group create \
       --resource-group rg-advsearch-dev \
       --template-file 09-embedding.json
  --parameters namePrefix=advsearch environment=dev location=centralindia
```
ARM deployments are idempotent — re-running a template against an existing resource
updates it in place rather than duplicating it.

## Enabling Defender for Cloud later

If you skipped step 10, or want to re-run it:
```bash
az deployment sub create \
  --location centralindia \
  --template-file 09-defender.json
```

## Tearing everything down

```bash
az group delete --name rg-advsearch-dev --yes --no-wait
```
This removes every resource-group-scoped resource (steps 1–9). Defender for Cloud
plans (step 10) are subscription-scoped and are **not** removed by deleting the
resource group — reset them individually if needed, e.g.:
```bash
az security pricing create --name KeyVaults --tier Free
```

## Assumptions baked into these templates

- Resource group `rg-advsearch-dev` in `centralindia`, embedding resource in
  `eastus2`, prefix `advsearch`, environment `dev` — all overridable at the top of
  `deploy.sh`.
- Functions reuse the one Storage Account rather than getting a dedicated one,
  since this is meant to run at small scale.
- Backup only protects the `backupshare` file share — not blob data or the App
  Service itself. Add more `Microsoft.RecoveryServices` resources if you need that.
- No LLM/chat model is deployed anywhere — only the embedding model. If you later
  want generated answers instead of ranked results + similarity scores, that's an
  intentional gap, not an oversight.

## Cost note

The Premium V2 App Service plan and Standard S1 AI Search are the bulk of the
monthly cost — both bill continuously regardless of traffic. Everything else
(Functions Consumption, Cosmos DB at 100 RU/s, Key Vault, small Storage, Log
Analytics at this volume, and the embedding model, which bills per-token) is
low-cost or near-free at this scale. Review current pricing before deploying:
https://azure.microsoft.com/en-us/pricing/calculator/

## Troubleshooting

- **`az: command not found`** — Azure CLI isn't installed or isn't on your PATH.
  See the Prerequisites section.
- **`jq: command not found`** — install `jq` (see Prerequisites).
- **`Run 'az login' first.`** — you're not authenticated; run `az login` and retry.
- **A deployment fails partway through** — `deploy.sh` doesn't roll back earlier
  steps. Fix the reported error and re-run `./deploy.sh`; already-deployed
  resources will just update in place rather than fail or duplicate.
- **Region/quota errors on the embedding model or App Service** — some
  subscriptions have per-region quota limits on Azure OpenAI or compute SKUs.
  Check your quota in the Azure Portal under that resource type, or try a
  different region by editing the relevant `LOCATION` variable.
