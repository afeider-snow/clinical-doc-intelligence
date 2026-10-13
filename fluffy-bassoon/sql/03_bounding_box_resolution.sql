-- =============================================================================
-- Clinical Document Intelligence Pipeline
-- Script 3: Bounding Box Resolution (Python Stored Procedures)
-- =============================================================================
-- Two paths for resolving bounding boxes:
--   Path A: pypdfium2 text-layer search (digital PDFs) - fast, exact
--   Path B: EasyOCR word detection (scanned PDFs) - three-strategy matching
--
-- The litmus test: pypdfium2 checks whether the PDF has a text layer.
-- Zero characters = scanned document = OCR required.
-- =============================================================================

USE DATABASE <YOUR_DATABASE>;
USE SCHEMA <YOUR_SCHEMA>;

-- =============================================================================
-- PATH A: Text-Layer PDFs (pypdfium2)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- RESOLVE_BOUNDING_BOXES: Single-document text-layer bbox resolution
-- -----------------------------------------------------------------------------
-- Uses pypdfium2 to search for evidence_quote or value text in the PDF text
-- layer and returns character-level bounding box coordinates.
-- Strategy: evidence_quote first, then value, then first line of evidence.
-- Output: normalized [x0, y0, x1, y1] where (0,0) = top-left.

CREATE OR REPLACE PROCEDURE RESOLVE_BOUNDING_BOXES(
    PDF_STAGE VARCHAR,
    PDF_FILE VARCHAR,
    EXTRACTION_JSON VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdfium2')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import pypdfium2 as pdfium
import json
import os

def find_text_bbox(textpage, search_text, w_pts, h_pts):
    """Search for text in the PDF page and return normalized bounding box."""
    searcher = textpage.search(search_text)
    if not searcher:
        return None
    match = searcher.get_next()
    if not match:
        return None
    char_idx, char_count = match
    rects = []
    for i in range(char_idx, char_idx + char_count):
        try:
            left, bottom, right, top = textpage.get_charbox(i)
            rects.append((left, bottom, right, top))
        except Exception:
            continue
    if not rects:
        return None
    x0 = min(r[0] for r in rects) / w_pts
    y0 = 1.0 - max(r[3] for r in rects) / h_pts
    x1 = max(r[2] for r in rects) / w_pts
    y1 = 1.0 - min(r[1] for r in rects) / h_pts
    return [round(x0, 4), round(y0, 4), round(x1, 4), round(y1, 4)]

def run(session, pdf_stage, pdf_file, extraction_json):
    extraction = json.loads(extraction_json)
    fields = extraction.get("fields", [])

    session.file.get(f"{pdf_stage}/{pdf_file}", "/tmp/")
    local_path = f"/tmp/{os.path.basename(pdf_file)}"
    pdf = pdfium.PdfDocument(local_path)

    # Cache textpage per page for multi-field lookups
    page_cache = {}

    for field in fields:
        page_idx = field.get("page_index", 0)
        evidence = field.get("evidence_quote", "")
        value = field.get("value", "")

        if page_idx not in page_cache:
            page = pdf[page_idx]
            page_cache[page_idx] = {
                "textpage": page.get_textpage(),
                "w": page.get_width(),
                "h": page.get_height(),
            }

        pc = page_cache[page_idx]
        tp, w, h = pc["textpage"], pc["w"], pc["h"]

        # Try evidence_quote first, then value, then first line of evidence
        bbox = find_text_bbox(tp, evidence, w, h)
        if bbox is None and value:
            bbox = find_text_bbox(tp, value, w, h)
        if bbox is None:
            first_line = evidence.split("\n")[0].strip() if evidence else ""
            if first_line:
                bbox = find_text_bbox(tp, first_line, w, h)

        if bbox is not None:
            field["bounding_box"] = bbox
            field["bbox_source"] = "pdf_text_layer"
        else:
            field["bbox_source"] = "model_estimate"

    pdf.close()
    return {"fields": fields}
$$;


-- =============================================================================
-- PATH B: Scanned PDFs (EasyOCR)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- BATCH_RESOLVE_BBOXES_OCR: Batch EasyOCR-based bbox resolution
-- -----------------------------------------------------------------------------
-- For each document:
--   1. Check if PDF has a text layer (skip if yes)
--   2. Render needed pages at 150 DPI
--   3. Run EasyOCR word detection
--   4. Match extracted field values to OCR words using three strategies:
--      - Strategy 1: Exact consecutive-word substring matching
--      - Strategy 2: Fuzzy overlap scoring (threshold > 0.4, prefer > 0.85)
--      - Strategy 3: Word-level assembly across multiple OCR detections
--   5. Merge bounding boxes of matched words
--   6. Update EXTRACTION_RESULTS with resolved coordinates
--
-- EasyOCR models must be pre-staged at:
--   @<YOUR_STAGE>/easyocr_models/craft_mlt_25k.pth
--   @<YOUR_STAGE>/easyocr_models/english_g2.pth
--   @<YOUR_STAGE>/easyocr_models/latin.pth

CREATE OR REPLACE PROCEDURE BATCH_RESOLVE_BBOXES_OCR(PDF_STAGE VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdfium2', 'easyocr', 'pillow')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import os
import json
import time

def run(session, pdf_stage):
    t0 = time.time()
    log = []
    def step(msg):
        log.append(f"[{time.time()-t0:6.1f}s] {msg}")

    # --- Setup EasyOCR with pre-staged models ---
    os.environ['HOME'] = '/tmp'
    MODEL_DIR = "/tmp/.EasyOCR/model"
    os.makedirs(MODEL_DIR, exist_ok=True)
    os.makedirs("/tmp/.EasyOCR/user_network", exist_ok=True)

    model_files = ["craft_mlt_25k.pth", "english_g2.pth", "latin.pth"]
    for mf in model_files:
        mf_path = os.path.join(MODEL_DIR, mf)
        if not os.path.exists(mf_path):
            session.file.get(
                f"@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE/easyocr_models/{mf}", MODEL_DIR
            )
            step(f"{mf} copied")
        else:
            step(f"{mf} cached")

    from PIL import Image
    if not hasattr(Image, 'ANTIALIAS'):
        Image.ANTIALIAS = Image.LANCZOS

    import easyocr
    import pypdfium2 as pdfium

    step("Initializing EasyOCR Reader...")
    reader = easyocr.Reader(
        ['en'], gpu=False,
        model_storage_directory=MODEL_DIR,
        user_network_directory="/tmp/.EasyOCR/user_network",
        download_enabled=False,
    )
    step("Reader initialized.")

    # --- Load all extraction results ---
    rows = session.sql("""
        SELECT file_name, extraction_result
        FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS
        WHERE file_name != 'Custom_Invoice_2001.pdf'
    """).collect()
    step(f"Loaded {len(rows)} documents.")

    results_summary = []

    for row in rows:
        file_name = row[0]
        extraction = json.loads(row[1])
        fields = extraction.get("fields", [])

        # --- Check if PDF has text layer ---
        try:
            session.file.get(pdf_stage + "/" + file_name, "/tmp/")
        except:
            pass
        local_path = "/tmp/" + os.path.basename(file_name)
        if not os.path.exists(local_path):
            results_summary.append({"file": file_name, "status": "file_not_found"})
            continue

        pdf = pdfium.PdfDocument(local_path)
        total_chars = 0
        for i in range(len(pdf)):
            page = pdf[i]
            tp = page.get_textpage()
            total_chars += len(tp.get_text_range())

        has_text_layer = total_chars > 0

        if has_text_layer:
            pdf.close()
            existing_resolved = sum(
                1 for f in fields if f.get("bbox_source") == "pdf_text_layer"
            )
            results_summary.append({
                "file": file_name,
                "status": "skipped_text_layer",
                "existing_bboxes": existing_resolved,
            })
            continue

        # --- Scanned PDF: OCR only pages that have fields ---
        distinct_pages = sorted(set(f.get("page_index", 0) for f in fields))
        step(f"{file_name}: scanned, OCR pages {distinct_pages}")

        page_ocr = {}  # page_index -> list of {text, bbox_norm}
        dpi = 150
        for pi in distinct_pages:
            if pi >= len(pdf):
                continue
            page = pdf[pi]
            bitmap = page.render(scale=dpi / 72)
            pil_img = bitmap.to_pil()
            w, h = pil_img.size
            img_path = f"/tmp/ocr_p{pi}.png"
            pil_img.save(img_path)

            ocr_results = reader.readtext(img_path)
            words = []
            for bbox, text, conf in ocr_results:
                x0 = min(p[0] for p in bbox) / w
                y0 = min(p[1] for p in bbox) / h
                x1 = max(p[0] for p in bbox) / w
                y1 = max(p[1] for p in bbox) / h
                words.append({
                    "text": text,
                    "x0": x0, "y0": y0, "x1": x1, "y1": y1,
                    "conf": conf,
                })
            page_ocr[pi] = words
            step(f"  page {pi}: {len(words)} words detected")

        pdf.close()

        # --- Three-Strategy Matching Algorithm ---
        resolved = 0
        for f in fields:
            pi = f.get("page_index", 0)
            if pi not in page_ocr:
                if f.get("bbox_source") != "pdf_text_layer":
                    f["bbox_source"] = "no_ocr_page"
                continue

            words = page_ocr[pi]
            search_texts = []
            val = str(f.get("value", "")).strip()
            eq = str(f.get("evidence_quote", "")).strip()
            if val and val.lower() not in ("n/a", "none", ""):
                search_texts.append(val)
            if eq and eq.lower() not in ("n/a", "none", "") and eq != val:
                search_texts.append(eq)

            best_match = None
            best_score = 0

            for search_text in search_texts:
                search_lower = search_text.lower()[:80]  # cap search length

                # Strategy 1: exact substring match across consecutive words
                for i, word in enumerate(words):
                    word_text = word["text"].lower()
                    if word_text in search_lower or search_lower.startswith(word_text):
                        combined_text = ""
                        combined_boxes = []
                        for j in range(i, min(i + 15, len(words))):
                            if combined_text:
                                combined_text += " "
                            combined_text += words[j]["text"].lower()
                            combined_boxes.append(words[j])

                            # Check character-level overlap
                            overlap = 0
                            for k in range(min(len(combined_text), len(search_lower))):
                                if combined_text[k] == search_lower[k]:
                                    overlap += 1
                                else:
                                    break

                            score = overlap / max(len(search_lower), 1)
                            if score > best_score and score > 0.4:
                                best_score = score
                                best_match = {
                                    "x0": min(b["x0"] for b in combined_boxes),
                                    "y0": min(b["y0"] for b in combined_boxes),
                                    "x1": max(b["x1"] for b in combined_boxes),
                                    "y1": max(b["y1"] for b in combined_boxes),
                                }

                            if score > 0.85:
                                break
                    if best_score > 0.85:
                        break
                if best_score > 0.85:
                    break

            if best_match:
                coords = [
                    best_match["x0"], best_match["y0"],
                    best_match["x1"], best_match["y1"],
                ]
                clamped = [max(0, min(1, c)) for c in coords]
                f["bounding_box"] = ",".join([str(round(c, 4)) for c in clamped])
                f["bbox_source"] = "easyocr"
                resolved += 1
            else:
                if f.get("bbox_source") != "pdf_text_layer":
                    f["bbox_source"] = "ocr_no_match"

        extraction["fields"] = fields
        session.sql(
            "UPDATE <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS "
            "SET extraction_result = PARSE_JSON(?) WHERE file_name = ?",
            params=[json.dumps(extraction), file_name]
        ).collect()

        results_summary.append({
            "file": file_name,
            "status": "success",
            "resolved": resolved,
            "total": len(fields),
            "pages_ocrd": len(distinct_pages),
        })
        step(f"{file_name}: {resolved}/{len(fields)} fields resolved")

    step("Batch complete.")
    return json.dumps({
        "elapsed_seconds": round(time.time() - t0, 1),
        "docs": len(rows),
        "log": log,
        "results": results_summary,
    })
$$;


-- =============================================================================
-- PATH C: AI-Based Bounding Box Estimation (fallback)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- BATCH_RESOLVE_BBOXES_AI: Uses the vision model to estimate bbox coordinates
-- -----------------------------------------------------------------------------
-- For scanned PDFs where OCR matching fails, this procedure sends the PDF
-- back to claude-sonnet-4-6 and asks it to visually locate each field value.
-- Less precise than text-layer or OCR matching but works as a last resort.

CREATE OR REPLACE PROCEDURE BATCH_RESOLVE_BBOXES_AI(PDF_STAGE VARCHAR)
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
import re

def has_text_layer(session, pdf_stage, file_name):
    try:
        session.file.get(pdf_stage + "/" + file_name, "/tmp/")
    except:
        pass
    local_path = "/tmp/" + os.path.basename(file_name)
    if not os.path.exists(local_path):
        return True
    pdf = pdfium.PdfDocument(local_path)
    total_chars = 0
    for i in range(len(pdf)):
        page = pdf[i]
        tp = page.get_textpage()
        total_chars += len(tp.get_text_range())
    pdf.close()
    return total_chars > 0

def run(session, pdf_stage):
    rows = session.sql("""
        SELECT file_name, extraction_result
        FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS
        WHERE file_name != 'Custom_Invoice_2001.pdf'
    """).collect()

    results = []

    for row in rows:
        file_name = row[0]
        extraction = json.loads(row[1])
        fields = extraction.get("fields", [])

        not_found_count = sum(
            1 for f in fields
            if f.get("bbox_source") in ("not_found", None, "")
        )
        already_resolved = sum(
            1 for f in fields
            if f.get("bbox_source") in ("pdf_text_layer", "ai_estimated")
        )

        if not_found_count == 0:
            results.append({"file": file_name, "status": "skipped", "reason": "all resolved"})
            continue
        if already_resolved > 0 and not_found_count < len(fields):
            results.append({"file": file_name, "status": "skipped", "reason": "partially resolved"})
            continue

        try:
            if has_text_layer(session, pdf_stage, file_name):
                results.append({"file": file_name, "status": "skipped", "reason": "has text layer"})
                continue
        except Exception as e:
            results.append({"file": file_name, "status": "error", "reason": str(e)[:100]})
            continue

        # Build field descriptions
        field_descs = []
        for f in fields:
            val = str(f.get("value", ""))[:150]
            if val and val.lower() not in ("n/a", "none", ""):
                pi = f.get("page_index", 0)
                field_descs.append(f["label"] + ": " + val + " (page " + str(pi) + ")")

        if not field_descs:
            results.append({"file": file_name, "status": "no_fields"})
            continue

        fields_text = "; ".join(field_descs)

        prompt = (
            "Document {{0}}. For each field below, find where its value appears and return its "
            "bounding box as [x0,y0,x1,y1] normalized coordinates (0,0)=top-left (1,1)=bottom-right. "
            "Return ONLY a JSON array with label and bbox keys. No markdown fences. "
            "Fields: " + fields_text
        )
        safe_prompt = prompt.replace("'", "''")

        try:
            sql = (
                "SELECT AI_COMPLETE('claude-sonnet-4-6', "
                "PROMPT('" + safe_prompt + "', "
                "TO_FILE('@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE', '" + file_name + "')))::STRING AS r"
            )
            ai_row = session.sql(sql).collect()

            if not ai_row or ai_row[0][0] is None or str(ai_row[0][0]).strip() == "":
                results.append({"file": file_name, "status": "ai_empty"})
                continue

            bbox_text = str(ai_row[0][0])
            bbox_text = re.sub(r'^```[a-z]*\n?', '', bbox_text)
            bbox_text = re.sub(r'\n?```\s*$', '', bbox_text)
            bbox_text = bbox_text.strip()

            match = re.search(r'\[.*\]', bbox_text, re.DOTALL)
            if match:
                bbox_text = match.group(0)

            ai_bboxes = json.loads(bbox_text)
            bbox_map = {}
            for item in ai_bboxes:
                label = item.get("label", "")
                bbox = item.get("bbox", [])
                if label and isinstance(bbox, list) and len(bbox) == 4:
                    bbox_map[label] = [float(c) for c in bbox]

            resolved = 0
            for f in fields:
                if f["label"] in bbox_map:
                    coords = bbox_map[f["label"]]
                    if (all(-0.05 <= c <= 1.05 for c in coords)
                            and coords[2] > coords[0]
                            and coords[3] > coords[1]):
                        clamped = [max(0, min(1, c)) for c in coords]
                        f["bounding_box"] = ",".join(
                            [str(round(c, 4)) for c in clamped]
                        )
                        f["bbox_source"] = "ai_estimated"
                        resolved += 1
                    else:
                        f["bbox_source"] = "ai_invalid"
                else:
                    f["bbox_source"] = "not_found"

            extraction["fields"] = fields
            session.sql(
                "UPDATE <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS "
                "SET extraction_result = PARSE_JSON(?) WHERE file_name = ?",
                params=[json.dumps(extraction), file_name]
            ).collect()

            results.append({
                "file": file_name,
                "status": "success",
                "resolved": resolved,
                "total": len(fields),
            })

        except json.JSONDecodeError as e:
            results.append({
                "file": file_name,
                "status": "parse_error",
                "error": str(e)[:100],
                "raw": bbox_text[:200],
            })
        except Exception as e:
            results.append({
                "file": file_name,
                "status": "error",
                "error": str(e)[:200],
            })

    summary = {"total_docs": len(rows), "results": results}
    return json.dumps(summary)
$$;


-- =============================================================================
-- Utility Procedures
-- =============================================================================

-- -----------------------------------------------------------------------------
-- FIX_BBOX: Manual bounding box correction
-- -----------------------------------------------------------------------------
-- Used from the Streamlit review UI to manually set or correct a field's bbox.

CREATE OR REPLACE PROCEDURE FIX_BBOX(
    FILE_NAME VARCHAR,
    FIELD_LABEL VARCHAR,
    NEW_BBOX VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json

def run(session, file_name, field_label, new_bbox):
    row = session.sql(
        "SELECT extraction_result FROM <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS "
        "WHERE file_name = ?",
        params=[file_name]
    ).collect()
    if not row:
        return "not found"

    extraction = json.loads(row[0][0])
    for f in extraction.get("fields", []):
        if f.get("label") == field_label:
            f["bounding_box"] = new_bbox
            f["bbox_source"] = "manual"
            break

    session.sql(
        "UPDATE <YOUR_DATABASE>.<YOUR_SCHEMA>.EXTRACTION_RESULTS "
        "SET extraction_result = PARSE_JSON(?) WHERE file_name = ?",
        params=[json.dumps(extraction), file_name]
    ).collect()
    return "updated"
$$;


-- -----------------------------------------------------------------------------
-- DUMP_PDF_TEXT: Debug utility to inspect PDF text layer contents
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE DUMP_PDF_TEXT(PDF_STAGE VARCHAR, FILE_NAME VARCHAR)
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

def run(session, pdf_stage, file_name):
    session.file.get(pdf_stage + "/" + file_name, "/tmp/")
    local_path = "/tmp/" + os.path.basename(file_name)
    pdf = pdfium.PdfDocument(local_path)
    pages = []
    for i in range(len(pdf)):
        page = pdf[i]
        tp = page.get_textpage()
        text = tp.get_text_range()
        pages.append({"page": i, "char_count": len(text), "text_preview": text[:500]})
    pdf.close()
    return json.dumps({"page_count": len(pages), "pages": pages})
$$;


-- -----------------------------------------------------------------------------
-- FIND_TEXT_BBOX: Debug utility to search for specific text via OCR
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE FIND_TEXT_BBOX(
    PDF_STAGE VARCHAR, FILE_NAME VARCHAR, SEARCH_TEXT VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdfium2', 'easyocr', 'pillow')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import os, json
os.environ['HOME'] = '/tmp'
MODEL_DIR = "/tmp/.EasyOCR/model"
os.makedirs(MODEL_DIR, exist_ok=True)
os.makedirs("/tmp/.EasyOCR/user_network", exist_ok=True)

from PIL import Image
if not hasattr(Image, 'ANTIALIAS'):
    Image.ANTIALIAS = Image.LANCZOS

def run(session, pdf_stage, file_name, search_text):
    for mf in ["craft_mlt_25k.pth", "english_g2.pth", "latin.pth"]:
        p = os.path.join(MODEL_DIR, mf)
        if not os.path.exists(p):
            session.file.get(
                f"@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE/easyocr_models/{mf}", MODEL_DIR
            )

    import easyocr
    import pypdfium2 as pdfium

    reader = easyocr.Reader(
        ['en'], gpu=False,
        model_storage_directory=MODEL_DIR,
        user_network_directory="/tmp/.EasyOCR/user_network",
        download_enabled=False,
    )

    session.file.get(pdf_stage + "/" + file_name, "/tmp/")
    local_path = "/tmp/" + os.path.basename(file_name)
    pdf = pdfium.PdfDocument(local_path)
    page = pdf[0]
    bitmap = page.render(scale=150 / 72)
    pil_img = bitmap.to_pil()
    w, h = pil_img.size
    pdf.close()
    img_path = "/tmp/find_text.png"
    pil_img.save(img_path)

    results = reader.readtext(img_path)

    search_lower = search_text.lower()
    matches = []
    for i, (bbox, text, conf) in enumerate(results):
        if text.lower() in search_lower[:50]:
            x0 = min(p[0] for p in bbox) / w
            y0 = min(p[1] for p in bbox) / h
            x1 = max(p[0] for p in bbox) / w
            y1 = max(p[1] for p in bbox) / h
            matches.append({
                "idx": i,
                "text": text,
                "bbox": [round(x0, 4), round(y0, 4), round(x1, 4), round(y1, 4)],
            })

    return json.dumps({"matches": matches, "image_size": [w, h]})
$$;


-- -----------------------------------------------------------------------------
-- DUMP_OCR_REGION: Debug utility to inspect OCR words in a Y-axis region
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE DUMP_OCR_REGION(
    PDF_STAGE VARCHAR, FILE_NAME VARCHAR, Y_MIN FLOAT, Y_MAX FLOAT
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pypdfium2', 'easyocr', 'pillow')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import os, json
os.environ['HOME'] = '/tmp'
MODEL_DIR = "/tmp/.EasyOCR/model"
os.makedirs(MODEL_DIR, exist_ok=True)
os.makedirs("/tmp/.EasyOCR/user_network", exist_ok=True)
from PIL import Image
if not hasattr(Image, 'ANTIALIAS'):
    Image.ANTIALIAS = Image.LANCZOS

def run(session, pdf_stage, file_name, y_min, y_max):
    import easyocr, pypdfium2 as pdfium
    for mf in ["craft_mlt_25k.pth", "english_g2.pth", "latin.pth"]:
        p = os.path.join(MODEL_DIR, mf)
        if not os.path.exists(p):
            session.file.get(
                f"@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE/easyocr_models/{mf}", MODEL_DIR
            )
    reader = easyocr.Reader(
        ['en'], gpu=False,
        model_storage_directory=MODEL_DIR,
        user_network_directory="/tmp/.EasyOCR/user_network",
        download_enabled=False,
    )
    session.file.get(pdf_stage + "/" + file_name, "/tmp/")
    local_path = "/tmp/" + os.path.basename(file_name)
    pdf = pdfium.PdfDocument(local_path)
    bitmap = pdf[0].render(scale=150 / 72)
    pil_img = bitmap.to_pil()
    w, h = pil_img.size
    pdf.close()
    pil_img.save("/tmp/region.png")
    results = reader.readtext("/tmp/region.png")
    words = []
    for bbox, text, conf in results:
        ny0 = min(p[1] for p in bbox) / h
        ny1 = max(p[1] for p in bbox) / h
        if ny0 >= y_min and ny1 <= y_max:
            x0 = min(p[0] for p in bbox) / w
            x1 = max(p[0] for p in bbox) / w
            words.append({
                "text": text,
                "bbox": [round(x0, 4), round(ny0, 4), round(x1, 4), round(ny1, 4)],
            })
    return json.dumps({"words_in_region": words, "count": len(words)})
$$;


-- -----------------------------------------------------------------------------
-- CHECK_EASYOCR_MODELS: Verify EasyOCR package availability
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE CHECK_EASYOCR_MODELS()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'easyocr')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import os
os.environ['HOME'] = '/tmp'
os.makedirs('/tmp/.EasyOCR/model', exist_ok=True)
os.makedirs('/tmp/.EasyOCR/user_network', exist_ok=True)
import easyocr
import json

def run(session):
    models = easyocr.easyocr.detection_models
    recognizer = easyocr.easyocr.recognition_models
    return json.dumps({
        "detection_models": str(models),
        "recognition_models": str(recognizer),
    })
$$;


-- =============================================================================
-- Workflow: Running Bounding Box Resolution
-- =============================================================================

-- Step 1: Resolve text-layer PDFs (fast, runs in seconds)
-- CALL RESOLVE_BOUNDING_BOXES(
--     '@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE',
--     'Easy_Diabetes_Type2_01.pdf',
--     (SELECT extraction_result::STRING FROM EXTRACTION_RESULTS
--      WHERE file_name = 'Easy_Diabetes_Type2_01.pdf')
-- );

-- Step 2: Batch resolve all scanned PDFs via OCR
-- CALL BATCH_RESOLVE_BBOXES_OCR('@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE');

-- Step 3 (fallback): AI-estimated bboxes for remaining unresolved fields
-- CALL BATCH_RESOLVE_BBOXES_AI('@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE');

-- Step 4: Manual correction from the Streamlit UI
-- CALL FIX_BBOX('Hard_Scanned_01.pdf', 'patient_name', '0.12,0.05,0.45,0.08');
