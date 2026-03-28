# Gitea CLI & API Reference

## Tea CLI

### Installation

```bash
brew install tea                    # macOS/Linux
go install code.gitea.io/tea@latest # or from source
```

### Configuration

```bash
tea login add --name=local --url=http://localhost:3000 --token=YOUR_TOKEN
tea login ls
tea login default local
tea whoami
```

### Command Tree

```
tea [--login NAME] [--repo OWNER/REPO] [--output table|json|csv|yaml] <command>

  issues (i)    list|create|edit|close|reopen
  pulls (pr)    list|create|close|reopen|checkout|merge|approve|reject|review|clean
  repos         list|search|create|create-from-template|fork|migrate|delete|edit
  labels        list|create|update|delete
  milestones    list|create|close|reopen|issues
  releases      list|create|edit|delete|assets
  branches      list|protect|unprotect
  times         list|add|delete|reset
  organizations list|create|delete
  actions       secrets|variables|runs|workflows
  webhooks      list|create|update|delete
  notifications list|read|unread|pin|unpin
  comment       INDEX --body TEXT
  open          (open repo in browser)
  clone         OWNER/REPO [PATH]
  admin         users (list|create|delete)
  api           METHOD ENDPOINT [BODY]
```

### Key Examples

```bash
# Issues
tea issues ls --state open --label bug
tea issues create --title "Fix login" --body "Details..." --label bug --assignee dev1

# Pull Requests
tea pr create --title "Feature X" --base main --head feature-x
tea pr checkout 42
tea pr merge 42 --style squash
tea pr approve 42

# Repos
tea repo create --name my-project --private --init
tea repo fork upstream/repo
tea clone owner/repo

# Releases
tea release create --tag v1.0.0 --title "v1.0.0" --note "Release notes"

# Actions
tea actions runs list
tea actions secrets add --name MY_SECRET --value "s3cr3t"

# Raw API
tea api GET /repos/owner/repo/branches
tea api POST /user/repos '{"name":"new-repo"}'
```

## REST API v1

**Base URL:** `http://localhost:3000/api/v1/`
**Swagger UI:** `http://localhost:3000/api/swagger`
**Auth:** `Authorization: token YOUR_TOKEN`

### Authentication

```bash
# Token auth (preferred)
curl -H "Authorization: token TOKEN" http://localhost:3000/api/v1/user

# Basic auth
curl -u user:password http://localhost:3000/api/v1/user

# Create a token
curl -X POST -u user:password -H "Content-Type: application/json" \
  -d '{"name":"my-token","scopes":["write:repository","write:issue"]}' \
  http://localhost:3000/api/v1/users/USER/tokens
```

### Token Scopes

| Scope | Covers |
|---|---|
| `read:repository` / `write:repository` | Repos, branches, content, tags, releases |
| `read:issue` / `write:issue` | Issues, PRs, labels, milestones |
| `read:organization` / `write:organization` | Orgs, teams, members |
| `read:user` / `write:user` | User profile, settings |
| `write:admin` | Site admin |

### Key Endpoints

**Repos:**
```bash
GET    /repos/search?q=QUERY
GET    /repos/{owner}/{repo}
POST   /user/repos                    # create
POST   /orgs/{org}/repos              # create under org
PATCH  /repos/{owner}/{repo}          # update
DELETE /repos/{owner}/{repo}
POST   /repos/{owner}/{repo}/forks
POST   /repos/migrate                 # mirror external repo
```

**Pull Requests:**
```bash
GET    /repos/{owner}/{repo}/pulls?state=open
GET    /repos/{owner}/{repo}/pulls/{index}
POST   /repos/{owner}/{repo}/pulls    # create
PATCH  /repos/{owner}/{repo}/pulls/{index}
POST   /repos/{owner}/{repo}/pulls/{index}/merge  # {"Do":"squash"}
POST   /repos/{owner}/{repo}/pulls/{index}/reviews # {"event":"APPROVED"}
POST   /repos/{owner}/{repo}/pulls/{index}/requested_reviewers
GET    /repos/{owner}/{repo}/pulls/{index}/commits
GET    /repos/{owner}/{repo}/pulls/{index}/files
```

**Issues:**
```bash
GET    /repos/{owner}/{repo}/issues?state=open&type=issues
POST   /repos/{owner}/{repo}/issues
PATCH  /repos/{owner}/{repo}/issues/{index}
POST   /repos/{owner}/{repo}/issues/{index}/comments
POST   /repos/{owner}/{repo}/issues/{index}/labels
```

**Branch Protection:**
```bash
POST   /repos/{owner}/{repo}/branch_protections
# Body: {branch_name, required_approvals, enable_status_check, status_check_contexts, ...}
```

**Webhooks:**
```bash
POST   /repos/{owner}/{repo}/hooks
# Body: {type:"gitea", config:{url,content_type,secret}, events:["push","pull_request"]}
```

**File Operations:**
```bash
GET    /repos/{owner}/{repo}/contents/{path}?ref=main
POST   /repos/{owner}/{repo}/contents/{path}     # create file
PUT    /repos/{owner}/{repo}/contents/{path}      # update file
DELETE /repos/{owner}/{repo}/contents/{path}      # delete file
```

**OAuth2 (Gitea as identity provider):**
```bash
POST   /user/applications/oauth2      # create OAuth app
# OIDC discovery: /.well-known/openid-configuration
# Authorize: /login/oauth/authorize?client_id=...&redirect_uri=...&response_type=code
# Token: POST /login/oauth/access_token
```

**Admin:**
```bash
GET    /admin/users
POST   /admin/users
PATCH  /admin/users/{username}
DELETE /admin/users/{username}
POST   /admin/actions/runners/registration-token
```

### Pagination

All list endpoints support `?page=N&limit=N`. Response headers include `X-Total-Count` and `Link` with `rel="next"`.
