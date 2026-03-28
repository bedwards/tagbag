# TagBag Unified Authentication

## Architecture: Gitea as Central Identity Provider

No external SSO (Authelia, Keycloak) needed. Gitea is already an OAuth2/OIDC provider.

```
                    ┌─────────────────┐
                    │     Gitea       │
                    │  OAuth2 / OIDC  │
                    │  Identity Hub   │
                    └──────┬──────────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
     ┌──────▼──────┐ ┌────▼─────┐ ┌──────▼───────┐
     │  Plane      │ │Woodpecker│ │  tagbag CLI  │
     │  OAuth2     │ │  OAuth2  │ │  PKCE flow   │
     │  (built-in) │ │(built-in)│ │              │
     └─────────────┘ └──────────┘ └──────────────┘
```

**Login flow:** User logs into Gitea once. OAuth2 redirects to Plane and Woodpecker are instant (no re-auth) because the Gitea session cookie is active.

## Gitea OIDC Endpoints

| Endpoint | URL |
|---|---|
| Discovery | `http://localhost:3000/.well-known/openid-configuration` |
| Authorize | `http://localhost:3000/login/oauth/authorize` |
| Token | `http://localhost:3000/login/oauth/access_token` |
| UserInfo | `http://localhost:3000/login/oauth/userinfo` |
| JWKS | `http://localhost:3000/login/oauth/keys` |

## Setup

### Step 1: Create OAuth2 Apps in Gitea

After first boot, create two OAuth2 apps at `http://localhost:3000/user/settings/applications`:

**Woodpecker:**
- Name: `Woodpecker`
- Redirect URI: `http://localhost:9080/authorize`
- Confidential: Yes

**Plane:**
- Name: `Plane`
- Redirect URI: `http://localhost:8080/auth/gitea/callback/`
- Confidential: Yes

**TagBag CLI (optional):**
- Name: `TagBag CLI`
- Redirect URI: `http://127.0.0.1/` (any loopback port)
- Confidential: No (public client, uses PKCE)

### Step 2: Configure Woodpecker

In `.env`:
```env
WOODPECKER_GITEA_CLIENT=<client-id>
WOODPECKER_GITEA_SECRET=<client-secret>
```

### Step 3: Configure Plane

In `plane.env`, add:
```env
GITEA_HOST=http://gitea:3000
GITEA_CLIENT_ID=<client-id>
GITEA_CLIENT_SECRET=<client-secret>
ENABLE_GITEA_SYNC=1
```

Or configure via Plane admin UI: `http://localhost:8080/god-mode/authentication/gitea/`

### Step 4: Restart
```bash
docker compose restart woodpecker-server plane-api
```

## CLI Unified Login

```bash
tagbag login
```

This opens a browser for Gitea OAuth2 login (PKCE flow), then stores tokens for all three services in `~/.config/tagbag/credentials.json`.

For manual token setup:
```bash
export GITEA_TOKEN="<gitea-personal-access-token>"
export PLANE_API_TOKEN="<plane-api-key>"
export WOODPECKER_TOKEN="<woodpecker-personal-token>"
```

## Plane's Built-in Gitea Support

The Plane fork already includes a Gitea OAuth provider:
- `apps/api/plane/authentication/provider/oauth/gitea.py` — OAuth2 flow
- `apps/api/plane/authentication/views/app/gitea.py` — Login/callback views
- `apps/admin/app/(all)/(dashboard)/authentication/gitea/form.tsx` — Admin config UI
- Scopes: `openid email profile`
- Supports `ENABLE_GITEA_SYNC` for syncing user data

## Automated Setup (via Gitea API)

```bash
# Create OAuth apps programmatically
curl -X POST "http://localhost:3000/api/v1/user/applications/oauth2" \
  -H "Authorization: token $GITEA_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Woodpecker","redirect_uris":["http://localhost:9080/authorize"],"confidential_client":true}'

curl -X POST "http://localhost:3000/api/v1/user/applications/oauth2" \
  -H "Authorization: token $GITEA_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Plane","redirect_uris":["http://localhost:8080/auth/gitea/callback/"],"confidential_client":true}'
```

## Token Types

| Token | Issued By | Used For | Lifetime |
|---|---|---|---|
| OAuth2 access token | Gitea | Delegated access, SSO flow | Short-lived |
| Gitea PAT | Gitea | Direct API access, scripts | Long-lived |
| Plane API key | Plane | Plane API access | Long-lived |
| Woodpecker PAT | Woodpecker | CI API access | Long-lived |

## Why No External SSO

- All three apps natively support Gitea OAuth2
- Proxy SSO (Authelia) adds latency and complexity
- Woodpecker requires forge-based OAuth (doesn't work with proxy auth)
- The OAuth2 redirect flow with an active Gitea session is already instant
