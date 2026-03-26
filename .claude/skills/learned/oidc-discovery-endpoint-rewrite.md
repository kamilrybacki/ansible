---
name: oidc-discovery-endpoint-rewrite
description: "When patching OIDC discovery for internal Docker networking, rewrite ALL endpoint URLs, not just issuer"
user-invocable: false
origin: auto-extracted
---

# OIDC Discovery Document — Rewrite All Endpoint URLs

**Extracted:** 2026-03-26
**Context:** Docker containers fetching OIDC discovery from an internal IdP (e.g., Authelia) while browsers need external URLs

## Problem
When a service (e.g., Nexterm) fetches the OIDC `.well-known/openid-configuration` document from an internal Docker address (`http://authelia:9091`), the discovery JSON contains internal URLs for all endpoints (`authorization_endpoint`, `token_endpoint`, `jwks_uri`, etc.). If you only rewrite the `issuer` field to the external origin, the browser still gets redirected to the internal `authorization_endpoint` URL — which is unresolvable outside Docker.

Symptom: browser navigates to `http://authelia:9091/api/oidc/authorization?...` → DNS resolution failure.

## Solution
When patching the discovery response, rewrite ALL string values that start with the internal origin to the external origin:

```javascript
const externalOrigin = 'https://' + authHost;
const internalOrigin = internalBase.origin;
for (const key of Object.keys(json)) {
    if (typeof json[key] === 'string' && json[key].startsWith(internalOrigin)) {
        json[key] = json[key].replace(internalOrigin, externalOrigin);
    }
}
```

This catches `authorization_endpoint`, `token_endpoint`, `userinfo_endpoint`, `jwks_uri`, `revocation_endpoint`, and any future endpoints without maintaining an explicit list.

## When to Use
- Patching OIDC discovery for services running in Docker that talk to an internal IdP
- Any `patchedFetch` / discovery proxy that rewrites OIDC metadata
- Symptom: browser redirect goes to an internal hostname after OIDC login initiation
