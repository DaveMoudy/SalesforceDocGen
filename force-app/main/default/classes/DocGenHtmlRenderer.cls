/**
 * Converts processed DOCX XML (post-merge) to HTML suitable for Blob.toPdf().
 * Uses string-based XML parsing for DOCX-specific namespace handling.
 */
public with sharing class DocGenHtmlRenderer {

    private static final String HTML_PREFIX =
        '<html><head><style>' +
        '@page { size: letter; margin: 1in; }' +
        'body { font-family: Arial, sans-serif; font-size: 11pt; line-height: 1.15; color: #000; }' +
        'h1 { font-size: 20pt; font-weight: bold; margin: 0 0 6pt 0; }' +
        'h2 { font-size: 16pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h3 { font-size: 14pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h4 { font-size: 12pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h5 { font-size: 11pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h6 { font-size: 10pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h1, h2, h3, h4, h5, h6 { page-break-after: avoid; }' +
        'table { border-collapse: collapse; width: 100%; page-break-inside: auto; }' +
        'tr { page-break-inside: avoid; page-break-after: auto; }' +
        'td, th { padding: 4pt; vertical-align: top; }' +
        'p { margin: 0 0 8pt 0; orphans: 2; widows: 2; page-break-inside: avoid; }' +
        'img { max-width: 100%; }' +
        'ul, ol { margin: 0 0 8pt 0; padding-left: 36pt; }' +
        'li { margin: 0 0 2pt 0; page-break-inside: avoid; }' +
        'hr { border: none; border-top: 1px solid #000; margin: 6pt 0; }' +
        'sub { vertical-align: sub; font-size: 0.8em; }' +
        'sup { vertical-align: super; font-size: 0.8em; }' +
        '</style></head><body>';

    private static final String HTML_SUFFIX = '</body></html>';

    // Unit conversions
    private static final Decimal HALF_POINTS_TO_PT = 0.5;     // half-points → pt (÷2)
    private static final Decimal TWIPS_TO_PT = 0.05;           // twips → pt (÷20)
    private static final Decimal EMU_TO_PX = 0.000104987;      // EMU → px (÷9525)

    // Standard Word heading style IDs → HTML heading levels
    private static final Map<String, Integer> HEADING_STYLE_MAP = new Map<String, Integer>{
        'Heading1' => 1, 'heading1' => 1, 'Heading 1' => 1,
        'Heading2' => 2, 'heading2' => 2, 'Heading 2' => 2,
        'Heading3' => 3, 'heading3' => 3, 'Heading 3' => 3,
        'Heading4' => 4, 'heading4' => 4, 'Heading 4' => 4,
        'Heading5' => 5, 'heading5' => 5, 'Heading 5' => 5,
        'Heading6' => 6, 'heading6' => 6, 'Heading 6' => 6
    };

    // Word style IDs that imply a list item
    private static final Set<String> LIST_STYLE_IDS = new Set<String>{
        'ListParagraph', 'listparagraph', 'ListBullet', 'ListNumber',
        'List Paragraph', 'List Bullet', 'List Number'
    };

    /**
     * Converts processed DOCX XML content and associated images into an HTML string
     * suitable for Blob.toPdf().
     * @param documentXml The processed word/document.xml content (post-merge)
     * @param images Map of relationship IDs to base64-encoded image data
     * @return HTML string ready for Blob.toPdf()
     */
    public static String convertToHtml(String documentXml, Map<String, String> images) {
        if (String.isBlank(documentXml)) {
            return HTML_PREFIX + HTML_SUFFIX;
        }
        if (images == null) {
            images = new Map<String, String>();
        }

        String bodyContent = extractBodyContent(documentXml);
        String html = processBodyContent(bodyContent, images);

        return HTML_PREFIX + html + HTML_SUFFIX;
    }

    /**
     * Overload for when no images are present.
     */
    public static String convertToHtml(String documentXml) {
        return convertToHtml(documentXml, new Map<String, String>());
    }

    /**
     * Extracts content between <w:body> and </w:body> tags.
     */
    private static String extractBodyContent(String xml) {
        Integer bodyStart = xml.indexOf('<w:body');
        if (bodyStart == -1) return xml;

        Integer bodyContentStart = xml.indexOf('>', bodyStart) + 1;
        Integer bodyEnd = xml.lastIndexOf('</w:body>');
        if (bodyEnd == -1) return xml.substring(bodyContentStart);

        // Strip <w:sectPr> (section properties) from end of body
        String content = xml.substring(bodyContentStart, bodyEnd);
        Integer sectStart = content.lastIndexOf('<w:sectPr');
        if (sectStart != -1) {
            content = content.substring(0, sectStart);
        }
        return content;
    }

    /**
     * Processes body-level DOCX XML elements into HTML.
     * Handles consecutive list paragraphs by wrapping them in <ul>/<ol>.
     */
    private static String processBodyContent(String xml, Map<String, String> images) {
        // First pass: collect all paragraphs and tables in order
        List<String> elements = new List<String>();
        List<String> elementTypes = new List<String>(); // 'p' or 'tbl'
        Integer cursor = 0;

        while (cursor < xml.length()) {
            Integer nextTag = xml.indexOf('<', cursor);
            if (nextTag == -1) break;
            cursor = nextTag;

            if (xml.substring(cursor).startsWith('<w:tbl')) {
                Integer tblEnd = findClosingTag(xml, cursor, 'w:tbl');
                if (tblEnd != -1) {
                    elements.add(xml.substring(cursor, tblEnd));
                    elementTypes.add('tbl');
                    cursor = tblEnd;
                } else {
                    cursor++;
                }
            } else if (xml.substring(cursor).startsWith('<w:p ') || xml.substring(cursor).startsWith('<w:p>') || xml.substring(cursor).startsWith('<w:p/>')) {
                Integer pEnd = findClosingTag(xml, cursor, 'w:p');
                if (pEnd != -1) {
                    elements.add(xml.substring(cursor, pEnd));
                    elementTypes.add('p');
                    cursor = pEnd;
                } else {
                    cursor++;
                }
            } else {
                Integer tagEnd = xml.indexOf('>', cursor);
                if (tagEnd != -1) {
                    cursor = tagEnd + 1;
                } else {
                    break;
                }
            }
        }

        // Second pass: render elements, grouping consecutive list paragraphs
        String result = '';
        Integer i = 0;
        while (i < elements.size()) {
            if (elementTypes[i] == 'tbl') {
                result += processTable(elements[i], images);
                i++;
            } else {
                // Check if this paragraph is a list item
                ListInfo li = getListInfo(elements[i]);
                if (li.isList) {
                    // Collect consecutive list paragraphs
                    List<String> listItems = new List<String>();
                    Boolean isNumbered = li.isNumbered;
                    listItems.add(elements[i]);
                    Integer j = i + 1;
                    while (j < elements.size() && elementTypes[j] == 'p') {
                        ListInfo nextLi = getListInfo(elements[j]);
                        if (!nextLi.isList) break;
                        listItems.add(elements[j]);
                        j++;
                    }
                    result += renderList(listItems, isNumbered, images);
                    i = j;
                } else {
                    result += processParagraph(elements[i], images);
                    i++;
                }
            }
        }

        return result;
    }

    /**
     * Detects if a paragraph is a list item by checking for w:numPr or list-style pStyle.
     */
    private static ListInfo getListInfo(String pXml) {
        ListInfo li = new ListInfo();
        li.isList = false;
        li.isNumbered = false;

        String pPr = extractElement(pXml, 'w:pPr');
        if (String.isBlank(pPr)) return li;

        // Check for explicit numbering properties
        if (pPr.contains('<w:numPr')) {
            li.isList = true;
            // numId 0 means "no list" in OOXML
            String numId = extractAttr(pPr, 'w:numId', 'w:val');
            if (numId == '0') {
                li.isList = false;
                return li;
            }
            // Heuristic: odd numId = bullet, even = numbered (Word's common pattern)
            // Also check for ilvl to detect nested lists (not handled as nested HTML for simplicity)
            if (numId != null && numId.isNumeric()) {
                Integer nId = Integer.valueOf(numId);
                li.isNumbered = (Math.mod(nId, 2) == 0);
            }
            return li;
        }

        // Check for list paragraph style
        String pStyleVal = extractAttr(pPr, 'w:pStyle', 'w:val');
        if (pStyleVal != null && LIST_STYLE_IDS.contains(pStyleVal)) {
            li.isList = true;
            li.isNumbered = pStyleVal.containsIgnoreCase('Number');
        }

        return li;
    }

    /**
     * Renders a group of consecutive list paragraphs as <ul> or <ol>.
     */
    private static String renderList(List<String> listItems, Boolean isNumbered, Map<String, String> images) {
        String tag = isNumbered ? 'ol' : 'ul';
        String result = '<' + tag + '>';
        for (String pXml : listItems) {
            String content = processRuns(pXml, images);
            if (String.isBlank(content)) content = '&nbsp;';

            // Extract paragraph-level styles for the <li>
            String pPr = extractElement(pXml, 'w:pPr');
            String style = '';
            if (String.isNotBlank(pPr)) {
                style = parseParagraphStyle(pPr);
            }

            result += '<li' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>' + content + '</li>';
        }
        result += '</' + tag + '>';
        return result;
    }

    /**
     * Processes a <w:p> element into an HTML paragraph, heading, or horizontal rule.
     */
    private static String processParagraph(String pXml, Map<String, String> images) {
        String style = '';
        Integer headingLevel = 0;
        Boolean pageBreakBefore = false;
        Boolean isTitle = false;

        // Extract paragraph properties
        String pPr = extractElement(pXml, 'w:pPr');
        if (String.isNotBlank(pPr)) {
            style = parseParagraphStyle(pPr);

            // Check for heading style
            String pStyleVal = extractAttr(pPr, 'w:pStyle', 'w:val');
            if (pStyleVal != null) {
                if (HEADING_STYLE_MAP.containsKey(pStyleVal)) {
                    headingLevel = HEADING_STYLE_MAP.get(pStyleVal);
                } else if (pStyleVal == 'Title' || pStyleVal == 'title') {
                    isTitle = true;
                } else if (pStyleVal == 'Subtitle' || pStyleVal == 'subtitle') {
                    // Render subtitle as styled paragraph
                    style += (String.isNotBlank(style) ? ';' : '') + 'font-size:14pt;color:#595959';
                }
            }

            // Check for page break before
            if (pPr.contains('<w:pageBreakBefore/>') || pPr.contains('<w:pageBreakBefore ')) {
                pageBreakBefore = true;
            }
        }

        // Process runs
        String content = processRuns(pXml, images);

        // Check for page break in runs (w:br w:type="page")
        if (pXml.contains('w:type="page"') || pXml.contains('w:type=\'page\'')) {
            pageBreakBefore = true;
        }

        // Empty paragraph with bottom border = horizontal rule
        if (String.isBlank(content) && String.isNotBlank(pPr) && pPr.contains('<w:pBdr')) {
            if (pPr.contains('<w:bottom ')) {
                return (pageBreakBefore ? '<div style="page-break-before:always"></div>' : '') + '<hr/>';
            }
        }

        String pageBreakDiv = pageBreakBefore ? '<div style="page-break-before:always"></div>' : '';

        // Empty paragraph = line break
        if (String.isBlank(content)) {
            return pageBreakDiv + '<p' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>&nbsp;</p>';
        }

        // Heading
        if (headingLevel > 0) {
            String tag = 'h' + headingLevel;
            return pageBreakDiv + '<' + tag + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>' + content + '</' + tag + '>';
        }

        // Title style
        if (isTitle) {
            return pageBreakDiv + '<h1 style="font-size:26pt;font-weight:normal' +
                (String.isNotBlank(style) ? ';' + style : '') + '">' + content + '</h1>';
        }

        return pageBreakDiv + '<p' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>' + content + '</p>';
    }

    /**
     * Parses <w:pPr> into CSS style string.
     */
    private static String parseParagraphStyle(String pPr) {
        List<String> styles = new List<String>();

        // Alignment: <w:jc w:val="center"/>
        String jcVal = extractAttr(pPr, 'w:jc', 'w:val');
        if (jcVal != null) {
            if (jcVal == 'center') styles.add('text-align:center');
            else if (jcVal == 'right' || jcVal == 'end') styles.add('text-align:right');
            else if (jcVal == 'both' || jcVal == 'distribute') styles.add('text-align:justify');
        }

        // Spacing: <w:spacing w:before="120" w:after="120" w:line="240" w:lineRule="auto"/>
        String spacingBefore = extractAttr(pPr, 'w:spacing', 'w:before');
        if (spacingBefore != null && spacingBefore.isNumeric()) {
            styles.add('margin-top:' + twipsToPt(Integer.valueOf(spacingBefore)) + 'pt');
        }
        String spacingAfter = extractAttr(pPr, 'w:spacing', 'w:after');
        if (spacingAfter != null && spacingAfter.isNumeric()) {
            styles.add('margin-bottom:' + twipsToPt(Integer.valueOf(spacingAfter)) + 'pt');
        }

        // Line spacing: <w:spacing w:line="360" w:lineRule="auto"/>
        // In "auto" mode: 240 = single, 360 = 1.5, 480 = double
        // In "exact"/"atLeast" mode: value is in twips
        String lineSpacing = extractAttr(pPr, 'w:spacing', 'w:line');
        String lineRule = extractAttr(pPr, 'w:spacing', 'w:lineRule');
        if (lineSpacing != null && lineSpacing.isNumeric()) {
            Integer lineVal = Integer.valueOf(lineSpacing);
            if (lineRule == 'exact' || lineRule == 'atLeast') {
                styles.add('line-height:' + twipsToPt(lineVal) + 'pt');
            } else {
                // "auto" or default — value/240 gives the multiplier
                Decimal multiplier = lineVal / 240.0;
                styles.add('line-height:' + multiplier);
            }
        }

        // Indent: <w:ind w:left="720" w:right="0" w:firstLine="360" w:hanging="360"/>
        String indLeft = extractAttr(pPr, 'w:ind', 'w:left');
        String indHanging = extractAttr(pPr, 'w:ind', 'w:hanging');
        if (indLeft != null && indLeft.isNumeric()) {
            styles.add('margin-left:' + twipsToPt(Integer.valueOf(indLeft)) + 'pt');
        }
        String indRight = extractAttr(pPr, 'w:ind', 'w:right');
        if (indRight != null && indRight.isNumeric()) {
            styles.add('margin-right:' + twipsToPt(Integer.valueOf(indRight)) + 'pt');
        }
        String indFirst = extractAttr(pPr, 'w:ind', 'w:firstLine');
        if (indFirst != null && indFirst.isNumeric()) {
            styles.add('text-indent:' + twipsToPt(Integer.valueOf(indFirst)) + 'pt');
        }
        // Hanging indent: negative text-indent
        if (indHanging != null && indHanging.isNumeric()) {
            Decimal hangPt = twipsToPt(Integer.valueOf(indHanging));
            styles.add('text-indent:-' + hangPt + 'pt');
            // If no explicit left indent, add padding to compensate
            if (indLeft == null) {
                styles.add('padding-left:' + hangPt + 'pt');
            }
        }

        // Paragraph shading: <w:shd w:val="clear" w:fill="FFFF00"/>
        String pFill = extractAttr(pPr, 'w:shd', 'w:fill');
        if (pFill != null && pFill != 'auto') {
            styles.add('background-color:#' + pFill);
        }

        // Paragraph borders: <w:pBdr><w:top w:val="single" w:sz="4" w:color="000000"/>...
        if (pPr.contains('<w:pBdr')) {
            String pBdr = extractElement(pPr, 'w:pBdr');
            if (String.isNotBlank(pBdr)) {
                String topBdr = parseBorderSide(pBdr, 'w:top');
                String bottomBdr = parseBorderSide(pBdr, 'w:bottom');
                String leftBdr = parseBorderSide(pBdr, 'w:left');
                String rightBdr = parseBorderSide(pBdr, 'w:right');
                if (topBdr != null) styles.add('border-top:' + topBdr);
                if (bottomBdr != null) styles.add('border-bottom:' + bottomBdr);
                if (leftBdr != null) styles.add('border-left:' + leftBdr);
                if (rightBdr != null) styles.add('border-right:' + rightBdr);
                if (topBdr != null || bottomBdr != null || leftBdr != null || rightBdr != null) {
                    styles.add('padding:4pt');
                }
            }
        }

        // Keep with next (avoid page break after this paragraph)
        if (pPr.contains('<w:keepNext/>') || pPr.contains('<w:keepNext ')) {
            styles.add('page-break-after:avoid');
        }

        // Keep lines together (avoid page break inside this paragraph)
        if (pPr.contains('<w:keepLines/>') || pPr.contains('<w:keepLines ')) {
            styles.add('page-break-inside:avoid');
        }

        return String.join(styles, ';');
    }

    /**
     * Parses a single border side element into a CSS border shorthand.
     * E.g., <w:top w:val="single" w:sz="4" w:color="000000"/> → "1pt solid #000000"
     */
    private static String parseBorderSide(String bdrXml, String side) {
        String val = extractAttr(bdrXml, side, 'w:val');
        if (val == null || val == 'none' || val == 'nil') return null;

        String sz = extractAttr(bdrXml, side, 'w:sz');
        String color = extractAttr(bdrXml, side, 'w:color');

        // sz is in 8ths of a point
        Decimal widthPt = 1;
        if (sz != null && sz.isNumeric()) {
            widthPt = Integer.valueOf(sz) / 8.0;
            if (widthPt < 0.5) widthPt = 0.5;
        }

        String cssColor = '#000000';
        if (color != null && color != 'auto') {
            cssColor = '#' + color;
        }

        // Map common Word border styles to CSS
        String cssStyle = 'solid';
        if (val == 'dashed' || val == 'dashSmallGap') cssStyle = 'dashed';
        else if (val == 'dotted') cssStyle = 'dotted';
        else if (val == 'double') cssStyle = 'double';

        return widthPt + 'pt ' + cssStyle + ' ' + cssColor;
    }

    /**
     * Processes all <w:r> (run) elements within a paragraph.
     */
    private static String processRuns(String pXml, Map<String, String> images) {
        String result = '';
        Integer cursor = 0;

        while (cursor < pXml.length()) {
            Integer runStart = pXml.indexOf('<w:r>', cursor);
            Integer runStart2 = pXml.indexOf('<w:r ', cursor);

            // Also check for drawing elements outside runs
            Integer drawingStart = pXml.indexOf('<w:drawing>', cursor);
            Integer drawingStart2 = pXml.indexOf('<w:drawing ', cursor);

            // Also check for hyperlinks
            Integer hyperlinkStart = pXml.indexOf('<w:hyperlink', cursor);

            // Find the earliest element
            Integer nextRun = -1;
            if (runStart != -1 && runStart2 != -1) nextRun = Math.min(runStart, runStart2);
            else if (runStart != -1) nextRun = runStart;
            else if (runStart2 != -1) nextRun = runStart2;

            Integer nextDrawing = -1;
            if (drawingStart != -1 && drawingStart2 != -1) nextDrawing = Math.min(drawingStart, drawingStart2);
            else if (drawingStart != -1) nextDrawing = drawingStart;
            else if (drawingStart2 != -1) nextDrawing = drawingStart2;

            // Find earliest of run, drawing, hyperlink
            Integer nextElement = -1;
            String elementType = '';

            if (nextRun != -1) { nextElement = nextRun; elementType = 'run'; }
            if (nextDrawing != -1 && (nextElement == -1 || nextDrawing < nextElement)) {
                nextElement = nextDrawing; elementType = 'drawing';
            }
            if (hyperlinkStart != -1 && (nextElement == -1 || hyperlinkStart < nextElement)) {
                nextElement = hyperlinkStart; elementType = 'hyperlink';
            }

            if (nextElement == -1) break;

            if (elementType == 'run') {
                Integer runEnd = findClosingTag(pXml, nextRun, 'w:r');
                if (runEnd != -1) {
                    result += processRun(pXml.substring(nextRun, runEnd), images);
                    cursor = runEnd;
                } else {
                    cursor = nextRun + 1;
                }
            } else if (elementType == 'drawing') {
                Integer drawEnd = findClosingTag(pXml, nextDrawing, 'w:drawing');
                if (drawEnd != -1) {
                    result += processDrawing(pXml.substring(nextDrawing, drawEnd), images);
                    cursor = drawEnd;
                } else {
                    cursor = nextDrawing + 1;
                }
            } else if (elementType == 'hyperlink') {
                Integer hlEnd = findClosingTag(pXml, hyperlinkStart, 'w:hyperlink');
                if (hlEnd != -1) {
                    result += processHyperlink(pXml.substring(hyperlinkStart, hlEnd), images);
                    cursor = hlEnd;
                } else {
                    cursor = hyperlinkStart + 1;
                }
            }
        }

        return result;
    }

    /**
     * Processes a <w:hyperlink> element — extracts inner runs and wraps in <a> if possible.
     */
    private static String processHyperlink(String hlXml, Map<String, String> images) {
        // Hyperlinks may have an anchor (bookmark) or r:id (external link).
        // We can't resolve r:id without the .rels file, so render the text with underline styling.
        String innerContent = '';
        Integer cursor = 0;
        while (cursor < hlXml.length()) {
            Integer runStart = hlXml.indexOf('<w:r>', cursor);
            Integer runStart2 = hlXml.indexOf('<w:r ', cursor);
            Integer nextRun = -1;
            if (runStart != -1 && runStart2 != -1) nextRun = Math.min(runStart, runStart2);
            else if (runStart != -1) nextRun = runStart;
            else if (runStart2 != -1) nextRun = runStart2;
            if (nextRun == -1) break;

            Integer runEnd = findClosingTag(hlXml, nextRun, 'w:r');
            if (runEnd != -1) {
                innerContent += processRun(hlXml.substring(nextRun, runEnd), images);
                cursor = runEnd;
            } else {
                cursor = nextRun + 1;
            }
        }

        if (String.isBlank(innerContent)) return '';

        // Wrap in styled span to indicate link (blue + underline)
        return '<span style="color:#0563C1;text-decoration:underline">' + innerContent + '</span>';
    }

    /**
     * Processes a single <w:r> (run) element into an HTML <span>.
     */
    private static String processRun(String rXml, Map<String, String> images) {
        // Check for page break: <w:br w:type="page"/>
        if (rXml.contains('<w:br') && rXml.contains('w:type="page"')) {
            return '<div style="page-break-before:always"></div>';
        }

        // Check for column break
        if (rXml.contains('<w:br') && rXml.contains('w:type="column"')) {
            return '<br/>';
        }

        // Check for regular break
        if (rXml.contains('<w:br')) {
            // Only treat as line break if it's not a page/column break
            if (!rXml.contains('w:type=')) {
                return '<br/>';
            }
        }

        // Check for tab character
        if (rXml.contains('<w:tab/>') || rXml.contains('<w:tab ')) {
            // Render tabs as fixed-width space
            String tabResult = '<span style="display:inline-block;width:36pt"></span>';
            // Also process any text in the same run
            String text = extractTextContent(rXml);
            if (String.isNotBlank(text)) {
                String rPr = extractElement(rXml, 'w:rPr');
                if (String.isNotBlank(rPr)) {
                    String style = parseRunStyle(rPr);
                    tabResult += '<span style="' + style + '">' + text.escapeHtml4() + '</span>';
                } else {
                    tabResult += text.escapeHtml4();
                }
            }
            return tabResult;
        }

        // Check for drawing (image)
        if (rXml.contains('<w:drawing')) {
            Integer drawStart = rXml.indexOf('<w:drawing');
            Integer drawEnd = findClosingTag(rXml, drawStart, 'w:drawing');
            if (drawEnd != -1) {
                return processDrawing(rXml.substring(drawStart, drawEnd), images);
            }
        }

        // Extract text (use isEmpty, not isBlank — preserve whitespace-only runs like spaces between bold merge fields)
        String text = extractTextContent(rXml);
        if (String.isEmpty(text)) return '';

        // Extract run properties
        String rPr = extractElement(rXml, 'w:rPr');
        if (String.isBlank(rPr)) {
            return text.escapeHtml4();
        }

        String style = parseRunStyle(rPr);
        String openTags = '';
        String closeTags = '';

        // Bold
        if (rPr.contains('<w:b/>') || rPr.contains('<w:b ')) {
            openTags += '<b>';
            closeTags = '</b>' + closeTags;
        }
        // Italic
        if (rPr.contains('<w:i/>') || rPr.contains('<w:i ')) {
            openTags += '<i>';
            closeTags = '</i>' + closeTags;
        }
        // Underline
        if (rPr.contains('<w:u ')) {
            openTags += '<u>';
            closeTags = '</u>' + closeTags;
        }
        // Strikethrough
        if (rPr.contains('<w:strike/>') || rPr.contains('<w:strike ')) {
            openTags += '<s>';
            closeTags = '</s>' + closeTags;
        }
        // Superscript / Subscript
        String vertAlign = extractAttr(rPr, 'w:vertAlign', 'w:val');
        if (vertAlign == 'superscript') {
            openTags += '<sup>';
            closeTags = '</sup>' + closeTags;
        } else if (vertAlign == 'subscript') {
            openTags += '<sub>';
            closeTags = '</sub>' + closeTags;
        }
        // All caps
        if (rPr.contains('<w:caps/>') || rPr.contains('<w:caps ')) {
            text = text.toUpperCase();
        }
        // Small caps — approximate with uppercase + smaller font
        if (rPr.contains('<w:smallCaps/>') || rPr.contains('<w:smallCaps ')) {
            text = text.toUpperCase();
            style += (String.isNotBlank(style) ? ';' : '') + 'font-variant:small-caps';
        }

        if (String.isNotBlank(style)) {
            return '<span style="' + style + '">' + openTags + text.escapeHtml4() + closeTags + '</span>';
        }
        return openTags + text.escapeHtml4() + closeTags;
    }

    /**
     * Parses <w:rPr> into CSS style string.
     */
    private static String parseRunStyle(String rPr) {
        List<String> styles = new List<String>();

        // Font: <w:rFonts w:ascii="Calibri"/>
        String font = extractAttr(rPr, 'w:rFonts', 'w:ascii');
        if (font == null) font = extractAttr(rPr, 'w:rFonts', 'w:hAnsi');
        if (font != null) {
            styles.add('font-family:\'' + font.escapeHtml4() + '\',sans-serif');
        }

        // Font size: <w:sz w:val="24"/> (half-points)
        String sz = extractAttr(rPr, 'w:sz', 'w:val');
        if (sz != null && sz.isNumeric()) {
            Decimal ptSize = Integer.valueOf(sz) * HALF_POINTS_TO_PT;
            styles.add('font-size:' + ptSize + 'pt');
        }

        // Color: <w:color w:val="FF0000"/>
        String color = extractAttr(rPr, 'w:color', 'w:val');
        if (color != null && color != 'auto') {
            styles.add('color:#' + color);
        }

        // Highlight: <w:highlight w:val="yellow"/>
        String highlight = extractAttr(rPr, 'w:highlight', 'w:val');
        if (highlight != null) {
            styles.add('background-color:' + highlight);
        }

        // Shading (different from highlight): <w:shd w:val="clear" w:fill="FFFF00"/>
        String shdFill = extractAttr(rPr, 'w:shd', 'w:fill');
        if (shdFill != null && shdFill != 'auto' && highlight == null) {
            styles.add('background-color:#' + shdFill);
        }

        // Letter spacing: <w:spacing w:val="20"/> (in twips)
        String letterSpacing = extractAttr(rPr, 'w:spacing', 'w:val');
        if (letterSpacing != null && letterSpacing.isNumeric()) {
            Integer lsVal = Integer.valueOf(letterSpacing);
            if (lsVal != 0) {
                styles.add('letter-spacing:' + twipsToPt(lsVal) + 'pt');
            }
        }

        return String.join(styles, ';');
    }

    /**
     * Processes a <w:tbl> element into an HTML <table>.
     */
    private static String processTable(String tblXml, Map<String, String> images) {
        String tableStyle = 'border-collapse:collapse;width:100%';
        Boolean hasBorders = false;

        // Parse table properties
        String tblPr = extractElement(tblXml, 'w:tblPr');
        if (String.isNotBlank(tblPr)) {
            // Table width
            String tblW = extractAttr(tblPr, 'w:tblW', 'w:w');
            String tblWType = extractAttr(tblPr, 'w:tblW', 'w:type');
            if (tblW != null && tblWType == 'pct') {
                Decimal pct = Integer.valueOf(tblW) / 50.0; // OOXML pct is in 50ths of a percent
                tableStyle = 'border-collapse:collapse;width:' + pct + '%';
            }

            // Table borders
            if (tblPr.contains('<w:tblBorders')) {
                hasBorders = true;
                tableStyle += ';border:1px solid #000';
            }

            // Table alignment
            String tblJc = extractAttr(tblPr, 'w:jc', 'w:val');
            if (tblJc == 'center') {
                tableStyle += ';margin-left:auto;margin-right:auto';
            } else if (tblJc == 'right' || tblJc == 'end') {
                tableStyle += ';margin-left:auto';
            }

            // Table cell margins (default padding for all cells)
            String tblCellMar = extractElement(tblPr, 'w:tblCellMar');
            if (String.isNotBlank(tblCellMar)) {
                String topMar = extractAttr(tblCellMar, 'w:top', 'w:w');
                String bottomMar = extractAttr(tblCellMar, 'w:bottom', 'w:w');
                String leftMar = extractAttr(tblCellMar, 'w:left', 'w:w');
                if (leftMar == null) leftMar = extractAttr(tblCellMar, 'w:start', 'w:w');
                String rightMar = extractAttr(tblCellMar, 'w:right', 'w:w');
                if (rightMar == null) rightMar = extractAttr(tblCellMar, 'w:end', 'w:w');
                // These values will be used on cells; for now they affect the table-level default
            }
        }

        // Process rows
        String rows = '';
        Integer cursor = 0;
        while (cursor < tblXml.length()) {
            Integer trStart = tblXml.indexOf('<w:tr', cursor);
            if (trStart == -1) break;

            Integer trEnd = findClosingTag(tblXml, trStart, 'w:tr');
            if (trEnd == -1) break;

            rows += processTableRow(tblXml.substring(trStart, trEnd), images, tblPr, hasBorders);
            cursor = trEnd;
        }

        return '<table style="' + tableStyle + '">' + rows + '</table>';
    }

    /**
     * Processes a <w:tr> element into an HTML <tr>.
     */
    private static String processTableRow(String trXml, Map<String, String> images, String tblPr, Boolean hasBorders) {
        String cells = '';
        Integer cursor = 0;

        // Check for header row
        String trPr = extractElement(trXml, 'w:trPr');
        Boolean isHeader = (String.isNotBlank(trPr) && (trPr.contains('<w:tblHeader/>') || trPr.contains('<w:tblHeader ')));

        while (cursor < trXml.length()) {
            Integer tcStart = trXml.indexOf('<w:tc', cursor);
            if (tcStart == -1) break;

            Integer tcEnd = findClosingTag(trXml, tcStart, 'w:tc');
            if (tcEnd == -1) break;

            cells += processTableCell(trXml.substring(tcStart, tcEnd), images, tblPr, hasBorders, isHeader);
            cursor = tcEnd;
        }

        return '<tr>' + cells + '</tr>';
    }

    /**
     * Processes a <w:tc> element into an HTML <td> or <th>.
     */
    private static String processTableCell(String tcXml, Map<String, String> images, String tblPr, Boolean hasBorders, Boolean isHeader) {
        List<String> styles = new List<String>();
        Integer colspan = 0;

        // Cell properties
        String tcPr = extractElement(tcXml, 'w:tcPr');
        if (String.isNotBlank(tcPr)) {
            // Cell width: <w:tcW w:w="2880" w:type="dxa"/>
            String tcW = extractAttr(tcPr, 'w:tcW', 'w:w');
            String tcWType = extractAttr(tcPr, 'w:tcW', 'w:type');
            if (tcW != null && tcW.isNumeric()) {
                if (tcWType == 'pct') {
                    Decimal pct = Integer.valueOf(tcW) / 50.0;
                    styles.add('width:' + pct + '%');
                } else {
                    // dxa = twips
                    styles.add('width:' + twipsToPt(Integer.valueOf(tcW)) + 'pt');
                }
            }

            // Shading: <w:shd w:val="clear" w:fill="E2EFDA"/>
            String fill = extractAttr(tcPr, 'w:shd', 'w:fill');
            if (fill != null && fill != 'auto') {
                styles.add('background-color:#' + fill);
            }

            // Vertical alignment: <w:vAlign w:val="center"/>
            String vAlign = extractAttr(tcPr, 'w:vAlign', 'w:val');
            if (vAlign != null) {
                styles.add('vertical-align:' + vAlign);
            }

            // Cell-specific borders: <w:tcBorders>
            if (tcPr.contains('<w:tcBorders')) {
                String tcBdr = extractElement(tcPr, 'w:tcBorders');
                if (String.isNotBlank(tcBdr)) {
                    String topBdr = parseBorderSide(tcBdr, 'w:top');
                    String bottomBdr = parseBorderSide(tcBdr, 'w:bottom');
                    String leftBdr = parseBorderSide(tcBdr, 'w:left');
                    if (leftBdr == null) leftBdr = parseBorderSide(tcBdr, 'w:start');
                    String rightBdr = parseBorderSide(tcBdr, 'w:right');
                    if (rightBdr == null) rightBdr = parseBorderSide(tcBdr, 'w:end');
                    if (topBdr != null) styles.add('border-top:' + topBdr);
                    if (bottomBdr != null) styles.add('border-bottom:' + bottomBdr);
                    if (leftBdr != null) styles.add('border-left:' + leftBdr);
                    if (rightBdr != null) styles.add('border-right:' + rightBdr);
                }
            } else if (hasBorders) {
                // Fall back to table-level borders
                styles.add('border:1px solid #000');
            }

            // Column span: <w:gridSpan w:val="2"/>
            String gridSpan = extractAttr(tcPr, 'w:gridSpan', 'w:val');
            if (gridSpan != null && gridSpan.isNumeric()) {
                colspan = Integer.valueOf(gridSpan);
            }

            // Cell padding: <w:tcMar>
            if (tcPr.contains('<w:tcMar')) {
                String tcMar = extractElement(tcPr, 'w:tcMar');
                if (String.isNotBlank(tcMar)) {
                    String cellPadTop = extractAttr(tcMar, 'w:top', 'w:w');
                    String cellPadBottom = extractAttr(tcMar, 'w:bottom', 'w:w');
                    String cellPadLeft = extractAttr(tcMar, 'w:left', 'w:w');
                    if (cellPadLeft == null) cellPadLeft = extractAttr(tcMar, 'w:start', 'w:w');
                    String cellPadRight = extractAttr(tcMar, 'w:right', 'w:w');
                    if (cellPadRight == null) cellPadRight = extractAttr(tcMar, 'w:end', 'w:w');

                    List<String> padParts = new List<String>();
                    padParts.add((cellPadTop != null && cellPadTop.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadTop)) + 'pt' : '4pt');
                    padParts.add((cellPadRight != null && cellPadRight.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadRight)) + 'pt' : '4pt');
                    padParts.add((cellPadBottom != null && cellPadBottom.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadBottom)) + 'pt' : '4pt');
                    padParts.add((cellPadLeft != null && cellPadLeft.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadLeft)) + 'pt' : '4pt');
                    styles.add('padding:' + String.join(padParts, ' '));
                }
            }
        } else if (hasBorders) {
            styles.add('border:1px solid #000');
        }

        // Process cell content (paragraphs)
        String content = processBodyContent(tcXml, images);

        String styleStr = String.join(styles, ';');
        String tag = isHeader ? 'th' : 'td';
        String attrs = '';
        if (String.isNotBlank(styleStr)) attrs += ' style="' + styleStr + '"';
        if (colspan > 1) attrs += ' colspan="' + colspan + '"';

        return '<' + tag + attrs + '>' + content + '</' + tag + '>';
    }

    /**
     * Processes a <w:drawing> element into an HTML <img> tag.
     */
    private static String processDrawing(String drawingXml, Map<String, String> images) {
        // Extract dimensions from <wp:extent cx="..." cy="..."/>
        Integer widthPx = 200; // default
        Integer heightPx = 150; // default

        String cx = extractAttr(drawingXml, 'wp:extent', 'cx');
        String cy = extractAttr(drawingXml, 'wp:extent', 'cy');
        if (cx == null) cx = extractAttr(drawingXml, 'a:ext', 'cx');
        if (cy == null) cy = extractAttr(drawingXml, 'a:ext', 'cy');

        if (cx != null && cx.isNumeric()) {
            widthPx = Math.round(Long.valueOf(cx) * EMU_TO_PX);
        }
        if (cy != null && cy.isNumeric()) {
            heightPx = Math.round(Long.valueOf(cy) * EMU_TO_PX);
        }

        // Extract relationship ID from <a:blip r:embed="rIdImg1"/>
        String relId = extractAttr(drawingXml, 'a:blip', 'r:embed');
        if (relId == null) return '';

        String imageValue = images.get(relId);
        if (imageValue == null) return '';

        // If the value is a URL (Salesforce content path or absolute URL), use directly as img src
        if (imageValue.startsWith('/sfc/') || imageValue.startsWith('/servlet/') ||
            imageValue.startsWith('/apex/') || imageValue.startsWithIgnoreCase('http')) {
            return '<img src="' + imageValue + '" ' +
                   'width="' + widthPx + '" height="' + heightPx + '" ' +
                   'style="max-width:100%" />';
        }

        // Otherwise treat as base64 — determine MIME type and create data URI
        String mimeType = 'image/png';
        if (imageValue.startsWith('/9j/') || imageValue.startsWith('/9J/')) {
            mimeType = 'image/jpeg';
        }

        return '<img src="data:' + mimeType + ';base64,' + imageValue + '" ' +
               'width="' + widthPx + '" height="' + heightPx + '" ' +
               'style="max-width:100%" />';
    }

    // ===== XML PARSING UTILITIES =====

    /**
     * Extracts all text content from <w:t> elements within the given XML.
     */
    private static String extractTextContent(String xml) {
        String result = '';
        Integer cursor = 0;

        while (cursor < xml.length()) {
            Integer tStart = xml.indexOf('<w:t', cursor);
            if (tStart == -1) break;

            // Skip self-closing <w:t/>
            Integer tagEnd = xml.indexOf('>', tStart);
            if (tagEnd == -1) break;

            if (xml.substring(tagEnd - 1, tagEnd) == '/') {
                cursor = tagEnd + 1;
                continue;
            }

            Integer contentStart = tagEnd + 1;
            Integer tEnd = xml.indexOf('</w:t>', contentStart);
            if (tEnd == -1) break;

            result += xml.substring(contentStart, tEnd);
            cursor = tEnd + 6; // length of </w:t>
        }

        // Unescape XML entities so downstream escapeHtml4() doesn't double-encode
        result = result.replace('&amp;', '&');
        result = result.replace('&lt;', '<');
        result = result.replace('&gt;', '>');
        result = result.replace('&apos;', '\'');
        result = result.replace('&quot;', '"');

        return result;
    }

    /**
     * Extracts the first occurrence of an element's content.
     * Returns the content including the element's own tags.
     */
    private static String extractElement(String xml, String tagName) {
        Integer start = xml.indexOf('<' + tagName);
        if (start == -1) return null;

        // Check for self-closing
        Integer tagEnd = xml.indexOf('>', start);
        if (tagEnd == -1) return null;
        if (xml.substring(tagEnd - 1, tagEnd) == '/') {
            return xml.substring(start, tagEnd + 1);
        }

        Integer endPos = findClosingTag(xml, start, tagName);
        if (endPos == -1) return xml.substring(start, tagEnd + 1);
        return xml.substring(start, endPos);
    }

    /**
     * Extracts an attribute value from a specific element.
     * E.g., extractAttr(xml, 'w:jc', 'w:val') from <w:jc w:val="center"/>
     */
    private static String extractAttr(String xml, String tagName, String attrName) {
        Integer tagStart = xml.indexOf('<' + tagName);
        if (tagStart == -1) return null;

        Integer tagEnd = xml.indexOf('>', tagStart);
        if (tagEnd == -1) return null;

        String tagContent = xml.substring(tagStart, tagEnd + 1);
        Integer attrStart = tagContent.indexOf(attrName + '="');
        if (attrStart == -1) return null;

        Integer valueStart = attrStart + attrName.length() + 2; // skip attr="
        Integer valueEnd = tagContent.indexOf('"', valueStart);
        if (valueEnd == -1) return null;

        return tagContent.substring(valueStart, valueEnd);
    }

    /**
     * Finds the position after the closing tag, handling nesting.
     * Returns the position after </tagName>.
     */
    private static Integer findClosingTag(String xml, Integer startPos, String tagName) {
        String openTag = '<' + tagName;
        String closeTag = '</' + tagName + '>';
        Integer depth = 0;
        Integer cursor = startPos;

        while (cursor < xml.length()) {
            Integer nextOpen = xml.indexOf(openTag, cursor);
            Integer nextClose = xml.indexOf(closeTag, cursor);

            if (nextClose == -1) return -1;

            if (nextOpen != -1 && nextOpen < nextClose) {
                // Check if it's actually the tag (not a prefix match like <w:tblPr matching <w:tbl)
                Integer afterOpen = nextOpen + openTag.length();
                if (afterOpen < xml.length()) {
                    String nextChar = xml.substring(afterOpen, afterOpen + 1);
                    if (nextChar == '>' || nextChar == ' ' || nextChar == '/') {
                        depth++;
                        cursor = afterOpen;
                        continue;
                    }
                }
                // Not a real match, skip past it
                cursor = afterOpen;
            } else {
                depth--;
                if (depth == 0) {
                    return nextClose + closeTag.length();
                }
                cursor = nextClose + closeTag.length();
            }
        }
        return -1;
    }

    /**
     * Converts twips to points.
     */
    private static Decimal twipsToPt(Integer twips) {
        return twips * TWIPS_TO_PT;
    }

    // Inner class for list detection
    private class ListInfo {
        Boolean isList;
        Boolean isNumbered;
    }
}