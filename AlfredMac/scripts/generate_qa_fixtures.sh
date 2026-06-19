#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$PROJECT_DIR/QA/Fixtures"
OUTPUT_DIR="$FIXTURE_DIR/Generated"
WORK_DIR="${TMPDIR:-/tmp}/alfred-qa-fixtures"

rm -rf "$WORK_DIR"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

require_zip() {
  if ! command -v zip >/dev/null 2>&1; then
    echo "zip is required to generate DOCX/PPTX fixtures." >&2
    exit 1
  fi
}

generate_pdf() {
  local source_txt="$WORK_DIR/sample-pdf.txt"
  local output_pdf="$OUTPUT_DIR/sample-text.pdf"

  cat > "$source_txt" <<'TXT'
Alfred QA PDF

This PDF contains embedded text for selected PDF reading tests.
It is generated locally and contains no sensitive content.

Expected behavior:
- Alfred reads it only after the user explicitly asks.
- Alfred does not persist extracted PDF text.
TXT

  if command -v cupsfilter >/dev/null 2>&1; then
    cupsfilter "$source_txt" > "$output_pdf" 2>/dev/null || {
      rm -f "$output_pdf"
      echo "Could not generate PDF with cupsfilter; skipping sample-text.pdf" >&2
    }
  else
    echo "cupsfilter not available; skipping sample-text.pdf" >&2
  fi
}

generate_docx() {
  local docx_dir="$WORK_DIR/docx"
  local output_docx="$OUTPUT_DIR/sample-document.docx"

  mkdir -p "$docx_dir/_rels" "$docx_dir/word/_rels" "$docx_dir/word"

  cat > "$docx_dir/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
XML

  cat > "$docx_dir/_rels/.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
XML

  cat > "$docx_dir/word/document.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Alfred QA DOCX</w:t></w:r></w:p>
    <w:p><w:r><w:t>This document verifies selected DOCX reading.</w:t></w:r></w:p>
    <w:p><w:r><w:t>Expected behavior: explicit request only, no persisted extracted text.</w:t></w:r></w:p>
    <w:sectPr/>
  </w:body>
</w:document>
XML

  cat > "$docx_dir/word/_rels/document.xml.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
XML

  (cd "$docx_dir" && zip -qr "$output_docx" .)
}

generate_pptx() {
  local pptx_dir="$WORK_DIR/pptx"
  local output_pptx="$OUTPUT_DIR/sample-deck.pptx"

  mkdir -p "$pptx_dir/_rels" "$pptx_dir/ppt/_rels" "$pptx_dir/ppt/slides/_rels" "$pptx_dir/ppt/slides" "$pptx_dir/ppt/slideLayouts/_rels" "$pptx_dir/ppt/slideLayouts" "$pptx_dir/ppt/slideMasters/_rels" "$pptx_dir/ppt/slideMasters" "$pptx_dir/ppt/theme"

  cat > "$pptx_dir/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
  <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
  <Override PartName="/ppt/slides/slide2.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
  <Override PartName="/ppt/slides/slide3.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
  <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
  <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
  <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
</Types>
XML

  cat > "$pptx_dir/_rels/.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
</Relationships>
XML

  cat > "$pptx_dir/ppt/presentation.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
  <p:sldIdLst>
    <p:sldId id="256" r:id="rId2"/>
    <p:sldId id="257" r:id="rId3"/>
    <p:sldId id="258" r:id="rId4"/>
  </p:sldIdLst>
  <p:sldSz cx="9144000" cy="5143500"/>
  <p:notesSz cx="6858000" cy="9144000"/>
</p:presentation>
XML

  cat > "$pptx_dir/ppt/_rels/presentation.xml.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide3.xml"/>
</Relationships>
XML

  cat > "$pptx_dir/ppt/slideMasters/slideMaster1.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>
  <p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst>
</p:sldMaster>
XML

  cat > "$pptx_dir/ppt/slideMasters/_rels/slideMaster1.xml.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
</Relationships>
XML

  cat > "$pptx_dir/ppt/slideLayouts/slideLayout1.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank">
  <p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>
</p:sldLayout>
XML

  cat > "$pptx_dir/ppt/slideLayouts/_rels/slideLayout1.xml.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
</Relationships>
XML

  cat > "$pptx_dir/ppt/theme/theme1.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Alfred QA"/>
XML

  for i in 1 2 3; do
    case "$i" in
      1) title="Alfred QA Deck"; body="This deck verifies selected PPTX reading." ;;
      2) title="Expected Behavior"; body="Alfred reads slide text only after an explicit request." ;;
      3) title="Privacy Assertion"; body="Extracted slide text is not persisted." ;;
    esac
    cat > "$pptx_dir/ppt/slides/slide${i}.xml" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <p:cSld><p:spTree>
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>
    <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>${title}</a:t></a:r></a:p></p:txBody></p:sp>
    <p:sp><p:nvSpPr><p:cNvPr id="3" name="Body"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>${body}</a:t></a:r></a:p></p:txBody></p:sp>
  </p:spTree></p:cSld>
</p:sld>
XML
    cat > "$pptx_dir/ppt/slides/_rels/slide${i}.xml.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
</Relationships>
XML
  done

  (cd "$pptx_dir" && zip -qr "$output_pptx" .)
}

generate_failure_fixtures() {
  printf 'This is intentionally not a valid DOCX package.\n' > "$OUTPUT_DIR/sample-malformed.docx"
  printf 'This is intentionally not a valid PPTX package.\n' > "$OUTPUT_DIR/sample-malformed.pptx"
  perl -e 'print "Alfred oversized text fixture line.\n" x 40000' > "$OUTPUT_DIR/sample-oversized.txt"
}

require_zip
generate_pdf
generate_docx
generate_pptx
generate_failure_fixtures

rm -rf "$WORK_DIR"

echo "Generated QA fixtures in:"
echo "  $OUTPUT_DIR"
echo
find "$OUTPUT_DIR" -maxdepth 1 -type f -print | sort
