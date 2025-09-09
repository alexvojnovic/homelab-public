#!/bin/bash

EMAIL="$YOUR_EMAIL_ADDRESS" # Email address used for ACME registration

AWS_REGION="$YOUR_AWS_REGION"
AWS_ACCESS_KEY_ID="$YOUR_AWS_ACCESS_KEY_ID"
AWS_ACCESS_KEY_SECRET="*****"

PARENT_DNS_ZONE="$YOUR_DOMAIN_NAME.com"
ARGOCD_HOST="argocd.$YOUR_DOMAIN_NAME.com"
ARGOCD_PASSWORD="****" 

apt-get update

echo "Installing Helm..."
# Helm 3
curl -SsL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "Installing K3S cluster..."
# K3S: Single Node, No Traefik, config available to all users
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -s - --write-kubeconfig-mode 644 
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml # cluster access for helm, kubectl

echo "Installing Nginx Ingress Controller..."
# Reverse proxy, SSL termination
helm install nginx-ingress oci://ghcr.io/nginxinc/charts/nginx-ingress --version 1.1.0

echo "Installing ArgoCD..."
# Install ArgoCD With Helm
kubectl create namespace argocd 
helm repo add argo https://argoproj.github.io/argo-helm 
helm install argocd argo/argo-cd --namespace argocd --set configs.cm.["accounts.readonly]"=apiKey, configs.rbac.["policy.csv"]="g, readonly, role:readonly"
# Patch ArgoCD-server to accept http, avoiding https redirect loop
kubectl patch configmap -n argocd argocd-cmd-params-cm -p '{"data":{"server.insecure":"true"}}' 
kubectl rollout restart -n argocd deployment argocd-server 
# Update Argocd admin password
apt-get -y install apache2-utils 
kubectl -n argocd patch secret argocd-secret -p '{"stringData": {"admin.password": "'$(htpasswd -bnBC 10 "" $ARGOCD_PASSWORD | tr -d ':\n' | sed 's/$2y/$2a/')'", "admin.passwordMtime": "'$(date +%FT%T%Z)'"}}'

echo "Installing Cert Manager and Cert Issuers"
# cert-manager CRDs first
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.crds.yaml 
kubectl create namespace cert-manager

# Add the following Resources
# 1. Staging Issuer, bound to argocd namespace
# 2. Production Cluster Issuer
# 3. AWS Access secret, for dns solver
# 4. Ingress to direct traffic to argocd-server

cat <<EOF | kubectl create -f -
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: argocd
spec:
  acme:
    email: $YOUR_EMAIL_ADDRESS
    privateKeySecretRef:
      name: letsencrypt-prod
    server: https://acme-v02.api.letsencrypt.org/directory
    solvers:
    - dns01:
        route53:
          accessKeyID: $AWS_ACCESS_KEY_ID
          region: $YOUR_AWS_REGION
          secretAccessKeySecretRef:
            key: secret-access-key
            name: $YOUR_ROUTE53_CREDENTIALS_SECRET_NAME
      selector:
        dnsZones:
        - $YOUR_DOMAIN_NAME.com
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "$EMAIL"
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - selector:
        dnsZones:
          - "$PARENT_DNS_ZONE"
      dns01:
        route53:
          region: "$AWS_REGION"
          accessKeyID: "$AWS_ACCESS_KEY_ID"
          secretAccessKeySecretRef:
            name: $YOUR_ROUTE53_CREDENTIALS_SECRET_NAME
            key: secret-access-key
---
apiVersion: v1
kind: Secret
metadata:
  name: $YOUR_ROUTE53_CREDENTIALS_SECRET_NAME
  namespace: argocd
type: Opaque
stringData:
  secret-access-key: "$AWS_ACCESS_KEY_SECRET"
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-user: "$YOUR_GRAFANA_ADMIN_USERNAME"
  admin-password: "$YOUR_GRAFANA_ADMIN_PASSWORD"
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    # cert-manager.io/cluster-issuer: letsencrypt-produuction
    cert-manager.io/issuer: letsencrypt-prod
    kubernetes.io/tls-acme: "true"
    acme.cert-manager.io/http01-edit-in-place: "true"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    gethomepage.dev/enabled: "true"
    gethomepage.dev/group: Tools
    gethomepage.dev/icon: argo-cd.png
    gethomepage.dev/name: ArgoCD
    gethomepage.dev/pod-selector: ""
    gethomepage.dev/widget.key: $WIDGET_KEY
    gethomepage.dev/widget.type: argocd
    gethomepage.dev/widget.url: https://argocd.$YOUR_DOMAIN_NAME.com

spec:
 ingressClassName: nginx
 tls:
   - hosts:
       - "$ARGOCD_HOST"
     secretName: argocd-server-tls
 rules:
   - host: "$ARGOCD_HOST"
     http:
       paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: argocd-server
               port:
                 number: 443
EOF
# install cert manager
helm repo add jetstack https://charts.jetstack.io
helm install --replace cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.13.3 \
  --set ingressShim.defaultIssuerName="letsencrypt-prod" \
  --set ingressShim.defaultIssuerKind="Issuer" 
