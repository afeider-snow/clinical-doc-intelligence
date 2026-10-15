# Document Classification and Routing

Before running extraction on a corpus of clinical documents, classify each document to route it to the right processing pipeline. A single-encounter office visit and a 300-page compiled patient history require fundamentally different architectures - sending both through the same pipeline wastes cost or loses accuracy.

Two approaches are provided depending on where you are in the pipeline:

| Option | Input | Cost | What it tells you |
|---|---|---|---|
| **Option 1: Page count metadata** | Raw PDF on stage | Zero AI credits (Python UDF only) | How large the document is. Drives the chunk-or-not decision. |
| **Option 2: AI_CLASSIFY** | Parsed text (post-OCR) | Minimal (lightweight text classification) | What type of document it is. Drives schema and pipeline selection. |

## Option 1: Page Count Metadata (Pre-Parse)

For scanned PDFs that haven't been parsed yet, a Python UDF reads page count directly from PDF metadata without any AI credits. This is the cheapest possible routing signal.

**Run:** `01_page_count_udf.sql`

The UDF reads the PDF header to extract page count - it does not parse, OCR, or read the document content. Cost is warehouse compute only.

Page count drives the most consequential routing decision:

```
page_count <= 20   →  Single-encounter. Send full document to AI_EXTRACT or AI_COMPLETE.
page_count > 20    →  Compiled chart. Needs chunking strategy before extraction.
```

The threshold is configurable. Adjust based on your document corpus.

### Limitation

Page count alone doesn't tell you *what* the document is - a 15-page lab bundle and a 15-page office visit are different document types that need different extraction schemas. For content-aware routing, combine with Option 2 after parsing.

## Option 2: AI_CLASSIFY (Post-Parse)

Once you have text (from `AI_PARSE_DOCUMENT`, Textract, or digital-born PDFs), classify the first ~2,000 characters to determine document type and route to the appropriate pipeline.

**Run:** `02_classify_and_route.sql`

### Document Categories and Routing

| Category | Routing implication |
|---|---|
| **Single-encounter note** (office visit, ER, discharge summary) | Full document to AI_EXTRACT - no chunking needed |
| **Compiled patient history** (multi-encounter, 100+ pages) | Chunking required, route to AI_COMPLETE pipeline |
| **Lab / pathology report** | Structured extraction with lab-specific schema |
| **Radiology / imaging report** | Targeted extraction - findings, impression, ordering provider |
| **Operative note** | Single-encounter but dense - may need procedure-specific prompt |
| **Administrative / billing** (EOB, claim form, prior auth) | Skip clinical extraction entirely |

These categories are a starting point. Adjust them based on the document types in your corpus.

### Why classify after parsing, not before?

There is no way today to send only the first few pages of a PDF to an AI function in Snowflake. Both `AI_PARSE_DOCUMENT` and `AI_COMPLETE` (file input) process the entire document. This means classification cannot serve as a cost-saving gate *before* the expensive parse step - you're paying for the full parse regardless.

Classification is most valuable as a routing step *after* you have text, to determine which extraction pipeline and schema to apply.

## Combining Both Options

The most practical pipeline uses both in sequence:

```
PDF on stage
  → get_page_count() .............. free, instant
      → short doc (≤20 pg) ........ AI_PARSE_DOCUMENT or AI_EXTRACT directly
      → long doc (>20 pg) ......... AI_PARSE_DOCUMENT → text
          → AI_CLASSIFY ........... route to correct pipeline
              → single-encounter .. full text to AI_COMPLETE
              → compiled chart .... chunk, then AI_COMPLETE per chunk
              → administrative .... skip extraction
              → lab/radiology ..... domain-specific schema
```

## Files

```
document_classification/
├── README.md                    # This file
├── 01_page_count_udf.sql       # Python UDF for PDF page count metadata
└── 02_classify_and_route.sql   # AI_CLASSIFY + routing logic
```

## Prerequisites

- A Snowflake stage with PDF documents
- `pypdf` package available in your Snowflake Python runtime (included in Snowflake Anaconda channel)
- `SNOWFLAKE.CORTEX_USER` database role for AI_CLASSIFY
