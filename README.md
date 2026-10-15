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

