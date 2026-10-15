# CVC ICD Explorer v2

A full-stack web application for searching ICD codes using free clinical language.  
Runs **alongside** the existing R Shiny app — no changes required to that app.

---

## What It Does

Type a clinical description (e.g. *"ST-elevation myocardial infarction"*) and get results in two panels simultaneously:

| Left Panel | Right Panel |
|---|---|
| **CVC Case Definitions** — matches from your curated `backupfile.xlsx` (Condition, Case Definition, ICD-10, ICD-9, CCI, ATC, Labs) | **Full ICD Universe** — live results from WHO ICD-11 API + NLM ICD-10-CM API |

Results can be downloaded as a formatted two-sheet Excel file.

---

## Architecture

```
React Frontend (port 5173)
       │  GET /api/search?q=...
       ▼
FastAPI Backend (port 8000)
  ┌────┴──────────────────────────────┐
  │  CVC Dataset     WHO ICD-11 API   NLM ICD-10-CM API
  │  (in-memory,     (OAuth2,         (no auth,
  │   from GitHub)    free)            free)
  └───────────────────────────────────┘
```

---

## Prerequisites

- Python 3.9+
- Node.js 18+ (use [nvm](https://github.com/nvm-sh/nvm) if needed)
- A WHO ICD API account (free — see below)
- A GitHub Personal Access Token with `repo:read` scope (to fetch `backupfile.xlsx`)

---

## Setup

### 1. WHO ICD-11 API credentials

1. Register at https://icd.who.int/icdapi
2. Log in → click **"View API access key"**
3. Copy your **Client ID** and **Client Secret**

### 2. Backend

```bash
cd cvc-explorer-v2/backend

# Copy and fill in credentials
cp ../.env.example .env
# Edit .env:
#   WHO_CLIENT_ID=your-client-id
#   WHO_CLIENT_SECRET=your-client-secret
#   GITHUB_PAT=your-github-pat

pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

The backend fetches `backupfile.xlsx` from GitHub on startup. Check the logs for:
```
INFO: CVC dataset loaded: N rows
INFO: Startup complete.
```

### 3. Frontend

```bash
cd cvc-explorer-v2/frontend
npm install
npm run dev
```

Open http://localhost:5173

The Vite dev server proxies `/api/*` to `http://localhost:8000` automatically — no CORS issues in development.

---

## Running Tests

### Backend (pytest)

```bash
cd cvc-explorer-v2/backend
python -m pytest -v
```

Expected: **21 passed**

### Frontend (Vitest)

```bash
cd cvc-explorer-v2/frontend
npm test
```

Expected: **27 passed**

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/healthz` | Health check |
| GET | `/api/cvc/search?q=` | Search CVC curated dataset |
| GET | `/api/who/search?q=` | Search WHO ICD-11 |
| GET | `/api/nlm/search?q=` | Search NLM ICD-10-CM |
| GET | `/api/search?q=` | Unified parallel search (all sources) |

Interactive API docs: http://localhost:8000/docs

---

## Deployment Alongside the Shiny App

The v2 app runs on separate ports and is completely independent:

| Service | Port | Notes |
|---------|------|-------|
| R Shiny app | 3838 (or shinyapps.io) | Unchanged |
| FastAPI backend | 8000 | `uvicorn main:app --port 8000` |
| React frontend | 5173 (dev) / 4173 (preview) | `npm run build && npm run preview` |

For production, build the React app and serve from a web server or CDN:
```bash
cd frontend
npm run build          # outputs to frontend/dist/
```

Set `VITE_API_BASE_URL=https://your-api-domain.com` in `frontend/.env` before building.

---

## Existing Shiny App — Secret Management Fix

The existing `app.R` contains a hardcoded GitHub PAT. To remove it safely:

1. Create a `.Renviron` file in the project root (never commit this):
   ```
   GITHUB_PAT=your-github-pat-here
   ```

2. In `app.R`, the line is already correct:
   ```r
   my_token <- Sys.getenv("GITHUB_PAT")
   ```

3. Restart the R session so `.Renviron` is loaded.

4. Add `.Renviron` to `.gitignore` and remove the old hardcoded token from git history:
   ```bash
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch app.R" HEAD
   ```
   Then commit a clean `app.R` with only `Sys.getenv("GITHUB_PAT")`.

> ⚠️ The token in the current `app.R` (`ghp_PSZFt...`) should be revoked at  
> https://github.com/settings/tokens and replaced with a new one.

---

## Project Structure

```
cvc-explorer-v2/
├── .env.example          # Template for secrets
├── .gitignore
├── README.md
├── backend/
│   ├── main.py           # FastAPI app + all routes
│   ├── config.py         # Settings from .env
│   ├── cvc_loader.py     # GitHub fetch + in-memory search
│   ├── who_client.py     # WHO ICD-11 OAuth2 client
│   ├── nlm_client.py     # NLM ICD-10-CM client
│   ├── requirements.txt
│   ├── pytest.ini
│   └── tests/
│       ├── test_cvc_loader.py
│       ├── test_clients.py
│       └── test_unified_search.py
└── frontend/
    ├── vite.config.ts    # Vite + proxy config
    ├── src/
    │   ├── App.tsx        # Main app shell
    │   ├── components/
    │   │   ├── Navbar.tsx
    │   │   ├── CvcPanel.tsx   # Left panel
    │   │   ├── IcdPanel.tsx   # Right panel
    │   │   └── Skeleton.tsx
    │   ├── hooks/
    │   │   └── useDebounce.ts
    │   ├── utils/
    │   │   ├── api.ts         # Axios API calls
    │   │   └── export.ts      # xlsx export
    │   ├── types/
    │   │   └── api.ts         # TypeScript types
    │   └── test/
    │       ├── App.test.tsx
    │       ├── CvcPanel.test.tsx
    │       ├── IcdPanel.test.tsx
    │       └── useDebounce.test.ts
    └── package.json
```
