#!/usr/bin/env bash
# scripts/setup-plane.sh — Automate Plane first-time setup via manage.py + API
# Idempotent: safe to run multiple times.
set -euo pipefail

PLANE_URL="${PLANE_URL:-http://localhost:8080}"
ADMIN_EMAIL="${PLANE_ADMIN_EMAIL:-admin@tagbag.local}"
ADMIN_PASSWORD="${PLANE_ADMIN_PASSWORD:-Tagbag!Secure123}"
ADMIN_FIRST_NAME="${PLANE_ADMIN_FIRST_NAME:-TagBag}"
ADMIN_LAST_NAME="${PLANE_ADMIN_LAST_NAME:-Admin}"
COMPANY_NAME="${PLANE_COMPANY_NAME:-TagBag}"
WORKSPACE_NAME="${PLANE_WORKSPACE_NAME:-TagBag}"
WORKSPACE_SLUG="${PLANE_WORKSPACE_SLUG:-tagbag}"
PROJECT_NAME="${PLANE_PROJECT_NAME:-TagBag}"
PROJECT_IDENTIFIER="${PLANE_PROJECT_IDENTIFIER:-TAGBA}"

COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

# Helper: run manage.py inside the plane-api container
plane_manage() {
  docker compose exec -T plane-api python manage.py "$@"
}

# Helper: run Django shell one-liner
plane_shell() {
  docker compose exec -T plane-api python manage.py shell -c "$1"
}

# Helper: curl with cookie jar (no redirect following — Plane returns 302 on success)
api() {
  local method="$1"; shift
  local path="$1"; shift
  curl -s -S \
    -X "$method" \
    -b "$COOKIE_JAR" \
    -c "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    "$@" \
    "${PLANE_URL}${path}"
}

echo "=== Plane First-Time Setup ==="
echo ""

# ---------------------------------------------------------------
# Step 1: Register the instance (idempotent)
# ---------------------------------------------------------------
echo "[1/7] Registering Plane instance..."
plane_manage register_instance "tagbag-local" 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------
# Step 2: Configure instance variables (idempotent)
# ---------------------------------------------------------------
echo "[2/7] Configuring instance..."
plane_manage configure_instance 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------
# Step 3: Create admin user via manage.py (idempotent)
# ---------------------------------------------------------------
echo "[3/7] Creating admin user..."

plane_shell "
from plane.db.models import User, Profile
from plane.license.models import Instance, InstanceAdmin
from django.contrib.auth.hashers import make_password

email = '${ADMIN_EMAIL}'
password = '${ADMIN_PASSWORD}'
first_name = '${ADMIN_FIRST_NAME}'
last_name = '${ADMIN_LAST_NAME}'
company_name = '${COMPANY_NAME}'

# Create or update user
user, created = User.objects.get_or_create(
    email=email,
    defaults={
        'first_name': first_name,
        'last_name': last_name,
        'username': email.split('@')[0],
        'password': make_password(password),
        'is_password_autoset': False,
        'is_active': True,
    }
)
if created:
    print(f'  User created: {email}')
else:
    print(f'  User already exists: {email}')
    # Ensure password is set correctly
    if not user.check_password(password):
        user.password = make_password(password)
        user.save()
        print('  Password updated.')

# Ensure profile exists
Profile.objects.get_or_create(user=user, defaults={'company_name': company_name})

# Ensure instance admin
inst = Instance.objects.first()
admin, admin_created = InstanceAdmin.objects.get_or_create(
    instance=inst, user=user, defaults={'role': 20}
)
if admin_created:
    print('  Instance admin created.')
else:
    print('  Instance admin already exists.')

# Mark setup done
if not inst.is_setup_done:
    inst.is_setup_done = True
    inst.instance_name = company_name
    inst.is_telemetry_enabled = False
    inst.save()
    print('  Instance marked as setup done.')
else:
    print('  Instance already set up.')
" 2>&1

# ---------------------------------------------------------------
# Step 4: Sign in as admin to get session cookies
# ---------------------------------------------------------------
echo "[4/7] Signing in as admin..."

# Get CSRF token
curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" "${PLANE_URL}/auth/get-csrf-token/" > /dev/null 2>&1
CSRF_TOKEN=$(grep -i csrftoken "$COOKIE_JAR" 2>/dev/null | awk '{print $NF}' || echo "")

# Sign in (form POST, don't follow redirect — 302 = success)
SIGNIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -c "$COOKIE_JAR" \
  -b "$COOKIE_JAR" \
  -H "X-CSRFToken: $CSRF_TOKEN" \
  -d "email=${ADMIN_EMAIL}&password=${ADMIN_PASSWORD}&medium=email" \
  "${PLANE_URL}/auth/sign-in/")

if [ "$SIGNIN_CODE" = "302" ]; then
  echo "  Signed in successfully (302 redirect)."
else
  echo "  WARNING: Sign-in returned HTTP $SIGNIN_CODE (expected 302)."
fi

# Verify session works
ME_RESPONSE=$(api GET "/api/users/me/" 2>/dev/null || echo '{}')
MY_EMAIL=$(echo "$ME_RESPONSE" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('email', ''))
except:
    print('')
" 2>/dev/null || echo "")

if [ -z "$MY_EMAIL" ]; then
  echo "  ERROR: Could not authenticate. Aborting."
  echo "  Response: $ME_RESPONSE"
  exit 1
fi
echo "  Authenticated as: $MY_EMAIL"

# ---------------------------------------------------------------
# Step 5: Create workspace (idempotent)
# ---------------------------------------------------------------
echo "[5/7] Creating workspace '${WORKSPACE_SLUG}'..."

EXISTING_WS=$(api GET "/api/users/me/workspaces/" 2>/dev/null || echo '[]')
WS_EXISTS=$(echo "$EXISTING_WS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    workspaces = data if isinstance(data, list) else data.get('results', [])
    print('true' if any(w.get('slug') == '${WORKSPACE_SLUG}' for w in workspaces) else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")

if [ "$WS_EXISTS" = "true" ]; then
  echo "  Workspace '${WORKSPACE_SLUG}' already exists."
else
  WS_RESULT=$(api POST "/api/workspaces/" \
    -d "{\"name\": \"${WORKSPACE_NAME}\", \"slug\": \"${WORKSPACE_SLUG}\", \"company_size\": \"1-10\"}")
  WS_ID=$(echo "$WS_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', ''))" 2>/dev/null || echo "")
  if [ -n "$WS_ID" ]; then
    echo "  Workspace created: id=$WS_ID"
  else
    echo "  WARNING: Workspace creation response: $WS_RESULT"
  fi
fi

# ---------------------------------------------------------------
# Step 6: Create project with identifier TAGBAG (idempotent)
# ---------------------------------------------------------------
echo "[6/7] Creating project '${PROJECT_NAME}' (${PROJECT_IDENTIFIER})..."

EXISTING_PROJ=$(api GET "/api/workspaces/${WORKSPACE_SLUG}/projects/" 2>/dev/null || echo '[]')
PROJ_EXISTS=$(echo "$EXISTING_PROJ" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    projects = data if isinstance(data, list) else data.get('results', [])
    print('true' if any(p.get('identifier') == '${PROJECT_IDENTIFIER}' for p in projects) else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")

if [ "$PROJ_EXISTS" = "true" ]; then
  echo "  Project '${PROJECT_IDENTIFIER}' already exists."
else
  PROJ_RESULT=$(api POST "/api/workspaces/${WORKSPACE_SLUG}/projects/" \
    -d "{\"name\": \"${PROJECT_NAME}\", \"identifier\": \"${PROJECT_IDENTIFIER}\", \"description\": \"Main TagBag project\", \"network\": 2}")
  PROJ_ID=$(echo "$PROJ_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', ''))" 2>/dev/null || echo "")
  if [ -n "$PROJ_ID" ]; then
    echo "  Project created: id=$PROJ_ID"
  else
    # Check if it's a "already exists" error
    ALREADY=$(echo "$PROJ_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    errs = str(d)
    print('true' if 'ALREADY_EXIST' in errs else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")
    if [ "$ALREADY" = "true" ]; then
      echo "  Project '${PROJECT_IDENTIFIER}' already exists (different workspace)."
    else
      echo "  WARNING: Project creation response: $PROJ_RESULT"
    fi
  fi
fi

# ---------------------------------------------------------------
# Step 7: Generate API token (idempotent)
# ---------------------------------------------------------------
echo "[7/7] Generating API token..."

EXISTING_TOKENS=$(api GET "/api/users/api-tokens/" 2>/dev/null || echo '[]')
TOKEN_EXISTS=$(echo "$EXISTING_TOKENS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tokens = data if isinstance(data, list) else data.get('results', [])
    print('true' if any(t.get('label') == 'tagbag-cli' for t in tokens) else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")

if [ "$TOKEN_EXISTS" = "true" ]; then
  echo "  API token 'tagbag-cli' already exists."
  echo "  (Token value is only shown at creation time.)"
else
  TOKEN_RESULT=$(api POST "/api/users/api-tokens/" \
    -d "{\"label\": \"tagbag-cli\", \"description\": \"CLI and automation token for TagBag\"}")
  API_TOKEN=$(echo "$TOKEN_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('token', ''))" 2>/dev/null || echo "")

  if [ -n "$API_TOKEN" ]; then
    echo "  API token created: $API_TOKEN"
    echo ""
    echo "  >>> Save this token! It will not be shown again. <<<"
    echo "  Add to your .env:  PLANE_API_TOKEN=$API_TOKEN"
  else
    echo "  WARNING: Token creation response: $TOKEN_RESULT"
  fi
fi

echo ""
echo "=== Plane Setup Complete ==="
echo "  Admin:     $ADMIN_EMAIL"
echo "  Workspace: $PLANE_URL/$WORKSPACE_SLUG"
echo "  Project:   $PLANE_URL/$WORKSPACE_SLUG/projects/ (identifier: $PROJECT_IDENTIFIER)"
echo "  God Mode:  $PLANE_URL/god-mode/"
echo ""
