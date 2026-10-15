# Clinical Document Intelligence with Snowflake Cortex AI

Automated extraction and human review of clinical documents for risk adjustment workflows, powered by Snowflake Cortex AI functions with pixel-accurate visual annotation.

## Overview

This solution extracts structured clinical fields from PDF documents using `AI_COMPLETE`, resolves bounding box coordinates using open-source Python libraries (`pypdfium2` for digital PDFs, `EasyOCR` for scanned/faxed documents), and presents results in a Streamlit App for manual review. AI Function Studio optimization identified prompt and model tactics that boosted accuracy from 77.8% to 83.0% while reducing per-document cost by 56%.

## Architecture

The pipeline processes clinical documents through three stages:

1. **Semantic Extraction** — A Custom AI Function (`CREATE AI FUNCTION`) wraps `AI_COMPLETE` with `PROMPT()` + `TO_FILE()` to read PDFs natively and extract 12 structured fields with confidence, rationale, and evidence metadata.
2. **Bounding Box Resolution** — `pypdfium2` text-layer search for digital PDFs; `EasyOCR` word detection for scanned/faxed documents. Only pages where AI identified fields are processed.
3. **Human Review** — Streamlit app with confidence-colored overlays, per-field rationale, and optional Cortex Search for ad-hoc Q&A.

## Repository Structure

```
├── sql/
│   ├── 01_tables_and_stage.sql          # Tables, stage, Cortex Search service
│   ├── 02_ai_function_and_prompt.sql    # CREATE AI FUNCTION + extraction prompt
│   ├── 03_bounding_box_resolution.sql   # pypdfium2 + EasyOCR stored procedures
│   ├── 04_cortex_search.sql             # Document page population for search
│   └── 05_evaluation_and_optimization.sql # AI Function evaluation + optimization
├── document_classification/
│   ├── README.md                        # Document routing guide
│   ├── 01_page_count_udf.sql           # Python UDF for PDF page count metadata
│   └── 02_classify_and_route.sql       # AI_CLASSIFY + routing logic
├── streamlit/
│   ├── streamlit_app.py                 # Human review app (Streamlit in Snowflake)
│   ├── environment.yml                  # Conda dependencies for SiS
│   └── snowflake.yml                    # Snowflake CLI deployment config
├── docs/
│   ├── clinical_doc_intelligence.html   # Full technical writeup
│   └── evaluation_and_optimization.md   # Evaluation + optimization guide
└── README.md
```

## Setup

### Prerequisites

- Snowflake account with Cortex AI functions enabled
- A warehouse (e.g., `COMPUTE_WH`)
- Python packages available in Snowflake: `pypdfium2`, `easyocr`

### Configuration

The SQL scripts use placeholder references that you need to replace with your own database and schema:

| Placeholder | Replace with |
|---|---|
| `<YOUR_DATABASE>` | Your database name |
| `<YOUR_SCHEMA>` | Your schema name |
| `<YOUR_WAREHOUSE>` | Your warehouse name |
| `<YOUR_STAGE>` | Your internal stage name |

### Steps

1. Run `sql/01_tables_and_stage.sql` to create tables, stage, and Cortex Search service
2. Upload PDFs to your stage: `PUT file:///path/to/pdfs/*.pdf @<YOUR_STAGE> AUTO_COMPRESS = FALSE`
3. Upload EasyOCR models: `PUT file:///path/to/easyocr_models/*.pth @<YOUR_STAGE>/easyocr_models/ AUTO_COMPRESS = FALSE`
4. Run `sql/02_ai_function_and_prompt.sql` to create the extraction function
5. Run `sql/03_bounding_box_resolution.sql` to create bounding box procedures
6. Run `sql/04_cortex_search.sql` to populate the search corpus
7. Run `sql/05_evaluation_and_optimization.sql` to evaluate and optimize extraction quality
8. Deploy the Streamlit app: `snow streamlit deploy` from the `streamlit/` directory (or upload via Snowsight)

## Document Routing

Before running extraction, classify each document to route it to the right processing pipeline. See DOCCLASSIFY_README.md for two approaches:

- **Option 1: Page count metadata** — Python UDF reads PDF header for page count (zero AI credits). Drives the chunk-or-not decision.
- **Option 2: AI_CLASSIFY** — Classifies parsed text into clinical document types (single-encounter, compiled history, lab, radiology, etc.) to select the right extraction schema and pipeline.

## Test Dataset

This solution was prototyped using the [JohnSnowLabs PDF De-identification Dataset](https://github.com/JohnSnowLabs/pdf-deid-dataset/tree/main) — a collection of 50 synthetic clinical documents across three complexity tiers (Easy, Medium, Hard) designed for clinical NLP research. The documents simulate real-world clinical formats including progress notes, discharge summaries, and procedure reports with varying levels of scan quality and structural complexity.

**Citation:**
```
JohnSnowLabs. (2024). PDF De-identification Dataset.
https://github.com/JohnSnowLabs/pdf-deid-dataset
```

## Key Results

| Metric | Baseline (claude-sonnet-4-6) | Optimized (gemini-2.5-flash, ITER_48) |
|---|---|---|
| Quality Score | 77.8% | 83.0% (+6.7%) |
| Credits / Document | 0.068 | 0.030 (-56%) |
| 60K Documents | 4,080 credits | 1,800 credits |

## Documentation

See `docs/clinical_doc_intelligence.html` for the full technical writeup covering:
- Extraction field schema (PII, risk adjustment, clinical reasoning)
- Human review workflow with triage logic
- AI Function evaluation and optimization results
- AI_EXTRACT vs AI_COMPLETE comparison
- Chunking strategies for large documents (extraction vs retrieval)

## License

This project is provided as-is for educational and prototyping purposes.
