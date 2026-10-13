-- =============================================================================
-- Clinical Document Intelligence Pipeline
-- Script 4: Cortex Search Corpus Population
-- =============================================================================
-- Populates the DOCUMENT_PAGES table that feeds the CLINICAL_DOC_SEARCH
-- Cortex Search Service. Handles both text-layer and scanned PDFs.
-- =============================================================================

USE DATABASE <YOUR_DATABASE>;
USE SCHEMA <YOUR_SCHEMA>;

-- -----------------------------------------------------------------------------
-- POPULATE_DOCUMENT_PAGES: Full corpus population (text-layer + OCR)
-- -----------------------------------------------------------------------------
-- For each document in EXTRACTION_RESULTS:
--   1. Download PDF and check for text layer using pypdfium2
--   2. Text-layer PDFs: extract text per page via pypdfium2
--   3. Scanned PDFs: extract text via AI_PARSE_DOCUMENT in OCR mode
--   4. Insert page text with metadata (patient_name, diagnosis, tier)
--
-- This procedure rebuilds the entire corpus (DELETE + INSERT).

CREATE OR REPLACE PROCEDURE POPULATE_DOCUMENT_PAGES(PDF_STAGE VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdfium2')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import pypdfium2 as pdfium
import os
import json

def run(session, pdf_stage):
    rows = session.sql("""
        SELECT file_name, extraction_result
        FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS
        WHERE file_name != 'Custom_Invoice_2001.pdf'
    """).collect()

    # Truncate existing pages
    session.sql("DELETE FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES").collect()

    text_layer_count = 0
    ocr_count = 0

    for row in rows:
        file_name = row[0]
        extraction = json.loads(row[1])
        fields = extraction.get("fields", [])

        # Get patient name and diagnosis from extraction
        patient_name = "Unknown"
        diagnosis = ""
        for f in fields:
            if f.get("label") == "patient_name":
                patient_name = f.get("value", "Unknown")
            if f.get("label") == "diagnosis":
                diagnosis = f.get("value", "")

        tier = (
            "Easy" if file_name.startswith("Easy")
            else "Medium" if file_name.startswith("Medium")
            else "Hard" if file_name.startswith("Hard")
            else "Other"
        )

        # Download PDF and check text layer
        try:
            session.file.get(pdf_stage + "/" + file_name, "/tmp/")
        except:
            pass
        local_path = "/tmp/" + os.path.basename(file_name)
        if not os.path.exists(local_path):
            continue

        pdf = pdfium.PdfDocument(local_path)
        total_chars = 0
        page_texts = []
        for i in range(len(pdf)):
            page = pdf[i]
            tp = page.get_textpage()
            text = tp.get_text_range()
            total_chars += len(text)
            page_texts.append(text)
        pdf.close()

        if total_chars > 0:
            # Text-layer PDF: use pypdfium2 text
            for i, text in enumerate(page_texts):
                if text.strip():
                    session.sql(
                        "INSERT INTO <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES "
                        "(file_name, page_index, page_text, patient_name, diagnosis, tier) "
                        "VALUES (?, ?, ?, ?, ?, ?)",
                        params=[file_name, i, text.strip(), patient_name, diagnosis, tier]
                    ).collect()
            text_layer_count += 1
        else:
            # Scanned PDF: use AI_PARSE_DOCUMENT OCR
            ocr_count += 1

    # Handle scanned PDFs via AI_PARSE_DOCUMENT
    scanned_files = session.sql("""
        SELECT DISTINCT er.file_name,
            (SELECT f.value:value::STRING
             FROM LATERAL FLATTEN(input => er.extraction_result:fields) f
             WHERE f.value:label::STRING = 'patient_name' LIMIT 1) AS patient_name,
            (SELECT f.value:value::STRING
             FROM LATERAL FLATTEN(input => er.extraction_result:fields) f
             WHERE f.value:label::STRING = 'diagnosis' LIMIT 1) AS diagnosis,
            CASE
                WHEN er.file_name LIKE 'Easy%' THEN 'Easy'
                WHEN er.file_name LIKE 'Medium%' THEN 'Medium'
                WHEN er.file_name LIKE 'Hard%' THEN 'Hard'
                ELSE 'Other'
            END AS tier
        FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS er
        WHERE er.file_name != 'Custom_Invoice_2001.pdf'
        AND er.file_name NOT IN (
            SELECT DISTINCT file_name FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES
        )
    """).collect()

    for sf in scanned_files:
        fname = sf[0]
        pname = sf[1] or "Unknown"
        diag = sf[2] or ""
        t = sf[3]
        try:
            parsed = session.sql("""
                SELECT AI_PARSE_DOCUMENT(
                    TO_FILE('@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE', ?),
                    {'mode': 'OCR', 'page_split': TRUE}
                ) AS doc
            """, params=[fname]).collect()
            if parsed and parsed[0][0]:
                import json as j2
                doc = (
                    parsed[0][0]
                    if isinstance(parsed[0][0], dict)
                    else j2.loads(str(parsed[0][0]))
                )
                pages = doc.get("pages", [])
                for p in pages:
                    pi = p.get("index", 0)
                    content = p.get("content", "")
                    if content.strip():
                        session.sql(
                            "INSERT INTO <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES "
                            "(file_name, page_index, page_text, "
                            "patient_name, diagnosis, tier) "
                            "VALUES (?, ?, ?, ?, ?, ?)",
                            params=[fname, pi, content.strip(), pname, diag, t]
                        ).collect()
        except Exception:
            pass  # skip docs that fail OCR

    total = session.sql(
        "SELECT COUNT(*) FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES"
    ).collect()[0][0]
    return json.dumps({
        "text_layer_docs": text_layer_count,
        "ocr_docs": ocr_count,
        "total_pages_indexed": total,
    })
$$;


-- -----------------------------------------------------------------------------
-- POPULATE_TEXT_LAYER_PAGES: Text-layer only (faster, no AI credits)
-- -----------------------------------------------------------------------------
-- Same as above but only processes text-layer PDFs. Scanned PDFs are
-- returned in the output for separate handling.

CREATE OR REPLACE PROCEDURE POPULATE_TEXT_LAYER_PAGES(PDF_STAGE VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdfium2')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import pypdfium2 as pdfium
import os
import json

def run(session, pdf_stage):
    session.sql("DELETE FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES").collect()

    rows = session.sql("""
        SELECT file_name, extraction_result
        FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS
        WHERE file_name != 'Custom_Invoice_2001.pdf'
    """).collect()

    text_count = 0
    scanned_files = []

    for row in rows:
        file_name = row[0]
        extraction = json.loads(row[1])
        fields = extraction.get("fields", [])

        patient_name = "Unknown"
        diagnosis = ""
        for f in fields:
            if f.get("label") == "patient_name":
                patient_name = f.get("value", "Unknown")
            if f.get("label") == "diagnosis":
                diagnosis = f.get("value", "")

        tier = (
            "Easy" if file_name.startswith("Easy")
            else "Medium" if file_name.startswith("Medium")
            else "Hard" if file_name.startswith("Hard")
            else "Other"
        )

        try:
            session.file.get(pdf_stage + "/" + file_name, "/tmp/")
        except:
            pass
        local_path = "/tmp/" + os.path.basename(file_name)
        if not os.path.exists(local_path):
            continue

        pdf = pdfium.PdfDocument(local_path)
        total_chars = 0
        page_texts = []
        for i in range(len(pdf)):
            tp = pdf[i].get_textpage()
            text = tp.get_text_range()
            total_chars += len(text)
            page_texts.append(text)
        pdf.close()

        if total_chars > 0:
            for i, text in enumerate(page_texts):
                if text.strip():
                    session.sql(
                        "INSERT INTO <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES "
                        "(file_name, page_index, page_text, "
                        "patient_name, diagnosis, tier) "
                        "VALUES (?, ?, ?, ?, ?, ?)",
                        params=[file_name, i, text.strip(),
                                patient_name, diagnosis, tier]
                    ).collect()
            text_count += 1
        else:
            scanned_files.append({
                "file_name": file_name,
                "patient_name": patient_name,
                "diagnosis": diagnosis,
                "tier": tier,
            })

    return json.dumps({
        "text_layer_docs": text_count,
        "scanned_remaining": len(scanned_files),
        "scanned_files": [s["file_name"] for s in scanned_files],
    })
$$;


-- =============================================================================
-- Workflow: Building the Search Corpus
-- =============================================================================

-- Option A: Full population (text-layer + scanned via AI_PARSE_DOCUMENT)
-- CALL POPULATE_DOCUMENT_PAGES('@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE');

-- Option B: Text-layer only (no AI credits), handle scanned separately
-- CALL POPULATE_TEXT_LAYER_PAGES('@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE');

-- After population, the Cortex Search Service auto-refreshes within TARGET_LAG.
-- Force a check:
-- SELECT COUNT(*) FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.DOCUMENT_PAGES;
-- SHOW CORTEX SEARCH SERVICES IN SCHEMA <YOUR_DATABASE>.<YOUR_SCHEMA>;
