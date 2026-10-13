-- =============================================================================
-- Clinical Document Intelligence Pipeline
-- Script 1: Tables, Stage, and Cortex Search Service
-- =============================================================================
-- Database: <YOUR_DATABASE> | Schema: <YOUR_SCHEMA> | Warehouse: <YOUR_WAREHOUSE>
-- =============================================================================

USE DATABASE <YOUR_DATABASE>;
USE SCHEMA <YOUR_SCHEMA>;
USE WAREHOUSE <YOUR_WAREHOUSE>;

-- -----------------------------------------------------------------------------
-- 1. Internal Stage for PDFs and EasyOCR Models
-- -----------------------------------------------------------------------------
-- PDF_STAGE holds:
--   - 50 clinical PDF documents (Easy_*, Medium_*, Hard_* tiers)
--   - EasyOCR model weights at /easyocr_models/ subdirectory:
--       craft_mlt_25k.pth, english_g2.pth, latin.pth
--   - Streamlit app files

CREATE OR REPLACE STAGE PDF_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Upload PDFs:
--   PUT file:///path/to/pdfs/*.pdf @<YOUR_STAGE> AUTO_COMPRESS = FALSE;
-- Upload EasyOCR models:
--   PUT file:///path/to/easyocr_models/*.pth @<YOUR_STAGE>/easyocr_models/ AUTO_COMPRESS = FALSE;

-- -----------------------------------------------------------------------------
-- 2. Extraction Results Table
-- -----------------------------------------------------------------------------
-- Stores the AI-extracted JSON for each clinical document.
-- EXTRACTION_RESULT is a VARIANT column containing:
--   { "fields": [ { "label", "value", "criterion_met", "rationale",
--                    "evidence_quote", "page_index", "confidence",
--                    "bounding_box", "bbox_source" } ] }

CREATE OR REPLACE TABLE EXTRACTION_RESULTS (
    RESULT_ID    NUMBER(38,0) AUTOINCREMENT START 1 INCREMENT 1 NOORDER,
    FILE_NAME    VARCHAR,
    EXTRACTION_RESULT VARIANT,
    EXTRACTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- -----------------------------------------------------------------------------
-- 3. Document Pages Table (Cortex Search corpus)
-- -----------------------------------------------------------------------------
-- Each row is one page of one document, with extracted text for search.
-- Text-layer PDFs use pypdfium2 extraction; scanned PDFs use AI_PARSE_DOCUMENT OCR.

CREATE OR REPLACE TABLE DOCUMENT_PAGES (
    FILE_NAME    VARCHAR,
    PAGE_INDEX   NUMBER(38,0),
    PAGE_TEXT    VARCHAR,
    PATIENT_NAME VARCHAR,
    DIAGNOSIS    VARCHAR,
    TIER         VARCHAR,
    INDEXED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- -----------------------------------------------------------------------------
-- 4. Ground Truth Table (for AI Function Evaluation)
-- -----------------------------------------------------------------------------
-- INPUT: the stage path to the PDF (e.g., 'Easy_Diabetes_Type2_01.pdf')
-- EXPECTED_OUTPUT: the expected JSON extraction result

CREATE OR REPLACE TABLE CLINICAL_GROUND_TRUTH (
    INPUT           VARCHAR,
    EXPECTED_OUTPUT VARCHAR
);

-- Populate ground truth (example pattern):
-- INSERT INTO CLINICAL_GROUND_TRUTH (INPUT, EXPECTED_OUTPUT)
-- SELECT 'Easy_Diabetes_Type2_01.pdf',
--        '{"fields": [{"label": "patient_name", "value": "John Smith", ...}, ...]}';

-- -----------------------------------------------------------------------------
-- 5. Cortex Search Service
-- -----------------------------------------------------------------------------
-- Enables natural-language search across the entire document corpus.
-- Embedding model: snowflake-arctic-embed-m-v1.5
-- Searchable column: PAGE_TEXT
-- Filterable attributes: FILE_NAME, PAGE_INDEX, PATIENT_NAME, DIAGNOSIS, TIER

CREATE OR REPLACE CORTEX SEARCH SERVICE CLINICAL_DOC_SEARCH
  ON PAGE_TEXT
  ATTRIBUTES FILE_NAME, PAGE_INDEX, PATIENT_NAME, DIAGNOSIS, TIER
  WAREHOUSE = <YOUR_WAREHOUSE>
  TARGET_LAG = '1 hour'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-m-v1.5'
AS (
    SELECT
        file_name,
        page_index,
        page_text,
        patient_name,
        diagnosis,
        tier
    FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES
);

-- =============================================================================
-- Usage Examples
-- =============================================================================

-- Run extraction on a single document:
--   INSERT INTO EXTRACTION_RESULTS (FILE_NAME, EXTRACTION_RESULT)
--   SELECT 'Easy_Diabetes_Type2_01.pdf',
--          EXTRACT_CLINICAL_DOCUMENT('Easy_Diabetes_Type2_01.pdf');

-- Batch extract all PDFs from stage:
--   INSERT INTO EXTRACTION_RESULTS (FILE_NAME, EXTRACTION_RESULT)
--   SELECT RELATIVE_PATH, EXTRACT_CLINICAL_DOCUMENT(RELATIVE_PATH)
--   FROM DIRECTORY(@<YOUR_STAGE>)
--   WHERE RELATIVE_PATH LIKE '%.pdf'
--     AND RELATIVE_PATH NOT LIKE '%easyocr_models%';

-- Query Cortex Search:
--   SELECT SNOWFLAKE.CORTEX.SEARCH(
--     '<YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_DOC_SEARCH',
--     '{"query": "patient with diabetes and hypertension", "columns": ["PAGE_TEXT","FILE_NAME","PATIENT_NAME"], "limit": 5}'
--   );
