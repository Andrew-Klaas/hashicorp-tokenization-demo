#!/bin/bash
set -v

nohup kubectl port-forward service/vault-ui 8200:8200 --pod-running-timeout=10m &

sleep 5s

export VAULT_ADDR="http://127.0.0.1:8200"

vault status

# curl \
#   --silent \
#   --request PUT \
#   --data '{"secret_shares": 1, "secret_threshold": 1}' \
#   ${VAULT_ADDR}/v1/sys/init | tee \
#   >(jq -r '.root_token' > /tmp/root-token) \
#   >(jq -r '.keys[0]' > /tmp/unseal-key)

#export UNSEAL_KEY=$(cat /tmp/unseal-key)
#vault operator unseal $UNSEAL_KEY
export ROOT_TOKEN=root
vault login $ROOT_TOKEN

echo '
path "*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}' | vault policy write vault_admin -
vault auth enable userpass
vault write auth/userpass/users/vault password=vault policies=vault_admin

vault login -method=userpass username=vault password=vault

cat << EOF > transform-app-example.policy
path "*" {
    capabilities = ["read", "list", "create", "update", "delete"]
}
path "transform/*" {
    capabilities = ["read", "list", "create", "update", "delete"]
}
EOF
vault policy write transform-app-example transform-app-example.policy

kubectl create serviceaccount vault-auth

kubectl apply --filename vault-auth-service-account.yaml

export VAULT_SA_NAME=$(kubectl get sa vault-auth -o jsonpath="{.secrets[*]['name']}" | awk '{ print $1 }')
export SA_JWT_TOKEN=$(kubectl get secret $VAULT_SA_NAME -o jsonpath="{.data.token}" | base64 --decode; echo)
export SA_CA_CRT=$(kubectl get secret $VAULT_SA_NAME -o jsonpath="{.data['ca\.crt']}" | base64 --decode; echo)

export K8S_HOST="https://kubernetes.default.svc:443"
vault auth enable kubernetes

vault write auth/kubernetes/config \
        token_reviewer_jwt="$SA_JWT_TOKEN" \
        kubernetes_host="$K8S_HOST" \
        kubernetes_ca_cert="$SA_CA_CRT"

vault write auth/kubernetes/role/example \
        bound_service_account_names=vault-auth \
        bound_service_account_namespaces=default \
        policies=transform-app-example \
        ttl=72h

vault write auth/kubernetes/role/vault_go_demo \
        bound_service_account_names=vault-auth \
        bound_service_account_namespaces=default \
        policies=transform-app-example \
        ttl=72h

vault secrets enable database

vault write database/config/my-postgresql-database \
plugin_name=postgresql-database-plugin \
allowed_roles="my-role, vault_go_demo" \
connection_url="postgresql://{{username}}:{{password}}@pq-postgresql-headless.default.svc:5432/vault_go_demo?sslmode=disable" \
username="postgres" \
password="password"

vault write database/roles/vault_go_demo \
db_name=my-postgresql-database \
creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
ALTER USER \"{{name}}\" WITH SUPERUSER;" \
default_ttl="1h" \
max_ttl="24h"

vault secrets enable transform
vault write transform/role/vault_go_demo transformations=ssn
vault write transform/transformations/tokenization/ssn \
    allowed_roles=vault_go_demo \
    max_ttl=24h

vault write transform/encode/vault_go_demo \
    transformation=ssn \
    value="123-45-6789"
