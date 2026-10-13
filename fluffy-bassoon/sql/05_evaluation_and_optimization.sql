-- =============================================================================
-- Clinical Document Intelligence Pipeline
-- Script 5: Evaluation and Optimization
-- =============================================================================
-- Uses Snowflake AI Function Evaluation and Optimization to measure and
-- improve extraction quality across the clinical document corpus.
-- =============================================================================

USE DATABASE <YOUR_DATABASE>;
USE SCHEMA <YOUR_SCHEMA>;

-- =============================================================================
-- 1. Create Evaluation Dataset
-- =============================================================================
-- The ground truth table (CLINICAL_GROUND_TRUTH) stores 10 labeled documents.
-- Each row has:
--   INPUT: the PDF stage path (e.g., 'Easy_Diabetes_Type2_01.pdf')
--   EXPECTED_OUTPUT: the gold-standard JSON extraction result

-- Create an ML Dataset version from the ground truth table:
CREATE OR REPLACE DATASET CLINICAL_EVAL_DATASET
  FROM TABLE <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_GROUND_TRUTH
  LABEL = 'v1';

-- =============================================================================
-- 2. Run Evaluation
-- =============================================================================
-- Evaluates the EXTRACT_CLINICAL_DOCUMENT function against ground truth.
-- Produces a quality score (0.0 to 1.0) measuring extraction accuracy.

-- Run evaluation (creates an experiment):
SELECT SNOWFLAKE.CORTEX.AI_FUNCTION_EVALUATION(
    '<YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACT_CLINICAL_DOCUMENT',
    { 'dataset': '<YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EVAL_DATASET', 'version': 'v1' },
    '<YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_EVAL'
);

-- Check evaluation results:
-- Navigate to Snowsight > AI & ML > AI Functions > EXTRACT_CLINICAL_DOCUMENT
-- The evaluation experiment shows per-document scores and aggregate metrics.

-- =============================================================================
-- 3. Run Optimization
-- =============================================================================
-- Optimization runs multiple iterations (up to 52) testing different prompt
-- variations, model configurations, and extraction strategies to maximize
-- the evaluation score.

SELECT SNOWFLAKE.CORTEX.AI_FUNCTION_OPTIMIZATION(
    '<YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACT_CLINICAL_DOCUMENT',
    { 'dataset': '<YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EVAL_DATASET', 'version': 'v1' },
    '<YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_OPT'
);

-- Results:
-- Baseline score: 0.80
-- Best iteration (ITER_48): 0.830
-- Promote the optimized iteration via Snowsight AI Function Studio.

-- =============================================================================
-- 4. Cost Monitoring
-- =============================================================================
-- Track per-model credit usage for AI functions.

SELECT
    MODEL_NAME,
    COUNT(DISTINCT QUERY_ID) AS num_calls,
    SUM(CREDITS) AS total_credits,
    SUM(CREDITS) / COUNT(DISTINCT QUERY_ID) AS avg_credits_per_call
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE FUNCTION_NAME IN ('AI_COMPLETE', 'AI_FUNCTION')
  AND START_TIME >= DATEADD('day', -14, CURRENT_TIMESTAMP())
GROUP BY MODEL_NAME
ORDER BY num_calls DESC;

-- Per-document cost breakdown:
SELECT
    QUERY_ID,
    MODEL_NAME,
    CREDITS,
    START_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE FUNCTION_NAME IN ('AI_COMPLETE', 'AI_FUNCTION')
  AND START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC
LIMIT 50;

-- =============================================================================
-- 5. Useful Diagnostic Queries
-- =============================================================================

-- Bbox resolution coverage:
SELECT
    f.value:bbox_source::STRING AS bbox_source,
    COUNT(*) AS field_count
FROM EXTRACTION_RESULTS,
    LATERAL FLATTEN(input => extraction_result:fields) f
GROUP BY bbox_source
ORDER BY field_count DESC;

-- Fields with low confidence:
SELECT
    file_name,
    f.value:label::STRING AS label,
    f.value:confidence::STRING AS confidence,
    f.value:criterion_met::STRING AS criterion_met,
    f.value:value::STRING AS value
FROM EXTRACTION_RESULTS,
    LATERAL FLATTEN(input => extraction_result:fields) f
WHERE f.value:confidence::STRING = 'low'
ORDER BY file_name;

-- Documents missing bounding boxes:
SELECT
    file_name,
    COUNT(*) AS total_fields,
    SUM(CASE WHEN f.value:bounding_box IS NOT NULL THEN 1 ELSE 0 END) AS with_bbox,
    SUM(CASE WHEN f.value:bbox_source::STRING = 'ocr_no_match' THEN 1 ELSE 0 END) AS ocr_no_match
FROM EXTRACTION_RESULTS,
    LATERAL FLATTEN(input => extraction_result:fields) f
GROUP BY file_name
HAVING ocr_no_match > 0
ORDER BY ocr_no_match DESC;
