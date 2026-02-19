# Ingress → Gateway API Migration

Demo showing two migration paths from `ingress-nginx` to Gateway API:
1. **Manual** — hand-crafted Gateway API resources
2. **Automated** — using `ingress2gateway` tool

## Repository Structure

```
app/                      # Node.js demo app (/hello, /goodbye routes)
k8s/before-migration/     # Original Ingress + Deployment/Service
k8s/manual/               # Hand-crafted Gateway API manifests
k8s/automated/            # ingress2gateway generated output
scripts/                  # Helper scripts (TLS cert generation)
```

## Prerequisites

- Kubernetes cluster (Docker Desktop/kind/minikube) with kubectl configured
- Docker daemon running

## Setup

### 1. Install kubectl

```bash
# macOS
brew install kubectl

# Linux
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

### 2. Install ingress-nginx

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx rollout status deployment ingress-nginx-controller --timeout=120s
```

### 3. Deploy Demo App

**Build image**:
```bash
docker build -t gateway-demo-app:latest app/
```

**Create TLS secret**:
```bash
./scripts/create-self-signed-tls.sh example.com hello-tls
```

**Deploy app + Ingress**:
```bash
kubectl apply -f k8s/before-migration/deployment-service.yaml
kubectl apply -f k8s/before-migration/ingress.yaml
```

**Expose ingress-nginx on localhost:443**:
```bash
kubectl delete svc ingress-nginx-controller -n ingress-nginx
kubectl expose deployment ingress-nginx-controller -n ingress-nginx --type=LoadBalancer --port=443 --target-port=https --name=ingress-nginx-controller
```

**Add host mapping**:
```bash
echo "127.0.0.1 example.com" | sudo tee -a /etc/hosts
```

**Test**:
```bash
curl -ik https://example.com/hello
# Response: {"message":"Hello from Nginx Ingress!"}

curl -ik https://example.com/goodbye
# Response: {"message":"Goodbye from Nginx Ingress!"}
```

## Migration Path 1: Manual

### Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

### Install Istio (Gateway Controller)

```bash
# Install istioctl
curl -L https://istio.io/downloadIstio | sh -
export PATH="$PWD/istio-1.29.0/bin:$PATH"

# Install Istio
istioctl install --set profile=demo -y
kubectl -n istio-system wait --for=condition=available deployment --all --timeout=120s
```

### Apply Gateway API Resources

```bash
kubectl apply -f k8s/manual/01-gatewayclass.yaml
kubectl apply -f k8s/manual/02-gateway.yaml
kubectl apply -f k8s/manual/03-httproute.yaml
kubectl apply -f k8s/manual/04-redirect-httproute.yaml
```

**Verify**:
```bash
kubectl get gateway hello-gateway
kubectl get httproute
kubectl describe gateway hello-gateway
```

**Test (both Ingress and Gateway API work simultaneously)**:
```bash
# Expose nginx on different port (simulates different LoadBalancer IP)
kubectl delete svc ingress-nginx-controller -n ingress-nginx
kubectl expose deployment ingress-nginx-controller -n ingress-nginx --type=LoadBalancer --port=8443 --target-port=https --name=ingress-nginx-controller

# Test via ingress-nginx (localhost:8443)
curl -ik https://example.com:8443/hello
# Response: {"message":"Hello from Nginx Ingress!"}
# Server header: (no server header or nginx)

# Test via Gateway API (localhost:443 via port-forward)
kubectl port-forward -n default svc/hello-gateway-istio 8444:443 &
curl -ik https://example.com:8444/hello
# Response: {"message":"Hello from Gateway API!"}
# Server header: istio-envoy
```

**Both controllers serving traffic = Zero downtime!** In production, they'd have different LoadBalancer IPs.

### Cutover to Gateway API (Simulating DNS Change)

```bash
# Delete Ingress resource
kubectl delete -f k8s/before-migration/ingress.yaml

# Delete ingress-nginx Service (frees localhost:443)
kubectl delete svc ingress-nginx-controller -n ingress-nginx

# Recreate Gateway to claim localhost:443 (simulates DNS pointing to new IP)
kubectl delete gateway hello-gateway
kubectl apply -f k8s/manual/02-gateway.yaml

# Wait for Gateway to get localhost
sleep 5
```

**Test (now only Gateway API handles traffic)**:
```bash
# Test HTTPS
curl -ik https://example.com/hello
# Response: {"message":"Hello from Gateway API!"}
# Server header: istio-envoy

# Test HTTP redirect
curl -ik http://example.com/hello
# Should redirect to HTTPS
```

## Migration Path 2: Automated

### Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

### Install Istio (Gateway Controller)

```bash
# Install istioctl (skip if already installed from manual path)
curl -L https://istio.io/downloadIstio | sh -
export PATH="$PWD/istio-1.29.0/bin:$PATH"

# Install Istio
istioctl install --set profile=demo -y
kubectl -n istio-system wait --for=condition=available deployment --all --timeout=120s
```

### Install ingress2gateway

```bash
# macOS/Linux (Homebrew)
brew install ingress2gateway

# OR download binary
# macOS
curl -LO https://github.com/kubernetes-sigs/ingress2gateway/releases/download/v0.4.0/ingress2gateway_darwin_amd64.tar.gz
tar -xzf ingress2gateway_darwin_amd64.tar.gz
sudo mv ingress2gateway /usr/local/bin/

# Linux
curl -LO https://github.com/kubernetes-sigs/ingress2gateway/releases/download/v0.4.0/ingress2gateway_linux_amd64.tar.gz
tar -xzf ingress2gateway_linux_amd64.tar.gz
sudo mv ingress2gateway /usr/local/bin/
```

### Generate and Apply

**Generate Gateway API manifests**:
```bash
# From live cluster
ingress2gateway print --providers ingress-nginx --namespace default > k8s/automated/generated-gateway.yaml

# OR from file
ingress2gateway print --providers ingress-nginx --input-file k8s/before-migration/ingress.yaml > k8s/automated/generated-gateway.yaml
```

**Create GatewayClass** (ingress2gateway doesn't generate this):
```bash
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: istio.io/gateway-controller
EOF
```

**Apply generated manifests**:
```bash
kubectl apply -f k8s/automated/generated-gateway.yaml
```

**Verify**:
```bash
kubectl get gateway nginx
kubectl get httproute
```

**Test (both Ingress and Gateway API work simultaneously)**:
```bash
# Expose nginx on different port (simulates different LoadBalancer IP)
kubectl delete svc ingress-nginx-controller -n ingress-nginx
kubectl expose deployment ingress-nginx-controller -n ingress-nginx --type=LoadBalancer --port=8443 --target-port=https --name=ingress-nginx-controller

# Test via ingress-nginx (localhost:8443)
curl -ik https://example.com:8443/hello
# Response: {"message":"Hello from Nginx Ingress!"}
# Server header: (no server header or nginx)

# Test via Gateway API (localhost:443 via port-forward)
kubectl port-forward -n default svc/nginx-nginx 8444:443 &
curl -ik https://example.com:8444/hello
# Response: {"message":"Hello from Gateway API!"}
# Server header: istio-envoy
```

**Both controllers serving traffic = Zero downtime!** In production, they'd have different LoadBalancer IPs.

### Cutover to Gateway API (Simulating DNS Change)

```bash
# Delete Ingress resource
kubectl delete -f k8s/before-migration/ingress.yaml

# Delete ingress-nginx Service (frees localhost:443)
kubectl delete svc ingress-nginx-controller -n ingress-nginx

# Recreate Gateway to claim localhost:443 (simulates DNS pointing to new IP)
kubectl delete gateway nginx
kubectl apply -f k8s/automated/generated-gateway.yaml

# Wait for Gateway to get localhost
sleep 5
```

**Test**:
```bash
# Test HTTPS
curl -ik https://example.com/hello
# Response: {"message":"Hello from Gateway API!"}
# Server header: istio-envoy

# Test HTTP
curl -ik http://example.com/hello
# Response: {"message":"Hello from Gateway API!"}
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Gateway ADDRESS shows `<none>` | Check GatewayClass `controllerName` matches installed controller |
| HTTPRoute not attached | Verify `parentRefs` matches Gateway name/namespace |
| TLS handshake fails | Ensure `hello-tls` Secret exists in same namespace as Gateway |
| 404 errors | Check HTTPRoute `hostnames` and path `matches` |
| `Unknown field` errors | Update Gateway API CRDs to v1.2.0+ |

**Debug commands**:
```bash
kubectl describe gateway <name>
kubectl describe httproute <name>
kubectl get gatewayclass
```

## Cleanup

```bash
# Remove Gateway API resources
kubectl delete -f k8s/automated/generated-gateway.yaml
kubectl delete -f k8s/manual/

# Remove original Ingress
kubectl delete -f k8s/before-migration/

# Remove controllers (optional)
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
istioctl uninstall --purge -y
```

## Key Differences: Ingress vs Gateway API

| Aspect | Ingress | Gateway API |
|--------|---------|-------------|
| **Resources** | 1 (Ingress) | 3 (GatewayClass, Gateway, HTTPRoute) |
| **Ownership** | Coupled | Separated (infra vs app teams) |
| **Controller selection** | `ingressClassName` | GatewayClass `controllerName` |
| **TLS config** | In Ingress | In Gateway (listener level) |
| **Routing rules** | In Ingress | In HTTPRoute |
| **Extensibility** | Annotations | Native fields + policy attachment |

## Notes

- GatewayClass `controllerName` is **immutable** — delete/recreate to change
- HTTP→HTTPS redirect: use HTTPRoute with `RequestRedirect` filter
- For production: use proper TLS certificates (cert-manager recommended)ove deletes the ingress-nginx Service, causing brief downtime. In production, use this approach:

### DNS Cutover (Recommended for Production)

1. **Deploy Gateway API alongside Ingress** (both running)
   ```bash
   kubectl apply -f k8s/manual/01-gatewayclass.yaml
   kubectl apply -f k8s/manual/02-gateway.yaml
   kubectl apply -f k8s/manual/03-httproute.yaml
   kubectl apply -f k8s/manual/04-redirect-httproute.yaml
   ```

2. **Gateway gets its own LoadBalancer IP** (e.g., `34.123.45.67`)
   ```bash
   kubectl get gateway hello-gateway
   # Wait for ADDRESS to be assigned
   ```

3. **Test Gateway endpoint directly**
   ```bash
   curl -ik --resolve example.com:443:34.123.45.67 https://example.com/hello
   ```

4. **Update DNS to point to new LoadBalancer IP**
   - Change A record: `example.com` → `34.123.45.67` (Gateway IP)
   - Wait for DNS propagation (TTL)

5. **Monitor traffic shifting to Gateway API**
   ```bash
   kubectl logs -n istio-system -l app=istio-ingressgateway --tail=100 -f
   ```

6. **After all traffic migrated, remove old Ingress**
   ```bash
   kubectl delete -f k8s/before-migration/ingress.yaml
   kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
   ```

### Key Production Considerations

- **Test in staging first** with identical setup
- **Monitor metrics** (latency, error rates, throughput)
- **Have rollback plan** ready (revert DNS, keep old Ingress)
- **Gradual rollout** by service/namespace
- **Use proper TLS certificates** (not self-signed)
- **Update monitoring/alerting** for new Gateway metrics
- **Document runbook** for on-call team
