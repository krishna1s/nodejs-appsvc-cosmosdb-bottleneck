#!/bin/bash

# Function to get URL status code
get_url_status_code() {
    url=$1
    status_code=$(curl -o /dev/null -s -w "%{http_code}" "$url")
    echo $status_code
}

# Set error handling
set -e

# az login --use-device-code
output=$(az account show -o json)
subscription_list=$(az account list -o json)
echo "$subscription_list" | jq -r '.[] | "\(.name)\t\(.id)\t\(.tenantId)"'
selected_subscription=$(echo "$output" | jq -r '.name')
echo "Currently logged in to subscription \"$selected_subscription\" in tenant $(echo "$output" | jq -r '.tenantId')"
read -p "Enter subscription Id ($(echo "$output" | jq -r '.id')): " selected_subscription
selected_subscription=${selected_subscription:-$(echo "$output" | jq -r '.id')}
echo "Changed to subscription ($selected_subscription)"

while true; do
    read -p "Enter webapp name: " deployment_name
    deployment_name=$(echo "$deployment_name" | xargs) # Trim whitespace
    if [[ "$deployment_name" =~ xbox|windows|login|microsoft ]]; then
        echo "Webapp name cannot have keywords xbox, windows, login, microsoft"
        continue
    fi

    # Check if the web app name is available
    http_status=$(get_url_status_code "http://$deployment_name.azurewebsites.net")
    if [[ "$http_status" -eq 000 ]]; then
        break
    else
        echo "Webapp name taken"
    fi
done

read -p "Enter location (eastus): " location
location=${location:-eastus}

resource_group="${deployment_name}${location}-rg"
echo "Creating resource group $resource_group"
az group create --location "$location" --name "$resource_group" --subscription "$selected_subscription"

database_name="$(echo "$deployment_name" | tr '[:upper:]' '[:lower:]')db" # Convert to lowercase

echo "Deploying Sample application.. (this might take a few minutes)"
deployment_outputs=$(az deployment group create \
    --resource-group "$resource_group" \
    --subscription "$selected_subscription" \
    --mode Incremental \
    --template-file ./windows-webapp-template.json \
    --parameters "webAppName=$deployment_name" \
    --parameters "hostingPlanName=$deployment_name-host" \
    --parameters "appInsightsLocation=$location" \
    --parameters "databaseAccountId=$database_name" \
    --parameters "databaseAccountLocation=$location" -o json)

connection_string=$(echo "$deployment_outputs" | jq -r '.properties.outputs.azureCosmosDBAccountKeys.value' | cut -d'&' -f1)

echo "Setting connection string to cosmos db"
az webapp config appsettings set \
    --name "$deployment_name" \
    --resource-group "$resource_group" \
    --subscription "$selected_subscription" \
    --settings CONNECTION_STRING="$connection_string"

echo "Setting app setting for App Service"
az webapp config appsettings set \
    --name "$deployment_name" \
    --resource-group "$resource_group" \
    --subscription "$selected_subscription" \
    --settings MSDEPLOY_RENAME_LOCKED_FILES=1

publish_config=$(az webapp deployment list-publishing-credentials \
    --name "$deployment_name" \
    --resource-group "$resource_group" \
    --subscription "$selected_subscription" -o json)

scm_uri=$(echo "$publish_config" | jq -r '.scmUri')

echo "Publishing sample app.. (this might take a minute or two)"
git init
git config user.email "you@example.com"
git config user.name "Example man"
git add -A
git commit -m "Initial commit"
git remote add azwebapp "$scm_uri" || git remote set-url azwebapp "$scm_uri"
git push azwebapp main:master

while true; do
    echo "Warming up App Service.."
    sleep 3
    http_status=$(get_url_status_code "http://$deployment_name.azurewebsites.net")
    if [[ "$http_status" -eq 200 ]]; then
        echo "Deployment Complete"
        echo "Open url https://$deployment_name.azurewebsites.net in the browser"
        echo "To delete the app, run command 'az group delete --name $resource_group'"
        exit 0
    fi
done