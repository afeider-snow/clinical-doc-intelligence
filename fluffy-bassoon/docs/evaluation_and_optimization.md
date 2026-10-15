# Evaluation and Optimization Guide

Step-by-step guide to measuring and improving clinical document extraction quality using Snowflake's AI Function Evaluation and Optimization, with guidance on comparing Custom AI Functions against AI_EXTRACT.

## 1. Create a Custom AI Function

A Custom AI Function wraps `AI_COMPLETE` with `PROMPT()` and `TO_FILE()` to read PDFs natively from a Snowflake stage. This is the function you will evaluate and optimize.

```sql
CREATE OR REPLACE AI FUNCTION EXTRACT_CLINICAL_DOCUMENT(PDF_STAGE_PATH VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS '
    SELECT AI_COMPLETE(
      ''claude-sonnet-4-6'',
      PROMPT(''You are a clinical document extraction and review model specializing
in risk adjustment coding. Analyze this clinical document {0} and extract the
following fields.

FIELDS TO EXTRACT:
1. patient_name - Full patient name
2. date_of_birth - Patient DOB in the format found in the document
3. medical_record_number - MRN, Hospital ID, SSN, or any patient identifier
4. provider_name - Doctor/provider name
5. date_of_service - Procedure date, report date, or encounter date
6. diagnosis - Primary diagnosis text as stated in the document
7. comorbidities - Secondary conditions, complications, or co-occurring diagnoses
8. medications - Current medications with dosages if available
9. lab_results - Key lab tests and their status or values
10. diagnosis_specificity - Is the diagnosis documented to the highest ICD-10
    specificity? Answer: high / medium / low
11. supporting_evidence - Does the clinical note content support the stated
    diagnosis? Answer yes / partial / no with a brief explanation
12. documentation_gaps - What clinically relevant information is missing?

For each field return:
- label: the field name exactly as listed above
- value: the extracted text or assessment
- criterion_met: yes | no | insufficient_documentation
- rationale: brief explanation
- evidence_quote: verbatim text from the document (findable substring)
- page_index: zero-based page number
- confidence: high | medium | low

Return ONLY valid JSON, no markdown fences:
{{
  "fields": [
    {{"label": "...", "value": "...", "criterion_met": "yes", "rationale": "...",
      "evidence_quote": "...", "page_index": 0, "confidence": "high"}}
  ]
}}'',
        TO_FILE(''@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE'', pdf_stage_path))
    )
';
```

### Why Claude and Gemini models?

`AI_COMPLETE` accepts file input via `TO_FILE()` for models that support multimodal (image/document) input natively. Today, that means:

| Model family | File input via TO_FILE() | Notes |
|---|---|---|
| **Claude** (Anthropic) | Yes | Reads PDFs page-by-page as images. Strong on structured extraction. |
| **Gemini** (Google) | Yes | Reads PDFs natively. Handles scanned/low-quality documents well - likely a reflection of Google's investment in document/image understanding (Google Lens, Cloud Vision). |
| **GPT** (OpenAI) | No | Text-only input to AI_COMPLETE. Requires `AI_PARSE_DOCUMENT` to extract text first. |
| **Llama** (Meta) | No | Text-only input to AI_COMPLETE. Requires `AI_PARSE_DOCUMENT` to extract text first. |

For GPT or Llama models, the pipeline becomes two steps:

```sql
-- Step 1: Parse the PDF to text
SELECT AI_PARSE_DOCUMENT(@PDF_STAGE, 'document.pdf', {'mode': 'OCR'}):content::STRING
    AS doc_text;

-- Step 2: Pass the text to AI_COMPLETE
SELECT AI_COMPLETE('llama4-maverick',
    'Extract the following fields from this clinical document:\n\n' || doc_text);
```

This adds cost (the AI_PARSE_DOCUMENT call) and loses visual layout information that Claude and Gemini can interpret directly from the rendered page. For clinical documents with tables, stamps, handwritten annotations, or complex formatting, native file input is a material advantage.

In our optimization experiments, `gemini-2.5-flash` (ITER_48) achieved the highest quality score (83.0%) at the lowest per-document cost - outperforming the Claude baseline on both dimensions.

## 2. Prepare a Ground Truth Dataset

Evaluation and optimization require a versioned `SNOWFLAKE.ML.DATASET` containing labeled examples. Each row has:
- **INPUT**: the value passed to your function (e.g., the PDF stage path)
- **EXPECTED_OUTPUT**: the correct/gold-standard extraction result

```sql
-- Create a ground truth table
CREATE OR REPLACE TABLE CLINICAL_GROUND_TRUTH (
    INPUT           VARCHAR,    -- e.g., 'Easy_Diabetes_Type2_01.pdf'
    EXPECTED_OUTPUT VARCHAR     -- gold-standard JSON extraction
);

-- Populate it with labeled examples (50-200 rows recommended, 1,000 max)
INSERT INTO CLINICAL_GROUND_TRUTH (INPUT, EXPECTED_OUTPUT)
VALUES ('Easy_Diabetes_Type2_01.pdf',
        '{"fields": [{"label": "patient_name", "value": "John Smith", ...}]}');

-- Create a versioned dataset from the table
CREATE OR REPLACE DATASET CLINICAL_EVAL_DATASET
  FROM TABLE <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_GROUND_TRUTH
  LABEL = 'v1';
```

**Tips for labeling:**
- Include documents across all complexity tiers (easy, medium, hard)
- Include both digital-born and scanned PDFs
- Label every field, including `"criterion_met": "no"` for fields not present
- 50-200 rows is recommended; fewer and optimization lacks signal, more and runtimes get long

## 3. Run an Evaluation

Evaluation measures your function's current quality without modifying it. Use this as a baseline before optimizing.

### Evaluation Specification

```sql
CREATE OR REPLACE EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_EVAL
  TYPE = 'AI_FUNCTION_EVALUATION'
  FROM SPECIFICATION $$
query_text: "<YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACT_CLINICAL_DOCUMENT(INPUT)"
metrics:
  - name: llm_judge
dataset:
  name: <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EVAL_DATASET
  version: v1
  ground_truth: EXPECTED_OUTPUT
evaluation:
  num_eval_runs: 3
$$;

EXECUTE EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_EVAL;
```

### Evaluation Parameters

| Parameter | Required | Description |
|---|---|---|
| `query_text` | Yes | SQL expression to evaluate. References dataset columns by name. Can be a Custom AI Function call or an inline `AI_COMPLETE` expression. |
| `metrics.name` | Yes | Exactly one scoring metric (see table below). |
| `metrics.judge_model` | No | Model used to grade outputs when `name: llm_judge`. Default: `claude-sonnet-4-5`. |
| `metrics.custom_udf` | Conditional | Required when `name: custom`. Fully-qualified UDF name. |
| `dataset.name` | Yes | Fully-qualified name of a versioned `SNOWFLAKE.ML.DATASET`. |
| `dataset.version` | Yes | Dataset version label (e.g., `v1`). |
| `dataset.ground_truth` | Yes | Column containing expected output. |
| `evaluation.num_eval_runs` | No | Number of repeat runs (1-20, default 1). Use 3-5 to measure variance. |

### Choosing a Metric

| Metric | When to use |
|---|---|
| `exact_match` | Classification tasks where the output must match a fixed label exactly. |
| `fuzzy_match` | Outputs that should approximately match but may differ in formatting, whitespace, or casing. |
| `contains_match` | One value should contain the other (e.g., extracted text is a substring of the expected output). |
| `redaction_match` | PII redaction tasks comparing redacted output to expected redaction. |
| `llm_judge` | **Best for clinical extraction.** Open-ended structured outputs (JSON with multiple fields) where semantic correctness matters more than exact string matching. The judge evaluates whether the extracted values are correct, not whether the formatting is identical. |
| `custom` | When you need domain-specific scoring logic. Write a scalar UDF that takes `(EXPECTED, PREDICTED)` and returns `{'score': 0.0-1.0}`. |

For clinical extraction, **use `llm_judge`**. The output is structured JSON with 12 fields, and minor differences in formatting, field ordering, or phrasing shouldn't count as failures. An exact_match metric would penalize semantically correct extractions that differ in punctuation or whitespace.

### Reading Results

```sql
-- Check if evaluation is complete
SHOW RUNS IN EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_EVAL;

-- Read scores for each run
SHOW RUN METRICS IN EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_EVAL RUN EVAL_1;
SHOW RUN METRICS IN EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_EVAL RUN EVAL_2;
```

The `score` metric (0-1) is your baseline. In our experiments, the baseline `claude-sonnet-4-6` function scored **0.778**.

## 4. Run an Optimization

Optimization generates candidate implementations by modifying the prompt and model, evaluates each against your dataset, and reports a quality/cost frontier. It does not modify your original function.

### Optimization Specification

```sql
CREATE OR REPLACE EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_OPT
  TYPE = 'AI_FUNCTION_OPTIMIZATION'
  FROM SPECIFICATION $$
function:
  function_name: "<YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACT_CLINICAL_DOCUMENT(VARCHAR)"
metrics:
  - name: llm_judge
dataset:
  name: <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EVAL_DATASET
  version: v1
  column_mapping:
    argument_mapping:
      PDF_STAGE_PATH: INPUT
    ground_truth: EXPECTED_OUTPUT
optimization:
  models:
    - claude-sonnet-4-6
    - gemini-2.5-flash
  reflection_model: claude-sonnet-4-5
  strategy: quality_first
  budget: light
$$;

EXECUTE EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_OPT;
```

### Optimization Parameters

| Parameter | Required | Description |
|---|---|---|
| `function.function_name` | Yes* | Fully-qualified function name with arg types. Must be created with `CREATE AI FUNCTION`. |
| `function.function_body` | Yes* | Alternative: inline SQL expression to optimize directly. Use one or the other. |
| `metrics.name` | Yes | Same metric options as evaluation. One metric per optimization. |
| `dataset.name` | Yes | Versioned `SNOWFLAKE.ML.DATASET`. |
| `dataset.version` | Yes | Dataset version. |
| `dataset.column_mapping.argument_mapping` | No | Maps function arg names to dataset column names when they differ. |
| `dataset.column_mapping.ground_truth` | No | Label column name (if not using the default). |
| `optimization.models` | Yes | List of candidate models to try (max 5). Each is optimized in parallel. |
| `optimization.reflection_model` | Yes | Model used to generate candidate improvements. Use the most capable available (e.g., `claude-sonnet-4-5`). |
| `optimization.strategy` | No | Optimization objective. Default: `quality_first`. |
| `optimization.budget` | No | Search effort. Default: `auto` (resolves to `light`). |

### Strategy: When to Choose Each

| Strategy | Behavior | When to use |
|---|---|---|
| `quality_first` | Maximize the metric score. Default. | When accuracy is the primary concern and you're willing to pay more per document. Clinical extraction where errors have compliance consequences. |
| `balanced` | Trade quality against cost. | When you need to find the best quality within a cost envelope. High-volume production workloads where a 5% quality gain isn't worth 2x cost. |
| `cost_first` | Minimize cost while holding quality. | When you have a quality floor and want the cheapest model/prompt that meets it. Triage or classification tasks where "good enough" is acceptable. |

### Budget: How Much to Search

| Budget | Iterations per model | When to use |
|---|---|---|
| `ultra-light` | 4-6 | First run. Validate the pipeline works end-to-end before spending on a full search. |
| `light` | 10-15 | Standard runs. Good balance of exploration and cost for most use cases. |
| `medium` | 18-27 | When `light` found promising candidates but you suspect more gains are possible. |
| `heavy` | 27-40 | Maximum exploration. Use when the quality improvement justifies the search cost (e.g., high-value extraction at scale). |

Budget applies independently to each candidate model. Three models with `light` budget means three separate 10-15 iteration searches.

### Inspecting Results

```sql
-- List all runs
SHOW RUNS IN EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_OPT;

-- Check the baseline (SEED)
SHOW RUN METRICS IN EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_OPT RUN SEED;

-- Check a specific candidate
SHOW RUN METRICS IN EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_OPT RUN ITER_48;

-- See the candidate's implementation (prompt + model)
SHOW RUN PARAMETERS IN EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_OPT RUN ITER_48;
```

Key metrics per run:

| Field | Meaning |
|---|---|
| `val_score` | Quality on the validation split (0-1). |
| `test_score` | Quality on the held-out test split. More honest than val_score. |
| `cost_compared_to_seed` | Cost relative to baseline. <1 is cheaper, >1 is more expensive. |
| `is_frontier` | 1 if on the Pareto frontier (not dominated on quality or cost). |

### Promoting the Winner

```sql
CREATE OR REPLACE AI FUNCTION EXTRACT_CLINICAL_DOCUMENT_V2(PDF_STAGE_PATH VARCHAR)
  RETURNS VARIANT
  FROM EXPERIMENT <YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_EXTRACTION_OPT
  RUN ITER_48;
```

This creates a new function from the winning candidate's prompt and model configuration. Your original function remains unchanged.

## 5. Comparing with AI_EXTRACT

AI_EXTRACT is Snowflake's built-in extraction function. It handles OCR, layout detection, and extraction in a single call - no prompt engineering required. Comparing it against a Custom AI Function helps determine which approach best fits your use case.

### Basic AI_EXTRACT Call

```sql
SELECT AI_EXTRACT(
    file => TO_FILE('@<YOUR_STAGE>', 'Easy_Diabetes_Type2_01.pdf'),
    responseFormat => {
        'patient_name':          'Full patient name',
        'date_of_birth':         'Patient date of birth',
        'medical_record_number': 'MRN or patient identifier',
        'provider_name':         'Doctor or provider name',
        'date_of_service':       'Encounter, procedure, or report date',
        'diagnosis':             'Primary diagnosis text'
    }
);
```

### AI_EXTRACT Parameters

| Parameter | Description | When to use |
|---|---|---|
| `file` | PDF/image file via `TO_FILE()`. | Always, for document extraction. |
| `text` | Plain text string input. Alternative to `file`. | When you already have OCR'd text and don't need layout-aware extraction. |
| `responseFormat` | Schema defining what to extract. Supports entity, list, and table extraction formats. | Always required. Use simple key-value for entities, JSON schema for lists/tables. |
| `scores => TRUE` | Returns a `scoring` object with per-field confidence (0-1). No additional cost. | Always enable for production. Use scores to flag low-confidence extractions for human review. |
| `config => {'scale_factor': N}` | Scales pages before processing (1.0-4.0). Increases token consumption proportionally and reduces max page limit. | Scanned documents with small text, dense layouts, or OCR errors. A scale_factor of 2.0 doubles token cost and halves the 125-page limit to 62. |
| `model` | Fine-tuned `arctic-extract` model reference. | When you've fine-tuned arctic-extract for your specific document type. |

### AI_EXTRACT with Scores

```sql
SELECT AI_EXTRACT(
    file => TO_FILE('@<YOUR_STAGE>', 'Easy_Diabetes_Type2_01.pdf'),
    responseFormat => {
        'patient_name':          'Full patient name',
        'date_of_birth':         'Patient date of birth',
        'medical_record_number': 'MRN or patient identifier',
        'provider_name':         'Doctor or provider name',
        'date_of_service':       'Encounter, procedure, or report date',
        'diagnosis':             'Primary diagnosis text'
    },
    scores => TRUE
);
```

Returns:
```json
{
  "response": {
    "patient_name": "John Smith",
    "date_of_birth": "03/15/1958",
    "diagnosis": "Type 2 Diabetes Mellitus"
  },
  "scoring": {
    "scores": {
      "patient_name": {"score": 0.99},
      "date_of_birth": {"score": 0.95},
      "diagnosis": {"score": 0.88}
    }
  },
  "error": null
}
```

### AI_EXTRACT with Scale Factor (Scanned Documents)

```sql
SELECT AI_EXTRACT(
    file => TO_FILE('@<YOUR_STAGE>', 'Hard_Scanned_Fax_01.pdf'),
    responseFormat => {
        'patient_name': 'Full patient name',
        'diagnosis':    'Primary diagnosis text'
    },
    config => {'scale_factor': 2.0},
    scores => TRUE
);
```

Scale factor tradeoffs:

| scale_factor | Tokens per page | Max pages | Use case |
|---|---|---|---|
| 1.0 (default) | 970 | 125 | Digital-born PDFs, clean scans |
| 2.0 | 1,940 | 62 | Scanned documents with small text or dense layouts |
| 2.5 | 2,425 | 50 | Low-quality faxes, detailed visual elements |
| 4.0 | 3,880 | 31 | Worst-case OCR scenarios - only use if lower factors produce errors |

### Structured Comparison: Custom AI Function vs AI_EXTRACT

To compare approaches on the same dataset, evaluate both using the same ground truth:

```sql
-- Evaluation 1: Custom AI Function
CREATE OR REPLACE EXPERIMENT <DB>.<SCHEMA>.EVAL_CUSTOM
  TYPE = 'AI_FUNCTION_EVALUATION'
  FROM SPECIFICATION $$
query_text: "<DB>.<SCHEMA>.EXTRACT_CLINICAL_DOCUMENT(INPUT)"
metrics:
  - name: llm_judge
dataset:
  name: <DB>.<SCHEMA>.CLINICAL_EVAL_DATASET
  version: v1
  ground_truth: EXPECTED_OUTPUT
evaluation:
  num_eval_runs: 3
$$;

EXECUTE EXPERIMENT <DB>.<SCHEMA>.EVAL_CUSTOM;

-- Evaluation 2: AI_EXTRACT (inline expression)
CREATE OR REPLACE EXPERIMENT <DB>.<SCHEMA>.EVAL_AI_EXTRACT
  TYPE = 'AI_FUNCTION_EVALUATION'
  FROM SPECIFICATION $$
query_text: "AI_EXTRACT(
    file => TO_FILE('@<DB>.<SCHEMA>.PDF_STAGE', INPUT),
    responseFormat => {
        'patient_name':          'Full patient name',
        'date_of_birth':         'Patient date of birth',
        'medical_record_number': 'MRN or patient identifier',
        'provider_name':         'Doctor or provider name',
        'date_of_service':       'Encounter, procedure, or report date',
        'diagnosis':             'Primary diagnosis text',
        'comorbidities':         'Secondary conditions or co-occurring diagnoses',
        'medications':           'Current medications with dosages',
        'lab_results':           'Key lab tests and values',
        'diagnosis_specificity': 'Is the diagnosis at highest ICD-10 specificity? high/medium/low',
        'supporting_evidence':   'Does clinical content support the diagnosis? yes/partial/no',
        'documentation_gaps':    'What clinically relevant information is missing?'
    }
)"
metrics:
  - name: llm_judge
dataset:
  name: <DB>.<SCHEMA>.CLINICAL_EVAL_DATASET
  version: v1
  ground_truth: EXPECTED_OUTPUT
evaluation:
  num_eval_runs: 3
$$;

EXECUTE EXPERIMENT <DB>.<SCHEMA>.EVAL_AI_EXTRACT;
```

### AI_EXTRACT vNext 

Key differences from AI_EXTRACT:

- Scores (`scores => TRUE`) may not be available yet in vNext
- The underlying model and extraction pipeline may differ from regular AI_EXTRACT
- Performance characteristics (latency, token usage, accuracy) may evolve

To compare AI_EXTRACT against your Custom AI Function, run separate evaluations on the same dataset and metric. Without scores, you'll rely on the evaluation experiment's `llm_judge` metric rather than AI_EXTRACT's built-in per-field confidence scores.

### When to Use Which

| Factor | Custom AI Function | AI_EXTRACT |
|---|---|---|
| **Prompt control** | Full control over prompt, instructions, output schema, and reasoning behavior. | No prompt - you define *what* to extract, Snowflake decides *how*. |
| **Model choice** | Any model supported by AI_COMPLETE. Can optimize across models. | Uses Snowflake's built-in extraction model (arctic-extract). Can fine-tune. |
| **Output schema** | Fully custom JSON. Can include rationale, evidence quotes, confidence, page references. | Fixed response structure. Entity, list, or table extraction. |
| **Optimization** | AI_FUNCTION_OPTIMIZATION tunes prompt + model automatically. | Fine-tune arctic-extract on your labeled data. |
| **Scores** | Must be built into your prompt (e.g., confidence field). | Native per-field scores via `scores => TRUE`. No additional cost. |
| **OCR handling** | Native for Claude/Gemini via TO_FILE(). Requires AI_PARSE_DOCUMENT for GPT/Llama. | Built-in. Handles digital and scanned documents. scale_factor for quality tuning. |
| **Best for** | Complex extraction with domain-specific reasoning, custom output formats, multi-field assessments. | Straightforward entity/table extraction where built-in OCR and scoring are sufficient. |

## 6. Cost Monitoring

Track per-model credit usage across all AI function calls:

```sql
SELECT
    MODEL_NAME,
    COUNT(DISTINCT QUERY_ID) AS num_calls,
    SUM(CREDITS) AS total_credits,
    SUM(CREDITS) / COUNT(DISTINCT QUERY_ID) AS avg_credits_per_call
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE FUNCTION_NAME IN ('AI_COMPLETE', 'AI_FUNCTION', 'AI_EXTRACT')
  AND START_TIME >= DATEADD('day', -14, CURRENT_TIMESTAMP())
GROUP BY MODEL_NAME
ORDER BY num_calls DESC;
```

For Custom AI Function token consumption:

```sql
SELECT
    m.value:key:CUSTOM_AI_FUNCTION_NAME::STRING AS func_name,
    m.value:key:metric::STRING AS metric_type,
    SUM(m.value:value::NUMBER) AS token_number
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY c,
    LATERAL FLATTEN(input => c.METRICS) m
WHERE c.START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    AND func_name ILIKE '%EXTRACT_CLINICAL_DOCUMENT%'
GROUP BY 1, 2
ORDER BY func_name DESC;
```
