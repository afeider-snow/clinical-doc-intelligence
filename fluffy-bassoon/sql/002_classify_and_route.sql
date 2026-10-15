-- =============================================================================
-- Document Classification - Option 2: AI_CLASSIFY + Routing
-- =============================================================================
-- Classifies parsed document text into clinical document types and routes
-- each to the appropriate extraction pipeline.
-- Prerequisite: documents must already be parsed to text (via AI_PARSE_DOCUMENT,
-- Textract, or digital-born PDF text extraction).
-- =============================================================================

USE DATABASE <YOUR_DATABASE>;
USE SCHEMA <YOUR_SCHEMA>;

-- -----------------------------------------------------------------------------
-- 1. Classify Documents by Type
-- -----------------------------------------------------------------------------
-- Uses AI_CLASSIFY on the first ~2,000 characters of parsed text.
-- Assumes a table with document text already available.

-- If your text comes from AI_PARSE_DOCUMENT:
--   SELECT AI_PARSE_DOCUMENT(@<YOUR_STAGE>, relative_path,
--          {'mode': 'OCR'}):content::STRING AS doc_text
--   FROM DIRECTORY(@<YOUR_STAGE>) WHERE relative_path LIKE '%.pdf';

SELECT
    document_id,
    AI_CLASSIFY(
        LEFT(doc_text, 2000),
        [
            'single-encounter note',
            'compiled patient history',
            'lab report',
            'radiology report',
            'operative note',
            'administrative/billing'
        ]
    ) AS doc_type
FROM parsed_documents;

-- -----------------------------------------------------------------------------
-- 2. Classify + Route in One Query
-- -----------------------------------------------------------------------------
-- Combines classification with routing logic to determine the extraction
-- pipeline for each document.

SELECT
    document_id,
    AI_CLASSIFY(
        LEFT(doc_text, 2000),
        [
            'single-encounter note',
            'compiled patient history',
            'lab report',
            'radiology report',
            'operative note',
            'administrative/billing'
        ]
    ) AS doc_type,
    CASE doc_type
        WHEN 'single-encounter note'
            THEN 'full-doc-extraction'       -- Send full document to AI_EXTRACT or AI_COMPLETE
        WHEN 'compiled patient history'
            THEN 'chunk-then-extract'        -- Chunk first, then AI_COMPLETE per chunk
        WHEN 'lab report'
            THEN 'lab-schema-extraction'     -- Lab-specific extraction schema
        WHEN 'radiology report'
            THEN 'radiology-schema-extraction' -- Radiology-specific extraction
        WHEN 'operative note'
            THEN 'procedure-extraction'      -- Procedure-specific prompt
        WHEN 'administrative/billing'
            THEN 'skip'                      -- No clinical extraction needed
        ELSE 'full-doc-extraction'           -- Default fallback
    END AS pipeline
FROM parsed_documents;

-- -----------------------------------------------------------------------------
-- 3. Combined Pipeline: Page Count + Classification
-- -----------------------------------------------------------------------------
-- Uses the page count UDF (from 01_page_count_udf.sql) as a first-pass filter,
-- then AI_CLASSIFY for content-aware routing on parsed text.
--
-- Assumes:
--   - GET_PAGE_COUNT UDF exists (from 01_page_count_udf.sql)
--   - Documents have been parsed to text in a PARSED_DOCUMENTS table

WITH page_counts AS (
    SELECT
        relative_path,
        GET_PAGE_COUNT(BUILD_SCOPED_FILE_URL(@<YOUR_STAGE>, relative_path)) AS page_count
    FROM DIRECTORY(@<YOUR_STAGE>)
    WHERE relative_path LIKE '%.pdf'
),
classified AS (
    SELECT
        p.relative_path,
        pc.page_count,
        CASE
            WHEN pc.page_count <= 20 THEN 'short'
            ELSE 'long'
        END AS length_category,
        AI_CLASSIFY(
            LEFT(p.doc_text, 2000),
            [
                'single-encounter note',
                'compiled patient history',
                'lab report',
                'radiology report',
                'operative note',
                'administrative/billing'
            ]
        ) AS doc_type
    FROM parsed_documents p
    JOIN page_counts pc ON p.relative_path = pc.relative_path
)
SELECT
    relative_path,
    page_count,
    length_category,
    doc_type,
    CASE
        WHEN doc_type = 'administrative/billing'
            THEN 'skip'
        WHEN length_category = 'short'
            THEN 'full-doc-extraction'
        WHEN length_category = 'long' AND doc_type = 'compiled patient history'
            THEN 'chunk-then-extract'
        WHEN length_category = 'long'
            THEN 'chunk-then-extract'
        ELSE 'full-doc-extraction'
    END AS pipeline
FROM classified
ORDER BY page_count DESC;
