-- =============================================================================
-- Document Classification - Option 1: Page Count Metadata
-- =============================================================================
-- Reads page count from PDF metadata without AI credits or OCR.
-- Cost: warehouse compute only (no Cortex AI token usage).
-- =============================================================================

USE DATABASE <YOUR_DATABASE>;
USE SCHEMA <YOUR_SCHEMA>;

-- -----------------------------------------------------------------------------
-- 1. Page Count UDF
-- -----------------------------------------------------------------------------
-- Reads the PDF header to extract page count. Does not parse or OCR content.
-- Uses pypdf (available in the Snowflake Anaconda channel).

CREATE OR REPLACE FUNCTION GET_PAGE_COUNT(file_path STRING)
RETURNS INT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdf')
HANDLER = 'run'
AS $$
from pypdf import PdfReader
from snowflake.snowpark.files import SnowflakeFile

def run(file_path):
    with SnowflakeFile.open(file_path, 'rb') as f:
        reader = PdfReader(f)
        return len(reader.pages)
$$;

-- -----------------------------------------------------------------------------
-- 2. Get Page Counts for All Staged PDFs
-- -----------------------------------------------------------------------------

SELECT
    relative_path,
    GET_PAGE_COUNT(BUILD_SCOPED_FILE_URL(@<YOUR_STAGE>, relative_path)) AS page_count
FROM DIRECTORY(@<YOUR_STAGE>)
WHERE relative_path LIKE '%.pdf'
ORDER BY page_count DESC;

-- -----------------------------------------------------------------------------
-- 3. Route by Page Count
-- -----------------------------------------------------------------------------
-- Adjust the threshold (20) based on your document corpus.

SELECT
    relative_path,
    GET_PAGE_COUNT(BUILD_SCOPED_FILE_URL(@<YOUR_STAGE>, relative_path)) AS page_count,
    CASE
        WHEN page_count <= 20 THEN 'single-encounter'
        ELSE 'compiled-chart'
    END AS routing_decision
FROM DIRECTORY(@<YOUR_STAGE>)
WHERE relative_path LIKE '%.pdf'
ORDER BY page_count DESC;
