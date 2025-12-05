# Milestone 5: Security Hardening

This document outlines the implementation of defense-in-depth security measures, including WAF, HTTPS, and CSP.

## 1. Checkout this Milestone

To deploy this version of the infrastructure:

```bash
git checkout tags/milestone-security-hardening
```

## 2. What was Implemented?

We moved beyond basic identity security to network and application hardening.

**Key Features:**
*   **Cloud Armor WAF**: Web Application Firewall rules to block SQL injection and XSS attacks.
    *   *Benefit*: Protects against common OWASP Top 10 vulnerabilities.
*   **HTTPS (Managed SSL)**: GKE Ingress with Google-managed SSL certificates.
    *   *Benefit*: Encrypted traffic in transit without managing certificate rotation.
*   **Content Security Policy (CSP)**: Strict HTTP headers to prevent malicious script execution.
    *   *Benefit*: Mitigates XSS attacks even if the WAF misses something.
*   **Vulnerability Scanning**: `gosec` and `trivy` added to CI/CD.
    *   *Benefit*: Shifts security left, catching vulnerabilities before deployment.

## 3. Pitfalls & Considerations

*   **WAF False Positives**: Aggressive WAF rules can block legitimate traffic. We started in "preview mode" (logging only) before enforcing.
*   **CSP Complexity**: Getting CSP right is hard. We had to carefully allow specific fonts and styles while blocking everything else.
*   **Ingress Latency**: Provisioning a Google-managed SSL certificate can take 10-20 minutes initially.

## 4. Alternatives Considered

*   **Cert-Manager**: Using Let's Encrypt with `cert-manager`.
    *   *Why Managed SSL?* Google-managed certs are simpler for GKE Ingress and require no in-cluster components to maintain.
*   **Nginx Ingress**: Using Nginx as the ingress controller.
    *   *Why GKE Ingress?* Native integration with Google Cloud Armor and Load Balancing.

## Implementation Details

For specific setup instructions on HTTPS, see [HTTPS Setup](HTTPS_SETUP.md).
