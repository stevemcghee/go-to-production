# HTTPS Setup for GKE Ingress

## Overview
This guide explains how to set up HTTPS for your application using GKE Ingress with Google-managed SSL certificates.

## Prerequisites
- A domain name you own (e.g., `example.com`)
- Access to your domain's DNS settings
- GKE cluster with the application deployed

## Step 1: Get the Ingress IP Address

After deploying the Ingress resource, get the assigned IP address:

```bash
kubectl get ingress todo-app-ingress
```

You'll see output like:
```
NAME               CLASS    HOSTS   ADDRESS        PORTS   AGE
todo-app-ingress   <none>   *       34.8.118.103   80      5m
```

**Note the ADDRESS** - this is your Ingress IP (e.g., `34.8.118.103`). You'll need this for DNS configuration.

## Step 2: Configure DNS

Add an A record in your DNS provider pointing your domain to the Ingress IP.

### Example DNS Configuration

If your domain is `example.com` and you want to use `todo.example.com`:

```
Type: A
Name: todo
Value: <YOUR_INGRESS_IP>  # e.g., 34.8.118.103
TTL: 300 (or automatic)
```

**Result**: `todo.example.com` will resolve to your Ingress IP address.

### Common DNS Providers

<details>
<summary>Google Cloud DNS</summary>

```bash
gcloud dns record-sets create todo.example.com. \
  --zone=<YOUR_ZONE> \
  --type=A \
  --ttl=300 \
  --rrdatas=<YOUR_INGRESS_IP>
```
</details>

<details>
<summary>Cloudflare</summary>

1. Go to DNS settings for your domain
2. Click "Add record"
3. Type: A
4. Name: todo
5. IPv4 address: <YOUR_INGRESS_IP>
6. Proxy status: DNS only (grey cloud)
7. TTL: Auto
</details>

<details>
<summary>Other Providers</summary>

Look for "DNS Management" or "DNS Records" in your provider's dashboard and add an A record as shown above.
</details>

## Step 3: Update ManagedCertificate Resource

Edit `k8s/managed-certificate.yaml` to use your domain:

```yaml
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: todo-app-cert
spec:
  domains:
    - todo.example.com  # Replace with YOUR domain
```

Apply the change:
```bash
kubectl apply -f k8s/managed-certificate.yaml
```

## Step 4: Verify DNS Propagation

Check that your DNS record is resolving correctly:

```bash
# Check DNS resolution
dig todo.example.com

# Should return your Ingress IP
# Or use nslookup
nslookup todo.example.com
```

**Expected output**: Should show your Ingress IP address (e.g., `34.8.118.103`)

DNS propagation typically takes **5-15 minutes** but can take up to 48 hours depending on your DNS provider and TTL settings.

## Step 5: Monitor Certificate Provisioning

Once DNS is configured and propagated, Google will automatically provision your SSL certificate.

### Check Certificate Status
```bash
kubectl get managedcertificate todo-app-cert
```

**Status progression**:
- `Provisioning` → Initial state, DNS verification in progress
- `Active` → Certificate ready, HTTPS working ✅

### Detailed Status
```bash
kubectl describe managedcertificate todo-app-cert
```

Look for the "Domain Status" section:
```yaml
Domain Status:
  Domain:  todo.example.com
  Status:  Active  # This means it's working!
```

**Timeline**: Certificate provisioning typically takes **10-60 minutes** after DNS is configured.

## Step 6: Test Your Setup

### Test HTTP (Available Immediately)
```bash
curl http://todo.example.com
# Or visit in browser
```

### Test HTTPS (After Certificate is Active)
```bash
curl https://todo.example.com
# Or visit in browser
```

## Troubleshooting

### Certificate Stuck in "Provisioning"

**Possible Causes**:
- DNS not configured or not propagated yet
- DNS pointing to wrong IP address
- Firewall blocking HTTP (port 80) for domain validation

**Solutions**:
1. Verify DNS: `dig todo.example.com` should return your Ingress IP
2. Wait for DNS propagation (can take up to 1 hour)
3. Ensure HTTP (port 80) is accessible

### Certificate Status "FailedNotVisible"

**Cause**: Google cannot reach your domain for validation

**Solutions**:
1. Verify DNS is pointing to the correct Ingress IP
2. Check Ingress is healthy: `kubectl get ingress`
3. Verify backend pods are running: `kubectl get pods`
4. Wait 15-30 minutes and check again (Google's validation can be slow)

### HTTP Works but HTTPS Doesn't

**Cause**: Certificate not yet active

**Solution**: Wait for certificate status to change to `Active` (10-60 minutes after DNS configuration)

### "SSL_ERROR_SYSCALL" or Certificate Errors

**Cause**: Certificate is still provisioning or not yet deployed

**Solution**: Check certificate status and wait for `Active` state

## Resources Created

This setup creates the following Kubernetes resources:

- **ManagedCertificate**: `todo-app-cert` - Manages SSL certificate provisioning
- **Ingress**: `todo-app-ingress` - GCP Load Balancer with HTTPS support
- **Service**: `todo-app-go-service` (NodePort) - Backend service

## Summary

1. ✅ Deploy Ingress and get IP address
2. ✅ Configure DNS A record: `todo.example.com` → `<INGRESS_IP>`
3. ✅ Update ManagedCertificate with your domain
4. ⏳ Wait for DNS propagation (5-15 minutes)
5. ⏳ Wait for certificate provisioning (10-60 minutes)
6. ✅ Access your app via HTTPS: `https://todo.example.com`

## Monitoring Certificate Progress

Watch the certificate status in real-time:
```bash
watch -n 10 'kubectl get managedcertificate todo-app-cert'
```

Or check detailed status periodically:
```bash
kubectl describe managedcertificate todo-app-cert | grep -A 5 "Domain Status"
```
