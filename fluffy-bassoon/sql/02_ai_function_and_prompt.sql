-- =============================================================================
-- Clinical Document Intelligence Pipeline
-- Script 2: AI Function and Extraction Prompt
-- =============================================================================
-- The core extraction function uses CREATE AI FUNCTION wrapping AI_COMPLETE
-- with PROMPT() + TO_FILE() to natively read PDFs on Snowflake.
-- =============================================================================

USE DATABASE <YOUR_DATABASE>;
USE SCHEMA <YOUR_SCHEMA>;

-- -----------------------------------------------------------------------------
-- 1. Primary Extraction Function: EXTRACT_CLINICAL_DOCUMENT
-- -----------------------------------------------------------------------------
-- Model: claude-sonnet-4-6
-- Input: relative path to a PDF on @<YOUR_STAGE> (e.g., 'Easy_Diabetes_Type2_01.pdf')
-- Output: VARIANT containing { "fields": [ ... ] }
--
-- Each field in the output contains:
--   label            - one of the 12 field names below
--   value            - extracted text or assessment
--   criterion_met    - "yes" | "no" | "insufficient_documentation"
--   rationale        - brief explanation of the extraction decision
--   evidence_quote   - verbatim text from the document (used for bounding box resolution)
--   page_index       - zero-based page number where the value was found
--   confidence       - "high" | "medium" | "low"
--
-- 12 Extraction Fields:
--   1.  patient_name              7.  comorbidities
--   2.  date_of_birth             8.  medications
--   3.  medical_record_number     9.  lab_results
--   4.  provider_name             10. diagnosis_specificity
--   5.  date_of_service           11. supporting_evidence
--   6.  diagnosis                 12. documentation_gaps

CREATE OR REPLACE AI FUNCTION EXTRACT_CLINICAL_DOCUMENT(PDF_STAGE_PATH VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS '
    SELECT AI_COMPLETE(
      ''claude-sonnet-4-6'',
      PROMPT(''You are a clinical document extraction and review model specializing in risk adjustment coding. Analyze this clinical document {0} and extract the following fields.

FIELDS TO EXTRACT:
1. patient_name - Full patient name
2. date_of_birth - Patient DOB in the format found in the document
3. medical_record_number - MRN, Hospital ID, SSN, or any patient identifier
4. provider_name - Doctor/provider name
5. date_of_service - Procedure date, report date, or encounter date
6. diagnosis - Primary diagnosis text as stated in the document
7. comorbidities - Secondary conditions, complications, or co-occurring diagnoses (comma-separated if multiple)
8. medications - Current medications with dosages if available (comma-separated)
9. lab_results - Key lab tests and their status or values (comma-separated)
10. diagnosis_specificity - Is the diagnosis documented to the highest ICD-10 specificity? Answer: "high" if type, complications, and laterality are specified; "medium" if partially specified; "low" if vague
11. supporting_evidence - Does the clinical note content support the stated diagnosis? Answer "yes", "partial", or "no" with a brief explanation
12. documentation_gaps - What clinically relevant information is missing that would improve risk adjustment coding accuracy? Answer "none" if complete, otherwise list gaps

For each field return:
- label: the field name exactly as listed above
- value: the extracted text or assessment
- criterion_met: "yes" if clearly present and legible, "no" if not found, "insufficient_documentation" if partially present
- rationale: brief explanation
- evidence_quote: verbatim text from the document used to extract this field (must be a findable substring in the document)
- page_index: zero-based page number
- confidence: "high", "medium", or "low"

Return ONLY valid JSON, no markdown fences:
{{
  "fields": [
    {{"label": "...", "value": "...", "criterion_met": "yes", "rationale": "...", "evidence_quote": "...", "page_index": 0, "confidence": "high"}}
  ]
}}'',
        TO_FILE(''@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE'', pdf_stage_path))
    )
';

-- -----------------------------------------------------------------------------
-- 2. AI-Based Bounding Box Estimation Function
-- -----------------------------------------------------------------------------
-- A secondary AI function that asks the model to visually locate field values
-- on the PDF and return normalized bounding box coordinates.
-- Used as a fallback for scanned PDFs when OCR matching fails.

CREATE OR REPLACE AI FUNCTION ESTIMATE_BOUNDING_BOXES(PDF_STAGE_PATH VARCHAR, FIELDS_JSON VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS '
SELECT TRY_PARSE_JSON(
    REGEXP_REPLACE(
        AI_COMPLETE(
            ''claude-sonnet-4-6'',
            PROMPT(
                ''Look at this document {0} carefully. For each field below, find where its value text appears on the page and estimate its bounding box as normalized coordinates [x0, y0, x1, y1] where (0,0) is top-left and (1,1) is bottom-right. Be precise. Return ONLY a JSON array with label and bbox keys. No markdown fences or extra text. Fields: '' || fields_json,
                TO_FILE(''@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE'', pdf_stage_path)
            )
        )::STRING,
        ''^```[a-z]*\\n|\\n```$'', ''''
    )
)
';

-- =============================================================================
-- Running Extraction
-- =============================================================================

-- Single document:
SELECT EXTRACT_CLINICAL_DOCUMENT('Easy_Diabetes_Type2_01.pdf') AS result;

-- Batch (all PDFs on stage):
INSERT INTO EXTRACTION_RESULTS (FILE_NAME, EXTRACTION_RESULT)
SELECT
    RELATIVE_PATH AS file_name,
    EXTRACT_CLINICAL_DOCUMENT(RELATIVE_PATH) AS extraction_result
FROM DIRECTORY(@<YOUR_STAGE>)
WHERE RELATIVE_PATH LIKE '%.pdf'
  AND RELATIVE_PATH NOT LIKE '%easyocr_models%'
  AND RELATIVE_PATH NOT IN (SELECT FILE_NAME FROM EXTRACTION_RESULTS);

-- =============================================================================
-- Tuning Parameters (applied via AI_COMPLETE options)
-- =============================================================================
-- AI_COMPLETE supports these tuning controls when called directly:
--
--   AI_COMPLETE('model', prompt,
--     { 'temperature': 0.1,    -- lower = more deterministic (0.0 - 1.0)
--       'top_p': 0.9,          -- nucleus sampling threshold
--       'max_tokens': 4096 })  -- maximum output length
--
-- These cannot be set inside CREATE AI FUNCTION but can be used when calling
-- AI_COMPLETE directly for experimentation or one-off runs.
