# Plane API Reference

**Base URL:** `http://localhost:8080/api/v1/`
**Swagger UI:** `http://localhost:8080/api/v1/schema/swagger-ui/`
**Auth:** `X-Api-Key: YOUR_API_TOKEN`
**Rate limit:** 60 req/min (regular), 300 req/min (service tokens)

## Authentication

Create API tokens in the Plane web UI: Workspace Settings > API Tokens.

```bash
curl -H "X-Api-Key: YOUR_TOKEN" http://localhost:8080/api/v1/users/me/
```

## Pagination

Cursor-based. Query params: `cursor`, `per_page`.

Response shape:
```json
{"results": [...], "next_cursor": "...", "prev_cursor": "...", "total_count": 42}
```

## Common Query Parameters

- `fields` — comma-separated fields to include
- `expand` — expand relations: `state`, `assignees`, `labels`, `project`, `created_by`
- `order_by` — prefix `-` for descending: `-created_at`, `priority`, `state__group`

## IMPORTANT: Use `/work-items/` not `/issues/`

The `/issues/` path is deprecated (EOL March 31, 2026). Use `/work-items/` everywhere.

## Endpoints

### User
```bash
GET  /api/v1/users/me/                                        # Current user
```

### Workspaces
```bash
GET  /api/v1/workspaces/                                      # List workspaces
GET  /api/v1/workspaces/{slug}/members/                       # List members
POST /api/v1/workspaces/{slug}/invitations/                   # Invite member
```

### Projects
```bash
GET  /api/v1/workspaces/{slug}/projects/                      # List
POST /api/v1/workspaces/{slug}/projects/                      # Create
GET  /api/v1/workspaces/{slug}/projects/{id}/                 # Get
PATCH /api/v1/workspaces/{slug}/projects/{id}/                # Update
DELETE /api/v1/workspaces/{slug}/projects/{id}/               # Delete
```

Create body:
```json
{"name": "My Project", "identifier": "MYPROJ", "description": "..."}
```

### Work Items (Issues)
```bash
GET  /api/v1/workspaces/{slug}/projects/{proj}/work-items/    # List (paginated)
POST /api/v1/workspaces/{slug}/projects/{proj}/work-items/    # Create
GET  /api/v1/workspaces/{slug}/projects/{proj}/work-items/{id}/ # Get
PATCH /api/v1/workspaces/{slug}/projects/{proj}/work-items/{id}/ # Update
DELETE /api/v1/workspaces/{slug}/projects/{proj}/work-items/{id}/ # Delete

# Human-readable lookup (PROJ-123)
GET  /api/v1/workspaces/{slug}/work-items/{PROJ}-{123}/

# Search
GET  /api/v1/workspaces/{slug}/work-items/search/?search=TEXT&limit=20
```

Create/Update body:
```json
{
  "name": "Fix the bug",
  "description_html": "<p>Details here</p>",
  "state": "uuid",
  "priority": "high",
  "assignees": ["uuid1", "uuid2"],
  "labels": ["uuid1"],
  "parent": "uuid",
  "start_date": "2026-04-01",
  "target_date": "2026-04-15"
}
```

Priority values: `urgent`, `high`, `medium`, `low`, `none`

### Comments
```bash
GET  .../work-items/{id}/comments/                            # List
POST .../work-items/{id}/comments/                            # Create
PATCH .../work-items/{id}/comments/{comment_id}/              # Update
DELETE .../work-items/{id}/comments/{comment_id}/             # Delete
```

Body: `{"comment_html": "<p>My comment</p>"}`

### Activities
```bash
GET  .../work-items/{id}/activities/                          # List (read-only)
```

### Links & Attachments
```bash
GET/POST .../work-items/{id}/links/                           # CRUD
GET/POST .../work-items/{id}/attachments/                     # CRUD
```

### States
```bash
GET  /api/v1/workspaces/{slug}/projects/{proj}/states/        # List
POST /api/v1/workspaces/{slug}/projects/{proj}/states/        # Create
PATCH /api/v1/workspaces/{slug}/projects/{proj}/states/{id}/  # Update
DELETE /api/v1/workspaces/{slug}/projects/{proj}/states/{id}/ # Delete
```

Body: `{"name": "In Review", "color": "#f59e0b", "group": "started"}`

Groups: `backlog`, `unstarted`, `started`, `completed`, `cancelled`

### Labels
```bash
GET/POST /api/v1/workspaces/{slug}/projects/{proj}/labels/
PATCH/DELETE .../labels/{id}/
```

Body: `{"name": "bug", "color": "#ef4444"}`

### Cycles (Sprints)
```bash
GET/POST /api/v1/workspaces/{slug}/projects/{proj}/cycles/
GET/PATCH/DELETE .../cycles/{id}/
GET/POST .../cycles/{id}/cycle-issues/                        # Add/list issues
DELETE .../cycles/{id}/cycle-issues/{issue_id}/               # Remove issue
POST .../cycles/{id}/transfer-issues/                         # Transfer incomplete
```

Create: `{"name": "Sprint 1", "start_date": "2026-04-01", "end_date": "2026-04-14"}`
Add issues: `{"issues": ["uuid1", "uuid2"]}`

### Modules
```bash
GET/POST /api/v1/workspaces/{slug}/projects/{proj}/modules/
GET/PATCH/DELETE .../modules/{id}/
GET/POST .../modules/{id}/module-issues/
DELETE .../modules/{id}/module-issues/{issue_id}/
```

### Project Members
```bash
GET/POST /api/v1/workspaces/{slug}/projects/{proj}/members/
PATCH/DELETE .../members/{id}/
```

Roles: `20` (admin), `15` (member), `5` (guest)

## Roles

| Value | Name |
|---|---|
| 20 | ADMIN |
| 15 | MEMBER |
| 5 | GUEST |
