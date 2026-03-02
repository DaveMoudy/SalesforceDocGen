public with sharing class DocGenService {

    // Collector for images to inject after XML processing
    private static List<Map<String, Object>> pendingImages = new List<Map<String, Object>>();
    private static Integer imageCounter = 0;

    /**
     * Processes a template with record data and returns the result as a Map containing
     * the document Blob, title, output format, and template type. Does NOT save to record.
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId) {
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            dataMap = DocGenController.generateDocumentData(templateId, recordId);
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String outputFormat = (String) dataMap.get('outputFormat');
        String templateType = (String) dataMap.get('templateType');

        if (base64File == null) throw new DocGenException('Template file content is missing.');

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject)dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        String contentTypesXml = null;
        String relsXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            Boolean isTargetXml = false;
            if (templateType == 'Word') {
                isTargetXml = name == 'word/document.xml' ||
                              (name.startsWith('word/header') && name.endsWith('.xml')) ||
                              (name.startsWith('word/footer') && name.endsWith('.xml'));
            } else if (templateType == 'PowerPoint') {
                isTargetXml = name.startsWith('ppt/slides/slide') && name.endsWith('.xml');
            }

            if (isTargetXml) {
                Blob content = reader.extract(name);
                String xml = content.toString();
                xml = mergeRunsInTags(xml);
                xml = processXml(xml, recordDataMap);
                writer.addEntry(name, Blob.valueOf(xml));
            } else if (name == '[Content_Types].xml') {
                contentTypesXml = reader.extract(name).toString();
            } else if (name == 'word/_rels/document.xml.rels') {
                relsXml = reader.extract(name).toString();
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        // Inject collected images into the ZIP
        if (!pendingImages.isEmpty()) {
            if (contentTypesXml != null) {
                if (!contentTypesXml.contains('Extension="png"')) {
                    contentTypesXml = contentTypesXml.replace('</Types>', '<Default Extension="png" ContentType="image/png"/></Types>');
                }
                if (!contentTypesXml.contains('Extension="jpeg"') && !contentTypesXml.contains('Extension="jpg"')) {
                    contentTypesXml = contentTypesXml.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
            }
            if (relsXml != null) {
                for (Map<String, Object> img : pendingImages) {
                    String relId = (String) img.get('relId');
                    String fName = (String) img.get('fileName');
                    String newRel = '<Relationship Id="' + relId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + fName + '"/>';
                    relsXml = relsXml.replace('</Relationships>', newRel + '</Relationships>');
                }
            }
            for (Map<String, Object> img : pendingImages) {
                String fName = (String) img.get('fileName');
                Blob imageBlob = (Blob) img.get('blob');
                writer.addEntry('word/media/' + fName, imageBlob);
            }
        }

        if (contentTypesXml != null) {
            writer.addEntry('[Content_Types].xml', Blob.valueOf(contentTypesXml));
        }
        if (relsXml != null) {
            writer.addEntry('word/_rels/document.xml.rels', Blob.valueOf(relsXml));
        }

        Blob resultBlob = writer.getArchive();
        String docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
        if (docTitle == null) docTitle = (String) resolveValue(recordDataMap, 'Name');

        return new Map<String, Object>{
            'blob' => resultBlob,
            'title' => docTitle,
            'outputFormat' => outputFormat,
            'templateType' => templateType
        };
    }

    /**
     * Processes a template and saves the result as a ContentVersion attached to the record.
     */
    public static Id generateDocument(Id templateId, Id recordId) {
        Map<String, Object> result = processDocument(templateId, recordId);
        Blob resultBlob = (Blob) result.get('blob');
        String docTitle = (String) result.get('title');
        String outputFormat = (String) result.get('outputFormat');
        String templateType = (String) result.get('templateType');

        return saveFile(resultBlob, docTitle, recordId, outputFormat, templateType);
    }

    /**
     * Preprocesses DOCX XML to merge text runs where template tags {tag} are split
     * across multiple <w:r><w:t> elements by Word's formatting engine.
     * After merging, processXml can find complete tags like {#QuoteLineItems}.
     */
    private static String mergeRunsInTags(String xml) {
        // 1. Find all <w:t...>text</w:t> elements and their text content positions
        Pattern wtPattern = Pattern.compile('<w:t(?:\\s[^>]*)?>([^<]*)</w:t>');
        Matcher m = wtPattern.matcher(xml);

        List<Integer> contentStarts = new List<Integer>();
        List<Integer> contentEnds = new List<Integer>();
        List<String> contents = new List<String>();

        while (m.find()) {
            contentStarts.add(m.start(1));
            contentEnds.add(m.end(1));
            contents.add(m.group(1));
        }

        if (contents.isEmpty()) return xml;

        // 2. Build flat text (concatenation of all <w:t> text) and segment offsets
        Integer totalLen = 0;
        List<Integer> flatOffsets = new List<Integer>();
        for (String c : contents) {
            flatOffsets.add(totalLen);
            totalLen += c.length();
        }
        String flatText = String.join(contents, '');

        // 3. Find tags where { and } are in different segments
        Boolean modified = false;
        Integer pos = 0;

        while (pos < flatText.length()) {
            Integer openBrace = flatText.indexOf('{', pos);
            if (openBrace == -1) break;
            Integer closeBrace = flatText.indexOf('}', openBrace);
            if (closeBrace == -1) break;

            // Determine which segments contain the { and }
            Integer openSeg = -1;
            Integer closeSeg = -1;
            for (Integer i = 0; i < contents.size(); i++) {
                Integer segStart = flatOffsets.get(i);
                Integer segEnd = segStart + contents.get(i).length();
                if (openBrace >= segStart && openBrace < segEnd) openSeg = i;
                if (closeBrace >= segStart && closeBrace < segEnd) closeSeg = i;
            }

            if (openSeg != -1 && closeSeg != -1 && openSeg != closeSeg) {
                modified = true;
                // Merge all text from openSeg through closeSeg into openSeg
                String merged = '';
                for (Integer i = openSeg; i <= closeSeg; i++) {
                    merged += contents.get(i);
                }
                contents.set(openSeg, merged);
                for (Integer i = openSeg + 1; i <= closeSeg; i++) {
                    contents.set(i, '');
                }
                // Recalculate flat offsets after merge
                totalLen = 0;
                for (Integer i = 0; i < contents.size(); i++) {
                    flatOffsets.set(i, totalLen);
                    totalLen += contents.get(i).length();
                }
                flatText = String.join(contents, '');
            }

            pos = closeBrace + 1;
        }

        if (!modified) return xml;

        // 4. Reconstruct XML by replacing text content (work backwards to maintain positions)
        String result = xml;
        for (Integer i = contents.size() - 1; i >= 0; i--) {
            String original = result.substring(contentStarts.get(i), contentEnds.get(i));
            if (!contents.get(i).equals(original)) {
                result = result.substring(0, contentStarts.get(i)) + contents.get(i) + result.substring(contentEnds.get(i));
            }
        }

        return result;
    }

    private static String processXml(String xml, Map<String, Object> data) {
        String output = '';
        Integer len = xml.length();
        Integer cursor = 0;
        
        while (cursor < len) {
            Integer nextTag = xml.indexOf('{', cursor);
            if (nextTag == -1) {
                output += xml.substring(cursor);
                break; 
            }
            output += xml.substring(cursor, nextTag);
            cursor = nextTag;
            
            Integer tagClose = xml.indexOf('}', cursor);
            if (tagClose == -1) {
                output += xml.substring(cursor);
                break;
            }
            
            String rawTag = xml.substring(cursor + 1, tagClose); 
            String tagContent = rawTag.trim();
            
            if (tagContent.startsWith('#')) {
                String key = tagContent.substring(1).trim();
                Integer sectionEnd = findBalancedEnd(xml, tagClose + 1, key);
                System.debug('DocGen processXml: Found section {#' + key + '}, sectionEnd=' + sectionEnd);

                if (sectionEnd == -1) {
                    System.debug('DocGen processXml: WARNING - no matching {/' + key + '} found! Tag output as literal.');
                    output += '{' + rawTag + '}';
                    cursor = tagClose + 1;
                } else {
                    // Default: Content between tags
                    Integer contentStart = tagClose + 1;
                    Integer contentEnd = sectionEnd;
                    String innerXml = xml.substring(contentStart, contentEnd);
                    
                    // Smart Table Row Expansion
                    // Check if we are inside a TR and if the loop is fully contained in it
                    Integer trStart = xml.lastIndexOf('<w:tr ', cursor);
                    if (trStart == -1) trStart = xml.lastIndexOf('<w:tr>', cursor);

                    // Find matching TR End
                    Integer trEnd = -1;
                    if (trStart != -1) {
                         // Verify trStart is actually an ancestor of our cursor (no </w:tr> between trStart and cursor)
                         Boolean trClosesBefore = xml.substring(trStart, cursor).contains('</w:tr>');

                         trEnd = xml.indexOf('</w:tr>', trStart);
                         Integer closeTagEnd = xml.indexOf('}', sectionEnd);

                         if (trClosesBefore) {
                             // The <w:tr> we found already closed before our tag - NOT our ancestor
                             cursor = xml.indexOf('}', sectionEnd) + 1;
                         } else if (trEnd > closeTagEnd) {
                             // Yes, the loop is fully inside this TR.
                             // Now, checking if we should expand.
                             // Expand if the start tag and end tag are in the SAME TR (implied by above)
                             // AND if we think it's intended (always true for better UX?)
                             
                             // CAUTION: If user meant cell-repetition, valid, but rare.
                             // We assume Row Repetition is preferred.
                             
                             // Redefine Inner XML to include the TR
                             // And strip the tags from it.
                             
                             contentStart = trStart;
                             contentEnd = trEnd + 7; // Length of </w:tr>
                             innerXml = xml.substring(contentStart, contentEnd);

                             String startTagFull = '{' + rawTag + '}';
                             innerXml = innerXml.replace(startTagFull, '');

                             String endTagFull = xml.substring(sectionEnd, closeTagEnd + 1);
                             innerXml = innerXml.replace(endTagFull, '');

                             // Backtrack output to remove the TR prefix already appended
                             Integer overlap = cursor - contentStart;
                             if (overlap > 0) {
                                  output = output.substring(0, output.length() - overlap);
                             }

                             cursor = contentEnd;
                        } else {
                            // Loop spans across TRs or is outside TR?
                            // Default behavior (keep tags inside, repeat content)
                             cursor = xml.indexOf('}', sectionEnd) + 1;
                        }
                    } else {
                        cursor = xml.indexOf('}', sectionEnd) + 1;
                    }

                    // Process Data
                    Object val = resolveValue(data, key);
                    String sectionResult = '';
                    System.debug('DocGen processXml: Section {#' + key + '} val type: ' + (val == null ? 'NULL' : (val instanceof Map<String, Object> ? 'Map' : (val instanceof List<Object> ? 'List' : 'Other'))));

                    if (val instanceof Boolean && (Boolean)val) {
                         sectionResult = processXml(innerXml, data);
                    } else if (val instanceof Map<String, Object>) {
                        Map<String, Object> mapVal = (Map<String, Object>) val;
                         if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                            List<Object> records = (List<Object>) mapVal.get('records');
                            System.debug('DocGen processXml: Loop {#' + key + '} iterating ' + records.size() + ' records');
                            for (Object item : records) {
                                if (item instanceof Map<String, Object>) sectionResult += processXml(innerXml, (Map<String, Object>) item);
                            }
                        } else {
                             sectionResult = processXml(innerXml, mapVal);
                        }
                    } else if (val instanceof List<Object>) {
                         List<Object> listVal = (List<Object>) val;
                         System.debug('DocGen processXml: Loop {#' + key + '} iterating ' + listVal.size() + ' items (direct list)');
                         for (Object item : listVal) {
                              if (item instanceof Map<String, Object>) sectionResult += processXml(innerXml, (Map<String, Object>) item);
                         }
                    } else if (val != null) {
                         sectionResult = processXml(innerXml, data);
                    }
                    System.debug('DocGen processXml: Section {#' + key + '} result length: ' + sectionResult.length());
                    output += sectionResult;
                }
                
            } else if (tagContent.startsWith('/')) {
                output += '{' + rawTag + '}';
                cursor = tagClose + 1;
            } else if (tagContent.startsWith('%')) {
                // Image tag: {%FieldName} or {%FieldName:WxH} — inject image with optional pixel dimensions
                String imageSpec = tagContent.substring(1).trim();
                String imageField = imageSpec;
                Integer imgWidthPx = null;
                Integer imgHeightPx = null;

                // Parse optional size suffix :WxH (pixels)
                if (imageSpec.contains(':')) {
                    List<String> parts = imageSpec.split(':', 2);
                    imageField = parts[0].trim();
                    String sizeStr = parts[1].trim().toLowerCase();
                    if (sizeStr.contains('x')) {
                        List<String> dims = sizeStr.split('x');
                        if (dims.size() == 2 && dims[0].isNumeric() && dims[1].isNumeric()) {
                            imgWidthPx = Integer.valueOf(dims[0]);
                            imgHeightPx = Integer.valueOf(dims[1]);
                        }
                    }
                }

                Object val = resolveValue(data, imageField);
                System.debug('DocGen processXml: Image tag {%' + imageField + '} val null?: ' + (val == null) + ', val length: ' + (val != null ? String.valueOf(val).length() : 0));
                if (val != null) {
                    String imageXml = buildImageXml(String.valueOf(val), imgWidthPx, imgHeightPx);
                    System.debug('DocGen processXml: buildImageXml returned ' + (imageXml == null ? 'NULL' : 'XML length ' + imageXml.length()));
                    if (imageXml != null) {
                        output += imageXml;
                    }
                }
                cursor = tagClose + 1;
            } else {
                // Parse optional date format suffix: {FieldName:format}
                String fieldName = tagContent;
                String dateFormat = null;
                if (tagContent.contains(':')) {
                    Integer colonIdx = tagContent.indexOf(':');
                    fieldName = tagContent.substring(0, colonIdx).trim();
                    dateFormat = tagContent.substring(colonIdx + 1).trim();
                }

                Object val = resolveValue(data, fieldName);
                if (val != null) {
                    String strVal;
                    // Apply date/time formatting if a format was specified
                    if (dateFormat != null && val instanceof DateTime) {
                        strVal = ((DateTime) val).format(dateFormat);
                    } else if (dateFormat != null && val instanceof Date) {
                        DateTime dt = DateTime.newInstance((Date) val, Time.newInstance(0, 0, 0, 0));
                        strVal = dt.format(dateFormat);
                    } else {
                        strVal = String.valueOf(val);
                    }
                    // Rich text containing images — inject as VML image
                    if (strVal.containsIgnoreCase('<img')) {
                        String imageXml = buildImageXml(strVal);
                        if (imageXml != null) {
                            output += imageXml;
                        }
                    }
                    // Strip remaining HTML tags (paragraphs, spans, divs) and output as text
                    else if (strVal.contains('<') && strVal.contains('>') && (strVal.containsIgnoreCase('<p') || strVal.containsIgnoreCase('<div') || strVal.containsIgnoreCase('<span') || strVal.containsIgnoreCase('<br'))) {
                        strVal = strVal.stripHtmlTags();
                        output += strVal.escapeXml();
                    }
                    else {
                        output += strVal.escapeXml();
                    }
                }
                cursor = tagClose + 1;
            }
        }
        return output;
    }
    
    private static Integer findBalancedEnd(String xml, Integer startSearch, String key) {
        Integer depth = 1;
        Integer cursor = startSearch;
        while (cursor < xml.length()) {
            Integer nextStart = xml.indexOf('{', cursor);
            if (nextStart == -1) return -1;
            Integer nextClose = xml.indexOf('}', nextStart);
            if (nextClose == -1) return -1;
            String content = xml.substring(nextStart + 1, nextClose).trim();
            if (content.equals('#' + key)) depth++;
            else if (content.equals('/' + key)) {
                depth--;
                if (depth == 0) return nextStart;
            }
            cursor = nextClose + 1;
        }
        return -1;
    }
    
    private static Object resolveValue(Map<String, Object> data, String path) {
        if (data == null) return null;
        List<String> parts = path.split('\\.');
        Object current = data;
        
        for (String part : parts) {
            if (current instanceof Map<String, Object>) {
                Map<String, Object> currentMap = (Map<String, Object>) current;
                if (currentMap.containsKey(part)) {
                    current = currentMap.get(part);
                } else {
                    // Try case-insensitive comparison
                    Boolean found = false;
                    for (String key : currentMap.keySet()) {
                        if (key.equalsIgnoreCase(part)) {
                            current = currentMap.get(key);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        System.debug('DocGen Debug: Key "' + part + '" not found in Map. Keys: ' + currentMap.keySet());
                        return null;
                    }
                }
            } else if (current instanceof SObject) {
                 SObject sobj = (SObject) current;
                 try {
                     current = sobj.get(part);
                 } catch(Exception e) { 
                     System.debug('DocGen Debug: Error retrieving field "' + part + '" from SObject ' + sobj + ': ' + e.getMessage());
                     return null; 
                 }
            } else {
                return null;
            }
            if (current == null) return null;
        }
        return current;
    }
    
    /**
     * Builds OOXML drawing markup for an image and registers it for ZIP injection.
     * Accepts: HTML with <img> tags, Salesforce file references (/servlet/..., /sfc/..., refid=...),
     * ContentVersion IDs, or base64 data URIs.
     */
    private static String buildImageXml(String fieldValue) {
        return buildImageXml(fieldValue, null, null);
    }

    private static String buildImageXml(String fieldValue, Integer widthPx, Integer heightPx) {
        if (String.isBlank(fieldValue)) return null;
        System.debug('DocGen buildImageXml: input length=' + fieldValue.length() + ', starts with: ' + fieldValue.left(100));

        Blob imageBlob = null;
        String ext = 'png';

        try {
            // 1. Rich text HTML containing <img> tags
            if (fieldValue.containsIgnoreCase('<img')) {
                System.debug('DocGen buildImageXml: detected <img>, calling extractImageFromHtml');
                imageBlob = extractImageFromHtml(fieldValue);
                System.debug('DocGen buildImageXml: extractImageFromHtml returned ' + (imageBlob == null ? 'NULL' : 'blob size ' + imageBlob.size()));
            }
            // 2. Base64 data URI
            else if (fieldValue.startsWith('data:image/')) {
                String base64Part = fieldValue.substringAfter(',');
                if (fieldValue.containsIgnoreCase('jpeg') || fieldValue.containsIgnoreCase('jpg')) ext = 'jpeg';
                imageBlob = EncodingUtil.base64Decode(base64Part);
            }
            // 3. Raw base64 (no data URI prefix)
            else if (fieldValue.length() > 100 && !fieldValue.contains('/') && !fieldValue.contains(' ')) {
                imageBlob = EncodingUtil.base64Decode(fieldValue);
            }
            // 4. ContentVersion ID (starts with 068)
            else if (fieldValue.startsWith('068') && fieldValue.length() >= 15) {
                List<ContentVersion> cvs = [SELECT VersionData, FileExtension FROM ContentVersion WHERE Id = :fieldValue WITH SYSTEM_MODE LIMIT 1];
                if (!cvs.isEmpty()) {
                    imageBlob = cvs[0].VersionData;
                    if (cvs[0].FileExtension != null) ext = cvs[0].FileExtension.toLowerCase();
                }
            }
            // 5. Salesforce file URL containing refid (rich text image reference)
            else if (fieldValue.containsIgnoreCase('refid=')) {
                String refId = fieldValue.substringAfterLast('refid=').substringBefore('&');
                if (String.isBlank(refId)) refId = fieldValue.substringAfterLast('refid=');
                imageBlob = fetchSalesforceImage(refId);
            }
            // 6. Salesforce servlet/sfc URL
            else if (fieldValue.containsIgnoreCase('/servlet/') || fieldValue.containsIgnoreCase('/sfc/')) {
                String docId = fieldValue.substringAfterLast('/');
                if (docId.contains('?')) docId = docId.substringBefore('?');
                imageBlob = fetchSalesforceImage(docId);
            }
            // 7. Generic HTTPS URL — attempt to fetch as image (reject plain HTTP)
            else if (fieldValue.startsWith('https://')) {
                if (fieldValue.contains('.salesforce.com') || fieldValue.contains('.force.com') || fieldValue.contains('.documentforce.com')) {
                    imageBlob = fetchViaNamedCredential(fieldValue.substringAfter('.com'));
                } else {
                    imageBlob = fetchDirectUrl(fieldValue);
                }
                if (fieldValue.containsIgnoreCase('.jpg') || fieldValue.containsIgnoreCase('.jpeg')) ext = 'jpeg';
            }

            if (imageBlob == null) {
                System.debug(LoggingLevel.WARN, 'DocGen: Could not resolve image from: ' + fieldValue.left(200));
                return null;
            }

            imageCounter++;
            String relId = 'rIdImg' + imageCounter;
            String fileName = 'docgen_image_' + imageCounter + '.' + ext;

            // Register image for ZIP injection
            pendingImages.add(new Map<String, Object>{
                'relId' => relId,
                'fileName' => fileName,
                'blob' => imageBlob
            });

            // Use DrawingML format (<w:drawing>) for broad compatibility.
            // VML (<w:pict>) works in Word but docx-preview (used for client-side PDF) cannot render it.
            // DrawingML is the modern OOXML standard supported by Word, docx-preview, and Salesforce rendition API.
            // EMU conversion: 1px at 96dpi = 9525 EMU, 1pt = 12700 EMU. Default: 4in x 3in
            Integer widthEmu = (widthPx != null) ? (widthPx * 9525) : (288 * 12700);
            Integer heightEmu = (heightPx != null) ? (heightPx * 9525) : (216 * 12700);

            return '</w:t></w:r>' +
                '<w:r><w:drawing>' +
                '<wp:inline distT="0" distB="0" distL="0" distR="0" ' +
                    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                  '<wp:extent cx="' + widthEmu + '" cy="' + heightEmu + '"/>' +
                  '<wp:docPr id="' + imageCounter + '" name="DocGenImage' + imageCounter + '"/>' +
                  '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                      '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                        '<pic:nvPicPr>' +
                          '<pic:cNvPr id="' + imageCounter + '" name="DocGenImage' + imageCounter + '"/>' +
                          '<pic:cNvPicPr/>' +
                        '</pic:nvPicPr>' +
                        '<pic:blipFill>' +
                          '<a:blip r:embed="' + relId + '" ' +
                            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>' +
                          '<a:stretch><a:fillRect/></a:stretch>' +
                        '</pic:blipFill>' +
                        '<pic:spPr>' +
                          '<a:xfrm>' +
                            '<a:off x="0" y="0"/>' +
                            '<a:ext cx="' + widthEmu + '" cy="' + heightEmu + '"/>' +
                          '</a:xfrm>' +
                          '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                        '</pic:spPr>' +
                      '</pic:pic>' +
                    '</a:graphicData>' +
                  '</a:graphic>' +
                '</wp:inline>' +
                '</w:drawing></w:r><w:r><w:t xml:space="preserve">';

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Image injection error: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Extracts the first image from rich text HTML.
     * Handles data URIs, Salesforce servlet URLs (via Named Credential callout), and refid references.
     */
    private static Blob extractImageFromHtml(String html) {
        // Use string parsing instead of regex to avoid "Regex too complicated" on large base64 data
        Integer imgIdx = html.indexOfIgnoreCase('<img');
        if (imgIdx == -1) return null;

        Integer srcIdx = html.indexOfIgnoreCase('src=', imgIdx);
        if (srcIdx == -1) return null;

        srcIdx += 4; // skip 'src='
        // Skip optional whitespace
        while (srcIdx < html.length() && html.substring(srcIdx, srcIdx + 1) == ' ') srcIdx++;

        // Determine quote character
        String quoteChar = html.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') return null;
        srcIdx++; // skip opening quote

        Integer srcEnd = html.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) return null;

        String src = html.substring(srcIdx, srcEnd).replace('&amp;', '&');

        // Data URI
        if (src.startsWith('data:image/')) {
            String base64Part = src.substringAfter(',');
            return EncodingUtil.base64Decode(base64Part);
        }

        // Salesforce rtaImage servlet URL — fetch via Named Credential
        if (src.containsIgnoreCase('servlet/rtaImage')) {
            return fetchViaNamedCredential('/servlet/' + src.substringAfter('/servlet/'));
        }

        // Other Salesforce servlet/sfc URL
        if (src.containsIgnoreCase('/servlet/') || src.containsIgnoreCase('/sfc/')) {
            return fetchViaNamedCredential(src.contains('://') ? src.substringAfter('.com') : src);
        }

        // Salesforce refid reference (fallback)
        if (src.containsIgnoreCase('refid=')) {
            String refId = src.substringAfterLast('refid=').substringBefore('&');
            if (String.isBlank(refId)) refId = src.substringAfterLast('refid=');
            return fetchSalesforceImage(refId);
        }

        // Generic HTTPS URL in <img> tag — fetch directly or via Named Credential (reject plain HTTP)
        if (src.startsWith('https://')) {
            if (src.contains('.salesforce.com') || src.contains('.force.com') || src.contains('.documentforce.com')) {
                return fetchViaNamedCredential(src.substringAfter('.com'));
            }
            return fetchDirectUrl(src);
        }

        return null;
    }

    /**
     * Fetches a resource from the same org via the DocGen_Loopback Named Credential.
     */
    private static Blob fetchViaNamedCredential(String path) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:DocGen_Loopback' + path);
            req.setMethod('GET');
            req.setTimeout(15000);
            Http h = new Http();
            HttpResponse res = h.send(req);
            if (res.getStatusCode() == 200) {
                return res.getBodyAsBlob();
            }
            System.debug(LoggingLevel.WARN, 'DocGen: Named Credential fetch returned ' + res.getStatusCode() + ' for: ' + path.left(200));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Named Credential fetch failed: ' + e.getMessage());
        }
        return null;
    }

    /**
     * Fetches image blob from a Salesforce file reference (ContentDocument ID or ContentVersion ID).
     */
    private static Blob fetchSalesforceImage(String fileRef) {
        if (String.isBlank(fileRef)) return null;
        try {
            // Try as ContentVersion ID first
            if (fileRef.startsWith('068')) {
                List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!cvs.isEmpty()) return cvs[0].VersionData;
            }
            // Try as ContentDocument ID
            if (fileRef.startsWith('069')) {
                List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!docs.isEmpty() && docs[0].LatestPublishedVersionId != null) {
                    Id latestCvId = docs[0].LatestPublishedVersionId;
                    List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :latestCvId WITH SYSTEM_MODE LIMIT 1];
                    if (!cvs.isEmpty()) return cvs[0].VersionData;
                }
            }
            // Try as a generic ID that could be linked
            if (fileRef.length() >= 15) {
                List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!cvs.isEmpty()) return cvs[0].VersionData;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Failed to fetch image for ref: ' + fileRef + ' - ' + e.getMessage());
        }
        return null;
    }

    /**
     * Fetches image data from a generic HTTP/HTTPS URL.
     * Requires a Remote Site Setting for the target domain.
     */
    private static Blob fetchDirectUrl(String url) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(url);
            req.setMethod('GET');
            req.setTimeout(15000);
            Http h = new Http();
            HttpResponse res = h.send(req);
            if (res.getStatusCode() == 200) {
                return res.getBodyAsBlob();
            }
            System.debug(LoggingLevel.WARN, 'DocGen: Direct URL fetch returned ' + res.getStatusCode() + ' for: ' + url.left(200));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Direct URL fetch failed: ' + e.getMessage());
        }
        return null;
    }

    private static Id saveFile(Blob fileBlob, String title, Id recordId, String format, String type) {
        ContentVersion cv = new ContentVersion();
        String baseName = (title != null ? title : 'Generated_Document');
        if (!baseName.startsWith('Generated_') && title == null) baseName = 'Generated_' + baseName; 
        // Logic: specific requirements? 
        // User wants "create a title". 
        // If title provided via format, use it exactly.
        // If not, revert to old behavior: 'Generated_' + recordName.
        
        // Revised Logic:
        if (title != null) baseName = title;
        else baseName = 'Generated_' + (recordId != null ? 'Document' : 'File'); // Fallback fallback
        
        String ext = (type == 'PowerPoint') ? '.pptx' : '.docx';
        cv.Title = baseName;
        cv.PathOnClient = baseName + ext;
        cv.VersionData = fileBlob;
        cv.FirstPublishLocationId = recordId;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        // Background PDF Rendition: if requested format is PDF, queue for delayed capture
        if (format == 'PDF') {
            DocGenRenditionService.addPendingRendition(savedCvId, recordId);
        }
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE].ContentDocumentId;
    }
    private static String generateDocTitle(String format, Map<String, Object> data) {
        if (String.isBlank(format)) return null;
        String result = format;
        Pattern p = Pattern.compile('\\{([^}]+)\\}');
        Matcher m = p.matcher(format);
        while(m.find()) {
            String key = m.group(1);
            Object val = resolveValue(data, key);
            if (val != null) {
                 result = result.replace('{' + key + '}', String.valueOf(val));
            } else {
                result = result.replace('{' + key + '}', '');
            }
        }
        return result;
    }
}