import streamlit as st
import json
import os
import re
import pandas as pd
from PIL import Image, ImageDraw, ImageFont
if not hasattr(Image, 'ANTIALIAS'):
    Image.ANTIALIAS = Image.LANCZOS

st.set_page_config(page_title="Clinical Document Review", layout="wide")

# ---------------------------------------------------------------------------
# Custom CSS
# ---------------------------------------------------------------------------
st.markdown("""
<style>
    .group-header {
        background: linear-gradient(135deg, #0D1B2A 0%, #11567F 100%);
        color: #FFFFFF;
        padding: 8px 14px;
        border-radius: 6px;
        font-size: 14px;
        font-weight: 600;
        margin: 18px 0 10px 0;
        border-left: 4px solid #29B5E8;
    }
    .group-header:first-of-type { margin-top: 6px; }
    .legend-box {
        background: #F4F8FC;
        border: 1px solid #D0E4F0;
        border-radius: 6px;
        padding: 10px 14px;
        margin-bottom: 12px;
        font-size: 13px;
        line-height: 1.8;
    }
    .detail-card {
        background: #FFFFFF;
        border: 1px solid #D0E4F0;
        border-radius: 8px;
        padding: 14px 16px;
        margin-bottom: 10px;
        box-shadow: 0 1px 4px rgba(17,86,127,0.08);
    }
    .detail-card-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 6px;
    }
    .detail-card .field-name {
        font-weight: 700;
        color: #11567F;
        font-size: 14px;
    }
    .detail-card .field-value {
        color: #1A2942;
        font-size: 13px;
        margin: 4px 0;
        padding: 6px 10px;
        background: #F4F8FC;
        border-radius: 4px;
    }
    .detail-card .field-meta {
        color: #5A7898;
        font-size: 12px;
        margin-top: 6px;
        line-height: 1.6;
    }
    /* CSS hover tooltips */
    .hover-tip {
        position: relative;
        cursor: help;
        border-bottom: 1px dotted #5A7898;
    }
    .hover-tip::after {
        content: attr(data-tip);
        position: absolute;
        bottom: 100%;
        left: 0;
        background: #0D1B2A;
        color: #FFFFFF;
        padding: 8px 12px;
        border-radius: 6px;
        font-size: 12px;
        line-height: 1.5;
        width: 320px;
        max-height: 200px;
        overflow-y: auto;
        white-space: normal;
        opacity: 0;
        pointer-events: none;
        transition: opacity 0.15s;
        z-index: 9999;
        box-shadow: 0 4px 12px rgba(0,0,0,0.25);
    }
    .hover-tip:hover::after {
        opacity: 1;
        pointer-events: auto;
    }
    /* Superscript citation with hover */
    .cite-ref {
        position: relative;
        cursor: help;
        font-size: 0.7em;
        vertical-align: super;
        line-height: 0;
        color: #29B5E8;
        font-weight: 700;
        margin: 0 1px;
    }
    .cite-ref::after {
        content: attr(data-tip);
        position: absolute;
        bottom: 100%;
        left: 50%;
        transform: translateX(-50%);
        background: #0D1B2A;
        color: #FFFFFF;
        padding: 8px 12px;
        border-radius: 6px;
        font-size: 12px;
        font-weight: 400;
        line-height: 1.5;
        width: 300px;
        white-space: normal;
        opacity: 0;
        pointer-events: none;
        transition: opacity 0.15s;
        z-index: 9999;
        box-shadow: 0 4px 12px rgba(0,0,0,0.25);
    }
    .cite-ref:hover::after {
        opacity: 1;
        pointer-events: auto;
    }
</style>
""", unsafe_allow_html=True)

# ---------------------------------------------------------------------------
# Snowflake session
# ---------------------------------------------------------------------------

def get_session():
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        conn = st.connection("snowflake")
        return conn.session()

session = get_session()

DB_SCHEMA = "<YOUR_DATABASE>.<YOUR_SCHEMA>"
PDF_STAGE = f"@{DB_SCHEMA}.PDF_STAGE"
RESULTS_TABLE = f"{DB_SCHEMA}.EXTRACTION_RESULTS"

EXPECTED_FIELDS = [
    "patient_name", "date_of_birth", "medical_record_number",
    "provider_name", "date_of_service", "diagnosis",
    "diagnosis_codes", "diagnosis_descriptions", "hcc_relevant_conditions",
    "comorbidities", "medications", "lab_results",
    "procedure_codes",
    "diagnosis_specificity", "supporting_evidence", "documentation_gaps",
]

FIELD_GROUPS = {
    "Demographics": ["patient_name", "date_of_birth", "medical_record_number", "provider_name", "date_of_service"],
    "Clinical": ["diagnosis", "diagnosis_codes", "diagnosis_descriptions", "hcc_relevant_conditions", "comorbidities", "medications", "lab_results", "procedure_codes"],
    "Risk Adjustment": ["diagnosis_specificity", "supporting_evidence", "documentation_gaps"],
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def parse_extraction(raw):
    if isinstance(raw, dict):
        return raw
    text = str(raw)
    text = re.sub(r"^```json\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    return json.loads(text)


def render_pdf_page(pdf_stage_path, page_index=0, dpi=150):
    import pypdfium2 as pdfium
    session.file.get(f"{PDF_STAGE}/{pdf_stage_path}", "/tmp/")
    local_path = os.path.join("/tmp", os.path.basename(pdf_stage_path))
    pdf = pdfium.PdfDocument(local_path)
    page = pdf[page_index]
    bitmap = page.render(scale=dpi / 72)
    pil_image = bitmap.to_pil()
    pdf.close()
    return pil_image


def has_valid_bbox(field):
    bbox = field.get("bounding_box")
    if not bbox:
        return False
    if isinstance(bbox, str):
        parts = [float(x) for x in bbox.split(",")]
        return sum(parts) > 0
    if isinstance(bbox, list):
        return sum(bbox) > 0
    return False


def parse_bbox(field):
    bbox = field.get("bounding_box")
    if isinstance(bbox, str):
        return [float(x) for x in bbox.split(",")]
    if isinstance(bbox, list):
        return [float(x) for x in bbox]
    return [0, 0, 0, 0]


def draw_bounding_boxes(pil_image, fields):
    drawable = [f for f in fields if has_valid_bbox(f)]
    if not drawable:
        return pil_image

    img = pil_image.copy().convert("RGBA")
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw_overlay = ImageDraw.Draw(overlay)
    draw_img = ImageDraw.Draw(img)
    w, h = img.size

    CONFIDENCE_STYLES = {
        "high":   {"rgb": (0, 120, 0),   "outline": "#006400", "alpha": 40},
        "medium": {"rgb": (210, 160, 0), "outline": "#B8860B", "alpha": 70},
        "low":    {"rgb": (200, 30, 30), "outline": "#8B1A1A", "alpha": 80},
    }

    for field in drawable:
        bbox = parse_bbox(field)
        confidence = field.get("confidence", "high")
        style = CONFIDENCE_STYLES.get(confidence, CONFIDENCE_STYLES["high"])
        x0, y0, x1, y1 = bbox[0] * w, bbox[1] * h, bbox[2] * w, bbox[3] * h
        draw_overlay.rectangle(
            [x0, y0, x1, y1],
            fill=(*style["rgb"], style["alpha"]),
            outline=(*style["rgb"], 180),
            width=2,
        )
        font_size = max(10, int(h * 0.012))
        try:
            font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", font_size)
        except OSError:
            font = ImageFont.load_default()
        draw_img.text((x0, y0 - font_size - 2), field["label"], fill=style["outline"], font=font)

    img = Image.alpha_composite(img, overlay)
    return img.convert("RGB")


def confidence_indicator(confidence):
    return {"high": "\U0001F7E2", "medium": "\U0001F7E0", "low": "\U0001F534"}.get(confidence, "\u26AA")


def criterion_indicator(criterion):
    return {"yes": "\u2705", "no": "\u274C", "insufficient_documentation": "\u26A0\uFE0F"}.get(criterion, "\u2753")


# ---------------------------------------------------------------------------
# Load data (lightweight metadata only for sidebar filters)
# ---------------------------------------------------------------------------

@st.cache_data(ttl=300)
def load_results():
    df = session.sql(f"""
        SELECT result_id, file_name, extraction_result, extracted_at
        FROM {RESULTS_TABLE}
        ORDER BY file_name ASC
    """).to_pandas()
    if df.empty:
        return df
    def get_tier(name):
        if name.startswith("Easy"): return "Easy"
        if name.startswith("Medium"): return "Medium"
        if name.startswith("Hard"): return "Hard"
        return "Other"
    df["TIER"] = df["FILE_NAME"].apply(get_tier)
    def get_patient(row):
        try:
            ext = parse_extraction(row["EXTRACTION_RESULT"])
            for f in ext.get("fields", []):
                if f.get("label") == "patient_name":
                    return f.get("value", "Unknown")
        except:
            pass
        return "Unknown"
    df["PATIENT_NAME"] = df.apply(get_patient, axis=1)
    return df

results_df = load_results()

# ---------------------------------------------------------------------------
# Sidebar filters
# ---------------------------------------------------------------------------

st.sidebar.header("Filters")

tier_filter = st.sidebar.multiselect(
    "Document tier",
    ["Easy", "Medium", "Hard", "Other"],
    default=[],
    help="Select tiers to display, or check 'Show all' below",
)

show_all = st.sidebar.checkbox("Show all documents", value=False)

if not results_df.empty:
    patient_names = sorted(results_df["PATIENT_NAME"].unique())
    patient_filter = st.sidebar.selectbox(
        "Patient name",
        ["All patients"] + patient_names,
    )
else:
    patient_filter = "All patients"

search_query = st.sidebar.text_input("Search", placeholder="File name or patient name...")

date_range = st.sidebar.date_input("Date range", value=[], help="Filter by extraction date")

confidence_filter = st.sidebar.multiselect(
    "Confidence levels",
    ["high", "medium", "low"],
    default=["high", "medium", "low"],
)

# ---------------------------------------------------------------------------
# Apply filters
# ---------------------------------------------------------------------------

st.title("Clinical Document Review")

# ---------------------------------------------------------------------------
# Batch OCR bbox resolution (top-level action)
# ---------------------------------------------------------------------------
with st.expander("Batch OCR Bounding Box Resolution"):
    st.caption("Runs EasyOCR on scanned PDFs to get pixel-accurate bounding boxes. Only processes pages with extracted fields. Skips documents that already have text-layer bboxes.")
    if st.button("Run batch OCR"):
        import time
        os.environ['HOME'] = '/tmp'
        MODEL_DIR = "/tmp/.EasyOCR/model"
        os.makedirs(MODEL_DIR, exist_ok=True)
        os.makedirs("/tmp/.EasyOCR/user_network", exist_ok=True)

        progress = st.empty()
        log_area = st.empty()
        t0 = time.time()
        log_lines = []
        def step(msg):
            log_lines.append(f"[{time.time()-t0:6.1f}s] {msg}")
            log_area.code("\n".join(log_lines[-30:]), language="text")

        model_files = ["craft_mlt_25k.pth", "english_g2.pth", "latin.pth"]
        for mf in model_files:
            mf_path = os.path.join(MODEL_DIR, mf)
            if not os.path.exists(mf_path):
                session.file.get(f"@<YOUR_DATABASE>.<YOUR_SCHEMA>.PDF_STAGE/easyocr_models/{mf}", MODEL_DIR)
                step(f"{mf} copied")
            else:
                step(f"{mf} cached")

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

        all_rows = session.sql(f"""
            SELECT file_name, extraction_result
            FROM {RESULTS_TABLE}
            WHERE file_name != 'Custom_Invoice_2001.pdf'
        """).to_pandas()
        step(f"Loaded {len(all_rows)} documents.")

        total_resolved = 0
        total_skipped = 0
        total_ocr_pages = 0

        for aidx, r in all_rows.iterrows():
            file_name = r["FILE_NAME"]
            extraction = parse_extraction(r["EXTRACTION_RESULT"])
            fields = extraction.get("fields", [])

            try:
                session.file.get(f"{PDF_STAGE}/{file_name}", "/tmp/")
            except:
                pass
            local_path = os.path.join("/tmp", os.path.basename(file_name))
            if not os.path.exists(local_path):
                step(f"{file_name}: file not found, skipping")
                continue

            pdf = pdfium.PdfDocument(local_path)
            total_chars = 0
            for i in range(len(pdf)):
                tp = pdf[i].get_textpage()
                total_chars += len(tp.get_text_range())

            if total_chars > 0:
                pdf.close()
                total_skipped += 1
                continue

            # Check if already fully resolved by easyocr
            easyocr_count = sum(1 for f in fields if f.get("bbox_source") == "easyocr")
            needs_ocr = sum(1 for f in fields if f.get("bbox_source") in ("ai_estimated", "not_found", "ocr_no_match", None, ""))
            if needs_ocr == 0:
                pdf.close()
                total_skipped += 1
                continue

            distinct_pages = sorted(set(f.get("page_index", 0) for f in fields))
            progress.info(f"Processing {file_name} ({aidx+1}/{len(all_rows)}) — OCR on {len(distinct_pages)} page(s)...")

            page_ocr = {}
            for pi in distinct_pages:
                if pi >= len(pdf):
                    continue
                page = pdf[pi]
                bitmap = page.render(scale=150 / 72)
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
                    words.append({"text": text, "x0": x0, "y0": y0, "x1": x1, "y1": y1})
                page_ocr[pi] = words
                total_ocr_pages += 1
                step(f"  {file_name} page {pi}: {len(words)} words")

            pdf.close()

            doc_resolved = 0
            for f in fields:
                if f.get("bbox_source") == "easyocr":
                    doc_resolved += 1
                    continue

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
                    search_lower = search_text.lower()

                    # Strategy 1: Block-level substring match
                    # EasyOCR often returns full sentences/paragraphs as single detections.
                    # Check if the search text appears within any detection's text, or vice versa.
                    for word in words:
                        block_text = word["text"].lower()
                        # Check if search text is a substring of the block
                        if len(block_text) > 20 and search_lower[:60] in block_text:
                            score = min(len(search_lower), len(block_text)) / max(len(search_lower), 1)
                            if score > best_score:
                                best_score = max(score, 0.85)
                                best_match = {"x0": word["x0"], "y0": word["y0"], "x1": word["x1"], "y1": word["y1"]}
                        # Check if the block is a substring of the search text
                        elif len(block_text) > 20 and block_text in search_lower:
                            score = len(block_text) / max(len(search_lower), 1)
                            if score > best_score and score > 0.3:
                                best_score = score
                                best_match = {"x0": word["x0"], "y0": word["y0"], "x1": word["x1"], "y1": word["y1"]}
                    if best_score > 0.85:
                        break

                    # Strategy 2: Multi-block merge for long text spanning multiple detections
                    # Find the first block that contains the start of the search text,
                    # then merge consecutive blocks until we cover most of it.
                    if best_score < 0.85:
                        for i, word in enumerate(words):
                            block_text = word["text"].lower()
                            # Check if this block's text overlaps with the start of the search
                            if search_lower[:30] in block_text or block_text[:20] in search_lower[:40]:
                                combined_boxes = [word]
                                combined_text = block_text
                                for j in range(i + 1, min(i + 8, len(words))):
                                    next_block = words[j]
                                    # Only merge vertically adjacent blocks (within ~5% y distance)
                                    if next_block["y0"] - combined_boxes[-1]["y1"] < 0.05:
                                        combined_text += " " + next_block["text"].lower()
                                        combined_boxes.append(next_block)
                                        # Check how much of search text we've covered
                                        overlap_len = 0
                                        for k in range(min(len(combined_text), len(search_lower))):
                                            if combined_text[k] == search_lower[k]:
                                                overlap_len += 1
                                            else:
                                                break
                                        score = overlap_len / max(len(search_lower[:80]), 1)
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

                    # Strategy 3: Original word-by-word prefix matching (fallback)
                    if best_score < 0.5:
                        search_cap = search_lower[:80]
                        for i, word in enumerate(words):
                            word_text = word["text"].lower()
                            if word_text in search_cap or search_cap.startswith(word_text):
                                combined_text = ""
                                combined_boxes = []
                                for j in range(i, min(i + 15, len(words))):
                                    if combined_text:
                                        combined_text += " "
                                    combined_text += words[j]["text"].lower()
                                    combined_boxes.append(words[j])
                                    overlap = 0
                                    for k in range(min(len(combined_text), len(search_cap))):
                                        if combined_text[k] == search_cap[k]:
                                            overlap += 1
                                        else:
                                            break
                                    score = overlap / max(len(search_cap), 1)
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
                    coords = [best_match["x0"], best_match["y0"], best_match["x1"], best_match["y1"]]
                    clamped = [max(0, min(1, c)) for c in coords]
                    f["bounding_box"] = ",".join([str(round(c, 4)) for c in clamped])
                    f["bbox_source"] = "easyocr"
                    doc_resolved += 1
                else:
                    if f.get("bbox_source") not in ("pdf_text_layer", "easyocr"):
                        f["bbox_source"] = "ocr_no_match"

            extraction["fields"] = fields
            session.sql(
                f"UPDATE {RESULTS_TABLE} SET extraction_result = PARSE_JSON(?) WHERE file_name = ?",
                params=[json.dumps(extraction), file_name]
            ).collect()
            total_resolved += doc_resolved
            step(f"{file_name}: {doc_resolved}/{len(fields)} fields resolved")

        elapsed = time.time() - t0
        progress.empty()
        st.success(f"Batch complete in {elapsed:.0f}s. {total_ocr_pages} pages OCR'd, {total_resolved} fields resolved, {total_skipped} docs skipped.")
        step(f"Done. {total_ocr_pages} pages, {total_resolved} fields, {elapsed:.0f}s total.")

if results_df.empty:
    st.info("No documents found.")
    st.stop()

if not show_all and not tier_filter:
    st.info("Select a document tier in the sidebar or check **Show all documents** to begin.")
    st.stop()

filtered_df = results_df.copy()

if not show_all:
    filtered_df = filtered_df[filtered_df["TIER"].isin(tier_filter)]

if patient_filter != "All patients":
    filtered_df = filtered_df[filtered_df["PATIENT_NAME"] == patient_filter]

if search_query:
    mask = filtered_df["FILE_NAME"].str.contains(search_query, case=False, na=False)
    patient_mask = filtered_df["PATIENT_NAME"].str.contains(search_query, case=False, na=False)
    filtered_df = filtered_df[mask | patient_mask]

if isinstance(date_range, (list, tuple)) and len(date_range) == 2:
    start, end = date_range
    filtered_df["DATE_ONLY"] = filtered_df["EXTRACTED_AT"].dt.date
    filtered_df = filtered_df[(filtered_df["DATE_ONLY"] >= start) & (filtered_df["DATE_ONLY"] <= end)]
    filtered_df = filtered_df.drop(columns=["DATE_ONLY"])

st.caption(f"{len(filtered_df)} document(s)")

# ---------------------------------------------------------------------------
# Document list
# ---------------------------------------------------------------------------

for idx, row in filtered_df.iterrows():
    extraction = parse_extraction(row["EXTRACTION_RESULT"])
    fields = extraction.get("fields", [])
    fields_by_label = {f["label"]: f for f in fields}

    present_labels = set(f["label"] for f in fields)
    missing_fields = [l for l in EXPECTED_FIELDS if l not in present_labels]
    missing_count = len(missing_fields)

    passed = sum(1 for f in fields if f.get("criterion_met") == "yes")
    bbox_count = sum(1 for f in fields if has_valid_bbox(f))

    needs_review_set = set()
    doc_gap_labels = []
    medium_conf_labels = []
    low_conf_labels = []
    for f in fields:
        label = f["label"]
        cm = f.get("criterion_met", "")
        conf = f.get("confidence", "high")
        if cm in ("no", "insufficient_documentation"):
            needs_review_set.add(label)
            doc_gap_labels.append(label)
        if conf == "medium":
            medium_conf_labels.append(label)
        if conf == "low":
            needs_review_set.add(label)
            low_conf_labels.append(label)
    needs_review = len(needs_review_set)

    patient = row.get("PATIENT_NAME", "Unknown")
    dos = fields_by_label.get("date_of_service", {}).get("value", "")

    header_html = f'**{row["FILE_NAME"]}** | {patient}'
    if dos:
        header_html += f' | {dos}'

    with st.expander(header_html):

        m1, m2, m3, m4 = st.columns(4)
        m1.markdown(f'<div style="text-align:center;"><div style="font-size:12px;color:#1A2942;">Passed</div><div style="font-size:64px;font-weight:700;color:#29B5E8;line-height:1.0;">{passed}</div></div>', unsafe_allow_html=True)
        m2.markdown(f'<div style="text-align:center;"><div style="font-size:12px;color:#1A2942;">Needs Review</div><div style="font-size:64px;font-weight:700;color:#29B5E8;line-height:1.0;">{needs_review}</div></div>', unsafe_allow_html=True)
        m3.markdown(f'<div style="text-align:center;"><div style="font-size:12px;color:#1A2942;">Missing Fields</div><div style="font-size:64px;font-weight:700;color:#29B5E8;line-height:1.0;">{missing_count}</div></div>', unsafe_allow_html=True)
        m4.markdown(f'<div style="text-align:center;"><div style="font-size:12px;color:#1A2942;">Bounding Boxes</div><div style="font-size:64px;font-weight:700;color:#29B5E8;line-height:1.0;">{bbox_count}</div></div>', unsafe_allow_html=True)

        st.markdown('<div style="margin-top:20px;"></div>', unsafe_allow_html=True)

        gap_items = doc_gap_labels + missing_fields
        if gap_items:
            gap_text = ", ".join(gap_items)
            st.markdown(
                f'<div style="background:#F4F4F4;border-left:4px solid #999999;border-radius:6px;padding:10px 14px;margin-bottom:10px;font-size:13px;">'
                f'<strong>Documentation gaps</strong> ({len(gap_items)}): {gap_text}'
                f'</div>', unsafe_allow_html=True)

        if medium_conf_labels or low_conf_labels:
            parts = []
            if medium_conf_labels:
                parts.append(f"{len(medium_conf_labels)} medium")
            if low_conf_labels:
                parts.append(f"{len(low_conf_labels)} low")
            all_conf_labels = medium_conf_labels + low_conf_labels
            parts_text = ", ".join(parts)
            labels_text = ", ".join(all_conf_labels)
            st.markdown(
                f'<div style="background:#F4F4F4;border-left:4px solid #999999;border-radius:6px;padding:10px 14px;margin-bottom:10px;font-size:13px;">'
                f'<strong>Confidence issues</strong> ({parts_text}): {labels_text}'
                f'</div>', unsafe_allow_html=True)

        st.markdown('<div style="margin-top:20px;"></div>', unsafe_allow_html=True)

        tab_fields, tab_details, tab_document = st.tabs(["Fields", "Extraction Details", "Annotated Document"])

        # --- Fields tab ---
        with tab_fields:
            st.markdown("""<div class="legend-box">
                <strong>Legend:</strong>
                \U0001F7E2 High confidence &nbsp;&nbsp;
                \U0001F7E0 Medium confidence &nbsp;&nbsp;
                \U0001F534 Low confidence &nbsp;&nbsp;
                \u26A0\uFE0F Insufficient documentation &nbsp;&nbsp;
                \u274C Not found / criterion not met
            </div>""", unsafe_allow_html=True)

            for group_name, group_labels in FIELD_GROUPS.items():
                group_fields = [f for f in fields if f["label"] in group_labels]
                st.markdown(f'<div class="group-header">{group_name}</div>', unsafe_allow_html=True)
                if not group_fields:
                    group_missing = [l for l in group_labels if l in missing_fields]
                    if group_missing:
                        for mf in group_missing:
                            st.caption(f"{mf} \u274C not found in extraction")
                    continue
                cols = st.columns(min(len(group_fields), 4))
                for i, field in enumerate(group_fields):
                    with cols[i % 4]:
                        cm = field.get("criterion_met", "")
                        conf = field.get("confidence", "high")
                        rationale = field.get("rationale", "")
                        if cm == "yes":
                            indicator = confidence_indicator(conf)
                        else:
                            indicator = f"{confidence_indicator(conf)} {criterion_indicator(cm)}"
                        if rationale:
                            safe_rationale = rationale.replace('"', '&quot;').replace("'", '&#39;').replace('<', '&lt;').replace('>', '&gt;')[:400]
                            label_html = (
                                f'<span class="hover-tip" data-tip="{safe_rationale}">'
                                f'{field["label"]} {indicator}</span>'
                            )
                        else:
                            label_html = f'{field["label"]} {indicator}'
                        st.markdown(label_html, unsafe_allow_html=True)
                        field_val = field.get("value", "")
                        val_len = len(str(field_val))
                        field_key = f"field_{row['RESULT_ID']}_{field['label']}"
                        if val_len > 60:
                            num_lines = min(max(val_len // 50, 2), 8)
                            st.text_area(
                                field["label"],
                                value=field_val,
                                key=field_key,
                                height=num_lines * 28,
                                label_visibility="collapsed",
                            )
                        else:
                            st.text_input(
                                field["label"],
                                value=field_val,
                                key=field_key,
                                label_visibility="collapsed",
                            )
                # Show missing fields for this group
                group_missing = [l for l in group_labels if l in missing_fields]
                if group_missing:
                    for mf in group_missing:
                        st.caption(f"{mf} \u274C not found in extraction")

            if st.button("Save Corrections", key=f"save_{row['RESULT_ID']}"):
                updated_fields = []
                for field in fields:
                    updated_value = st.session_state.get(
                        f"field_{row['RESULT_ID']}_{field['label']}", field.get("value", "")
                    )
                    updated_fields.append({**field, "value": updated_value})
                updated_json = json.dumps({"fields": updated_fields}).replace("'", "''")
                session.sql(f"""
                    UPDATE {RESULTS_TABLE}
                    SET extraction_result = PARSE_JSON('{updated_json}')
                    WHERE result_id = {row['RESULT_ID']}
                """).collect()
                st.success("Corrections saved!")

        # --- Details tab: card layout ---
        with tab_details:
            for field in fields:
                cm = field.get("criterion_met", "")
                conf = field.get("confidence", "high")
                cm_icon = criterion_indicator(cm)
                conf_icon = confidence_indicator(conf)
                bbox_src = field.get("bbox_source", "")
                page_num = field.get("page_index", 0) + 1

                status_badges = f"{conf_icon} {conf}"
                if cm != "yes":
                    status_badges += f" &nbsp; {cm_icon} {cm}"

                value_text = field.get("value", "")
                rationale_text = field.get("rationale", "")
                evidence_text = field.get("evidence_quote", "")

                card_html = f"""<div class="detail-card">
                    <div class="detail-card-header">
                        <span class="field-name">{field['label']}</span>
                        <span style="font-size:12px;color:#5A7898;">Page {page_num} &middot; {bbox_src}</span>
                    </div>
                    <div style="font-size:13px;margin-bottom:4px;">{status_badges}</div>
                    <div class="field-value">{value_text}</div>"""

                if rationale_text:
                    card_html += f'<div class="field-meta"><strong>Rationale:</strong> {rationale_text}</div>'
                if evidence_text:
                    safe_evidence = evidence_text.replace("<", "&lt;").replace(">", "&gt;")
                    card_html += f'<div class="field-meta"><strong>Evidence:</strong> <em>&ldquo;{safe_evidence}&rdquo;</em></div>'

                card_html += "</div>"
                st.markdown(card_html, unsafe_allow_html=True)

        # --- Annotated document tab ---
        with tab_document:
            drawable_fields = [f for f in fields if has_valid_bbox(f)]
            if not drawable_fields:
                st.info("No bounding boxes resolved for this document.")

            pages_referenced = sorted(set(f.get("page_index", 0) for f in fields))
            if len(pages_referenced) > 1:
                selected_page = st.selectbox(
                    "Page", pages_referenced,
                    format_func=lambda x: f"Page {x + 1}",
                    key=f"page_{row['RESULT_ID']}"
                )
            else:
                selected_page = pages_referenced[0] if pages_referenced else 0

            page_fields = [f for f in drawable_fields if f.get("page_index", 0) == selected_page]

            try:
                page_img = render_pdf_page(row["FILE_NAME"], page_index=selected_page)
                if page_fields:
                    annotated = draw_bounding_boxes(page_img, page_fields)
                else:
                    annotated = page_img
                st.image(annotated, use_column_width=True)
            except Exception as e:
                st.error(f"Could not render PDF page: {e}")

# ---------------------------------------------------------------------------
# Cortex Search: Ad-hoc document Q&A
# ---------------------------------------------------------------------------

st.markdown("---")
st.subheader("Ask a Question About These Documents")
st.caption("Powered by Cortex Search. Answers are grounded in the indexed document text with citations.")

if "search_history" not in st.session_state:
    st.session_state.search_history = []

user_question = st.text_input("Ask a question", placeholder="e.g., What medications is Beth Barber taking?", key="search_q")

if user_question:
    with st.spinner("Searching documents..."):
        try:
            search_result = session.sql("""
                SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                    '<YOUR_DATABASE>.<YOUR_SCHEMA>.CLINICAL_DOC_SEARCH',
                    ?
                )
            """, params=[json.dumps({
                "query": user_question,
                "columns": ["file_name", "page_index", "patient_name", "diagnosis", "page_text"],
                "limit": 10
            })]).collect()

            if search_result and search_result[0][0]:
                raw = search_result[0][0]
                parsed = json.loads(raw) if isinstance(raw, str) else raw
                all_results = parsed.get("results", [])

                # Extract patient name from question if possible, filter results
                # Try to detect a patient name mentioned in the question
                import re as re_mod
                question_lower = user_question.lower()
                patient_names_in_corpus = set(str(r.get("patient_name", "")).lower() for r in all_results)
                matched_patient = None
                for pn in patient_names_in_corpus:
                    if pn and pn != "unknown" and pn.lower() in question_lower:
                        matched_patient = pn
                        break
                # Also check first/last name fragments
                if not matched_patient:
                    for pn in patient_names_in_corpus:
                        if pn and pn != "unknown":
                            name_parts = pn.split()
                            for part in name_parts:
                                if len(part) > 2 and part.lower() in question_lower:
                                    matched_patient = pn
                                    break
                        if matched_patient:
                            break

                if matched_patient:
                    results = [r for r in all_results if str(r.get("patient_name", "")).lower() == matched_patient]
                    if not results:
                        results = all_results[:5]
                    else:
                        results = results[:5]
                else:
                    results = all_results[:5]

                if not results:
                    st.info("No relevant documents found.")
                else:
                    # Build context for AI_COMPLETE to synthesize an answer
                    context_parts = []
                    for i, r in enumerate(results):
                        fn = str(r.get("file_name", ""))
                        pi = int(r.get("page_index", 0))
                        pn = str(r.get("patient_name", ""))
                        text = str(r.get("page_text", ""))[:1500]
                        context_parts.append(f"[Source {i+1}: {fn}, Page {pi+1}, Patient: {pn}]\n{text}")

                    context_block = "\n\n".join(context_parts)

                    prompt = f"""Answer the following question using ONLY the provided document excerpts. 
For each claim, include a citation [Source N] AND quote the specific text from the excerpt that supports your answer.
If the answer is not found in the excerpts, say so.

Question: {user_question}

Document excerpts:
{context_block}

Answer:"""

                    answer_row = session.sql(
                        "SELECT AI_COMPLETE('claude-sonnet-4-6', ?)::STRING AS answer",
                        params=[prompt]
                    ).collect()

                    answer_text = answer_row[0][0] if answer_row else "Could not generate answer."

                    # Build source lookup for inline citations — doc name, page, and relevant quote only
                    source_tips = {}
                    for i, r in enumerate(results):
                        fn = str(r.get("file_name", ""))
                        pi = int(r.get("page_index", 0))
                        full_text = str(r.get("page_text", ""))
                        # Find the most relevant snippet for the question
                        q_words = [w for w in user_question.lower().split() if len(w) > 3]
                        snippet = full_text[:120]
                        for qw in q_words:
                            idx_found = full_text.lower().find(qw)
                            if idx_found >= 0:
                                start = max(0, idx_found - 40)
                                snippet = full_text[start:start+150]
                                break
                        safe_snippet = snippet.replace('"', '&quot;').replace("'", '&#39;').replace('<', '&lt;').replace('>', '&gt;')
                        source_tips[i+1] = f"{fn}, Page {pi+1}: {safe_snippet}"

                    # Replace [Source N] with hoverable superscript citations
                    display_text = answer_text
                    for n in range(len(results), 0, -1):
                        tip = source_tips.get(n, "")
                        display_text = display_text.replace(
                            f"[Source {n}]",
                            f'<span class="cite-ref" data-tip="{tip}">[{n}]</span>'
                        )

                    st.markdown("**Answer:**")
                    st.markdown(display_text, unsafe_allow_html=True)

                    # Source list (compact) with relevant quoted text
                    with st.expander("View sources"):
                        for i, r in enumerate(results):
                            fn = str(r.get("file_name", ""))
                            pi = int(r.get("page_index", 0))
                            pn = str(r.get("patient_name", "Unknown"))
                            diag = str(r.get("diagnosis", ""))
                            full_text = str(r.get("page_text", ""))
                            # Extract a relevant snippet around key terms from the question
                            snippet = full_text[:300]
                            q_words = [w for w in user_question.lower().split() if len(w) > 3]
                            for qw in q_words:
                                idx_found = full_text.lower().find(qw)
                                if idx_found > 0:
                                    start = max(0, idx_found - 80)
                                    snippet = "..." + full_text[start:start+300] + "..."
                                    break
                            st.markdown(
                                f'<div class="detail-card">'
                                f'<div class="detail-card-header">'
                                f'<span class="field-name">[{i+1}] {fn} — Page {pi+1}</span>'
                                f'<span style="font-size:12px;color:#5A7898;">{pn} · {diag}</span>'
                                f'</div>'
                                f'<div class="field-meta">{snippet}</div>'
                                f'</div>',
                                unsafe_allow_html=True,
                            )
            else:
                st.warning("Search returned no results.")
        except Exception as e:
            st.error(f"Search failed: {e}")
