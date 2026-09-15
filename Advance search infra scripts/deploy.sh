#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - Deploys the full advance-search-app infrastructure on Azure
#
# Order:
#   1. Key Vault          (needs to exist before anything pushes secrets to it)
#   2. Storage Account    (blob container for docs + file share for backup)
#   3. Azure Monitor      (Log Analytics + App Insights)
#   4. App Service        (Django host)
#   5. Cosmos DB
#   6. Azure AI Search    ("Foundry IQ" on the cost sheet)
#   7. Azure Functions    (reuses the Storage Account from step 2)
#   8. Azure OpenAI embedding (text-embedding-3-large, East US 2 — different
#                              region from everything else, same resource group)
#   9. Azure Backup       (Recovery Services Vault, protects the file share)
#  10. Microsoft Defender for Cloud (subscription-scope, deployed last, asks first)
#
# Requires: az cli logged in (az login), jq installed, Contributor on the
# subscription/RG, and Security Admin (or Owner) on the subscription for step 10.
# ==============================================================================
set -euo pipefail

# ---------- Configuration (edit these) ----------
RESOURCE_GROUP="rg-advsearch-dev"
LOCATION="centralindia"
EMBEDDING_LOCATION="eastus2"          # text-embedding-3-large isn't confirmed available in centralindia
NAME_PREFIX="advsearch"
ENVIRONMENT="dev"
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates"
SUB_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/subscription"
# --------------------------------------------------

log()  { echo -e "\n\033[1;36m==> $1\033[0m"; }
warn() { echo -e "\033[1;33m! $1\033[0m"; }

command -v az >/dev/null 2>&1 || { echo "Azure CLI not found. Install it first."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found. Install it first (used to parse deployment outputs)."; exit 1; }

log "Checking Azure CLI login"
az account show >/dev/null 2>&1 || { echo "Run 'az login' first."; exit 1; }
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo "Using subscription: $SUBSCRIPTION_ID"

log "Creating resource group: $RESOURCE_GROUP"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

COMMON_PARAMS="namePrefix=$NAME_PREFIX environment=$ENVIRONMENT location=$LOCATION"

# ---------- 1. Key Vault ----------
log "Deploying Key Vault"
KV_OUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/01-keyvault.json" \
  --parameters $COMMON_PARAMS \
  --query properties.outputs -o json)
KEY_VAULT_NAME=$(echo "$KV_OUT" | jq -r .keyVaultName.value)
KEY_VAULT_URI=$(echo "$KV_OUT" | jq -r .keyVaultUri.value)
echo "Key Vault: $KEY_VAULT_NAME"

# ---------- 2. Storage Account ----------
log "Deploying Storage Account"
ST_OUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/02-storage.json" \
  --parameters $COMMON_PARAMS \
  --query properties.outputs -o json)
STORAGE_ACCOUNT_NAME=$(echo "$ST_OUT" | jq -r .storageAccountName.value)
STORAGE_CONN_STRING=$(echo "$ST_OUT" | jq -r .primaryConnectionString.value)
echo "Storage Account: $STORAGE_ACCOUNT_NAME"

az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "StorageConnectionString" \
  --value "$STORAGE_CONN_STRING" -o none

# ---------- 3. Azure Monitor ----------
log "Deploying Azure Monitor (Log Analytics + App Insights)"
MON_OUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/03-monitor.json" \
  --parameters $COMMON_PARAMS \
  --query properties.outputs -o json)
APPINSIGHTS_CONN_STRING=$(echo "$MON_OUT" | jq -r .appInsightsConnectionString.value)
echo "Application Insights deployed"

# ---------- 4. App Service ----------
log "Deploying App Service (Linux, P1v2)"
APP_OUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/04-appservice.json" \
  --parameters $COMMON_PARAMS appInsightsConnectionString="$APPINSIGHTS_CONN_STRING" keyVaultUri="$KEY_VAULT_URI" \
  --query properties.outputs -o json)
WEB_APP_NAME=$(echo "$APP_OUT" | jq -r .webAppName.value)
WEB_APP_PRINCIPAL_ID=$(echo "$APP_OUT" | jq -r .webAppPrincipalId.value)
echo "App Service: $WEB_APP_NAME"

az keyvault set-policy --name "$KEY_VAULT_NAME" --object-id "$WEB_APP_PRINCIPAL_ID" \
  --secret-permissions get list -o none

# ---------- 5. Cosmos DB ----------
log "Deploying Cosmos DB (NoSQL, 100 RU/s)"
COSMOS_OUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/05-cosmosdb.json" \
  --parameters $COMMON_PARAMS \
  --query properties.outputs -o json)
COSMOS_CONN_STRING=$(echo "$COSMOS_OUT" | jq -r .primaryConnectionString.value)
echo "Cosmos DB deployed"

az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "CosmosDbConnectionString" \
  --value "$COSMOS_CONN_STRING" -o none

# ---------- 6. Azure AI Search ("Foundry IQ") ----------
log "Deploying Azure AI Search (Standard S1)"
SEARCH_OUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/06-search.json" \
  --parameters $COMMON_PARAMS \
  --query properties.outputs -o json)
SEARCH_SERVICE_NAME=$(echo "$SEARCH_OUT" | jq -r .searchServiceName.value)
SEARCH_ADMIN_KEY=$(echo "$SEARCH_OUT" | jq -r .adminKey.value)
echo "AI Search service: $SEARCH_SERVICE_NAME"

az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "SearchAdminKey" \
  --value "$SEARCH_ADMIN_KEY" -o none

# ---------- 7. Azure Functions ----------
log "Deploying Azure Functions (Consumption plan)"
FUNC_OUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/07-functions.json" \
  --parameters $COMMON_PARAMS storageAccountName="$STORAGE_ACCOUNT_NAME" appInsightsConnectionString="$APPINSIGHTS_CONN_STRING" \
  --query properties.outputs -o json)
FUNCTION_APP_NAME=$(echo "$FUNC_OUT" | jq -r .functionAppName.value)
FUNCTION_PRINCIPAL_ID=$(echo "$FUNC_OUT" | jq -r .functionAppPrincipalId.value)
echo "Function App: $FUNCTION_APP_NAME"

az keyvault set-policy --name "$KEY_VAULT_NAME" --object-id "$FUNCTION_PRINCIPAL_ID" \
  --secret-permissions get list -o none

# ---------- 8. Azure OpenAI embedding model (East US 2) ----------
log "Deploying Azure OpenAI (text-embedding-3-large) in $EMBEDDING_LOCATION"
warn "This resource lands in $EMBEDDING_LOCATION, not $LOCATION — same resource group, different region."
EMB_OUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/09-embedding.json" \
  --parameters namePrefix="$NAME_PREFIX" environment="$ENVIRONMENT" location="$EMBEDDING_LOCATION" \
  --query properties.outputs -o json)
OAI_ACCOUNT_NAME=$(echo "$EMB_OUT" | jq -r .accountName.value)
OAI_ENDPOINT=$(echo "$EMB_OUT" | jq -r .endpoint.value)
OAI_DEPLOYMENT_NAME=$(echo "$EMB_OUT" | jq -r .deploymentName.value)
OAI_API_KEY=$(echo "$EMB_OUT" | jq -r .apiKey.value)
echo "Azure OpenAI account: $OAI_ACCOUNT_NAME  (deployment: $OAI_DEPLOYMENT_NAME)"

az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "EmbeddingEndpoint" --value "$OAI_ENDPOINT" -o none
az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "EmbeddingApiKey" --value "$OAI_API_KEY" -o none

# ---------- Wire up Key Vault references as app settings ----------
log "Pointing App Service and Function App at Key Vault secrets"
az webapp config appsettings set --resource-group "$RESOURCE_GROUP" --name "$WEB_APP_NAME" --settings \
  "COSMOS_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=${KEY_VAULT_URI}secrets/CosmosDbConnectionString/)" \
  "SEARCH_ADMIN_KEY=@Microsoft.KeyVault(SecretUri=${KEY_VAULT_URI}secrets/SearchAdminKey/)" \
  "SEARCH_SERVICE_NAME=$SEARCH_SERVICE_NAME" \
  "EMBEDDING_ENDPOINT=@Microsoft.KeyVault(SecretUri=${KEY_VAULT_URI}secrets/EmbeddingEndpoint/)" \
  "EMBEDDING_API_KEY=@Microsoft.KeyVault(SecretUri=${KEY_VAULT_URI}secrets/EmbeddingApiKey/)" \
  "EMBEDDING_DEPLOYMENT_NAME=$OAI_DEPLOYMENT_NAME" \
  -o none

az functionapp config appsettings set --resource-group "$RESOURCE_GROUP" --name "$FUNCTION_APP_NAME" --settings \
  "COSMOS_CONNECTION_STRING=@Microsoft.KeyVault(SecretUri=${KEY_VAULT_URI}secrets/CosmosDbConnectionString/)" \
  "SEARCH_ADMIN_KEY=@Microsoft.KeyVault(SecretUri=${KEY_VAULT_URI}secrets/SearchAdminKey/)" \
  "SEARCH_SERVICE_NAME=$SEARCH_SERVICE_NAME" \
  "EMBEDDING_ENDPOINT=@Microsoft.KeyVault(SecretUri=${KEY_VAULT_URI}secrets/EmbeddingEndpoint/)" \
  "EMBEDDING_API_KEY=@Microsoft.KeyVault(SecretUri=${KEY_VAULT_URI}secrets/EmbeddingApiKey/)" \
  "EMBEDDING_DEPLOYMENT_NAME=$OAI_DEPLOYMENT_NAME" \
  -o none

# ---------- 9. Azure Backup ----------
log "Deploying Azure Backup (Recovery Services Vault + file share protection)"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_DIR/08-backup.json" \
  --parameters $COMMON_PARAMS storageAccountName="$STORAGE_ACCOUNT_NAME" \
  -o none
echo "Backup vault deployed"

# ---------- 10. Microsoft Defender for Cloud (subscription scope) ----------
log "Enabling Microsoft Defender for Cloud plans (subscription-wide)"
warn "This changes protection for the WHOLE subscription, not just this resource group."
read -p "Continue enabling Defender plans on subscription $SUBSCRIPTION_ID? [y/N] " CONFIRM
if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
  az deployment sub create \
    --location "$LOCATION" \
    --template-file "$SUB_TEMPLATE_DIR/09-defender.json" \
    -o none
  echo "Defender for Cloud plans enabled"
else
  warn "Skipped Defender for Cloud step. Re-run 'az deployment sub create --location $LOCATION --template-file $SUB_TEMPLATE_DIR/09-defender.json' later if you want it."
fi

log "Deployment complete"
cat <<SUMMARY

Resource Group:       $RESOURCE_GROUP  ($LOCATION, except embedding below)
Key Vault:             $KEY_VAULT_NAME
Storage Account:       $STORAGE_ACCOUNT_NAME
App Service:           $WEB_APP_NAME  (https://$(az webapp show -g "$RESOURCE_GROUP" -n "$WEB_APP_NAME" --query defaultHostName -o tsv))
Cosmos DB:              deployed, connection string in Key Vault as "CosmosDbConnectionString"
Azure AI Search:        $SEARCH_SERVICE_NAME  (admin key in Key Vault as "SearchAdminKey")
Function App:           $FUNCTION_APP_NAME
Azure OpenAI embedding: $OAI_ACCOUNT_NAME in $EMBEDDING_LOCATION  (deployment "$OAI_DEPLOYMENT_NAME", text-embedding-3-large)
Backup Vault:           rsv-$NAME_PREFIX-$ENVIRONMENT

Secrets stored in Key Vault "$KEY_VAULT_NAME":
  - StorageConnectionString
  - CosmosDbConnectionString
  - SearchAdminKey
  - EmbeddingEndpoint
  - EmbeddingApiKey

SUMMARY
