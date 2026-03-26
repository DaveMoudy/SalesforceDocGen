public with sharing class DocGenService {

    // Collector for images to inject after XML processing
    private static List<Map<String, Object>> pendingImages = new List<Map<String, Object>>();
    private static Integer imageCounter = 0;
    private static String currentTemplateType = 'Word'; // Set before processXml calls
    private static String currentOutputFormat = 'Native'; // Set before processXml — PDF skips blob loading for images

    /**
     * Public wrapper for processXml — used by e2e tests to validate tag processing.
     * @param xml The XML string containing merge tags
     * @param data The record data map to resolve tags against
     * @return The processed XML with tags replaced by data values
     */
    public static String processXmlForTest(String xml, Map<String, Object> data) {
        return processXml(xml, data);
    }

    /**
     * Intermediate merge result containing processed XML, images, and passthrough ZIP entries.
     */
    private class MergeResult {
        String documentXml;                                   // Processed word/document.xml
        Map<String, String> processedXmlEntries;              // All processed XML entries (name → xml)
        Map<String, Blob> passthroughEntries;                 // Non-XML ZIP entries passed through as-is
        String contentTypesXml;                               // [Content_Types].xml
        String relsXml;                                       // word/_rels/document.xml.rels
        String relsPath;                                      // Path to rels file
        String mediaPath;                                     // Path prefix for media files
        Map<String, String> imageBase64ByRelId;               // relId → base64 image data (for DOCX and fallback)
        Map<String, String> imageUrlByRelId;                  // relId → absolute URL (for PDF rendering via Blob.toPdf)
        String templateType;
        String outputFormat;
        String docTitle;

        MergeResult() {
            processedXmlEntries = new Map<String, String>();
            passthroughEntries = new Map<String, Blob>();
            imageBase64ByRelId = new Map<String, String>();
            imageUrlByRelId = new Map<String, String>();
        }
    }

    /**
     * Core merge logic: processes template tags in DOCX/PPTX XML and collects results.
     * Returns structured intermediate data without assembling into a final format.
     */
    private static MergeResult mergeTemplate(Id templateId, Id recordId) {
        return mergeTemplate(templateId, recordId, null, null);
    }

    private static MergeResult mergeTemplate(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        return mergeTemplate(templateId, recordId, resolvedImages, null);
    }

    /**
     * Thread-local storage for pre-loaded record data. When set, mergeTemplate
     * skips DocGenController.generateDocumentData() and uses this data instead.
     * Cleared after each use.
     */
    private static Map<String, Object> preloadedRecordDataOverride;

    private static MergeResult mergeTemplate(Id templateId, Id recordId, Map<String, String> resolvedImages, String outputFormatOverride) {
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            if (preloadedRecordDataOverride != null) {
                // Use pre-cached data from bulk batch — skips per-record SOQL
                dataMap = DocGenController.generateDocumentDataFromCache(templateId, preloadedRecordDataOverride);
                preloadedRecordDataOverride = null; // Clear after use
            } else {
                dataMap = DocGenController.generateDocumentData(templateId, recordId);
            }
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        // Apply LWC-resolved images: replace Salesforce URLs with data URIs in record data.
        // This enables DOCX image embedding without server-side HTTP callouts.
        if (resolvedImages != null && !resolvedImages.isEmpty()) {
            applyResolvedImages(dataMap.get('data'), resolvedImages);
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String outputFormat = (String) dataMap.get('outputFormat');
        String templateType = (String) dataMap.get('templateType');

        // Allow callers to force PDF output format
        if (outputFormatOverride != null) {
            outputFormat = outputFormatOverride;
        }

        if (base64File == null) {
            throw new DocGenException('Template file content is missing.');
        }

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject)dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        MergeResult mr = new MergeResult();
        mr.templateType = templateType;
        mr.outputFormat = outputFormat;

        // Determine rels path based on template type
        if (templateType == 'PowerPoint') {
            mr.relsPath = 'ppt/_rels/presentation.xml.rels';
            mr.mediaPath = 'ppt/media/';
        } else if (templateType == 'Excel') {
            mr.relsPath = 'xl/_rels/workbook.xml.rels';
            mr.mediaPath = 'xl/media/';
        } else {
            mr.relsPath = 'word/_rels/document.xml.rels';
            mr.mediaPath = 'word/media/';
        }

        // For PDF output, try the heap-efficient path: use pre-decomposed XML parts
        // saved as ContentVersions during template version save, skipping full ZIP decompression.
        // Saves ~1.5-2MB heap by avoiding base64 decode + ZIP reader + passthrough extraction.
        if (outputFormat == 'PDF' && templateType == 'Word') {
            currentOutputFormat = 'PDF';
            MergeResult pdfResult = tryMergeFromPreDecomposed(templateId, recordDataMap, mr);
            if (pdfResult != null) {
                mr = pdfResult;
                mr.docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
                if (mr.docTitle == null) {
                    mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
                }
                return mr;
            }
        }

        // Full ZIP decompression path — used for DOCX/PPTX/XLSX output or when pre-decomposed parts are unavailable
        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);

        // Excel two-pass: worksheets collected here, processed after shared strings are read
        Map<String, String> pendingExcelSheets = new Map<String, String>();
        String excelSharedStringsXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            Boolean isTargetXml = false;
            if (templateType == 'Word') {
                isTargetXml = name == 'word/document.xml' ||
                              (name.startsWith('word/header') && name.endsWith('.xml')) ||
                              (name.startsWith('word/footer') && name.endsWith('.xml'));
            } else if (templateType == 'PowerPoint') {
                isTargetXml = name.startsWith('ppt/slides/slide') && name.endsWith('.xml');
            } else if (templateType == 'Excel') {
                isTargetXml = (name.startsWith('xl/worksheets/sheet') && name.endsWith('.xml')) ||
                              name == 'xl/sharedStrings.xml';
            }

            // Excel: collect worksheets for second pass (shared strings must be read first)
            if (templateType == 'Excel' && isTargetXml && name != 'xl/sharedStrings.xml') {
                pendingExcelSheets.put(name, reader.extract(name).toString());
                continue;
            }

            if (isTargetXml) {
                Blob content = reader.extract(name);
                String xml = content.toString();
                currentTemplateType = templateType;

                // Excel: capture shared strings table (not merged, just stored)
                if (templateType == 'Excel' && name == 'xl/sharedStrings.xml') {
                    excelSharedStringsXml = xml;
                    mr.passthroughEntries.put(name, content); // keep original in ZIP
                    continue;
                }

                if (templateType == 'Word') {
                    xml = mergeRunsInTags(xml);
                }
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(name, xml);
                if (name == 'word/document.xml') {
                    mr.documentXml = xml;
                }
            } else if (name == '[Content_Types].xml') {
                mr.contentTypesXml = reader.extract(name).toString();
            } else if (name == mr.relsPath) {
                mr.relsXml = reader.extract(name).toString();
            } else {
                mr.passthroughEntries.put(name, reader.extract(name));
            }
        }

        // Excel second pass: inline shared strings into worksheets, then merge tags
        if (templateType == 'Excel' && !pendingExcelSheets.isEmpty()) {
            currentTemplateType = 'Excel';
            List<String> sharedStrings = parseSharedStrings(excelSharedStringsXml);
            for (String sheetName : pendingExcelSheets.keySet()) {
                String xml = pendingExcelSheets.get(sheetName);
                xml = inlineSharedStrings(xml, sharedStrings);
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(sheetName, xml);
            }
            // Remove sharedStrings.xml from passthrough — cells are now inline
            mr.passthroughEntries.remove('xl/sharedStrings.xml');
        }

        // Collect existing template images into imageBase64ByRelId for HTML rendering.
        // Parse rels XML to map relId → media filename, then look up in passthroughEntries.
        if (mr.relsXml != null) {
            Integer relCursor = 0;
            while (relCursor < mr.relsXml.length()) {
                Integer relStart = mr.relsXml.indexOf('<Relationship ', relCursor);
                if (relStart == -1) {
                    break;
                }
                Integer relSelfClose = mr.relsXml.indexOf('/>', relStart);
                Integer relClose = mr.relsXml.indexOf('>', relStart);
                if (relClose == -1) {
                    break;
                }
                Integer relEnd = (relSelfClose != -1 && relSelfClose < relClose) ? relSelfClose + 2 : relClose + 1;

                String relTag = mr.relsXml.substring(relStart, relEnd);
                String relType = extractXmlAttrValue(relTag, 'Type');
                if (relType != null && relType.contains('/image')) {
                    String relId = extractXmlAttrValue(relTag, 'Id');
                    String target = extractXmlAttrValue(relTag, 'Target');
                    if (relId != null && target != null && target.startsWith('media/')) {
                        String fullPath = mr.mediaPath + target.substringAfter('media/');
                        Blob imgBlob = mr.passthroughEntries.get(fullPath);
                        if (imgBlob != null && !mr.imageBase64ByRelId.containsKey(relId)) {
                            mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode(imgBlob));
                        }
                    }
                }
                relCursor = relEnd;
            }
        }

        // Process pending images: update content types, rels, and collect base64 for HTML
        if (!pendingImages.isEmpty()) {
            if (mr.contentTypesXml != null) {
                if (!mr.contentTypesXml.contains('Extension="png"')) {
                    mr.contentTypesXml = mr.contentTypesXml.replace('</Types>', '<Default Extension="png" ContentType="image/png"/></Types>');
                }
                if (!mr.contentTypesXml.contains('Extension="jpeg"') && !mr.contentTypesXml.contains('Extension="jpg"')) {
                    mr.contentTypesXml = mr.contentTypesXml.replace('</Types>', '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>');
                }
            }
            if (mr.relsXml != null) {
                for (Map<String, Object> img : pendingImages) {
                    // Add relationship for ALL images (blob or URL-only)
                    String relId = (String) img.get('relId');
                    String fName = (String) img.get('fileName');
                    String newRel = '<Relationship Id="' + relId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + fName + '"/>';
                    mr.relsXml = mr.relsXml.replace('</Relationships>', newRel + '</Relationships>');
                }
            }
            // Collect image data for rendering paths
            for (Map<String, Object> img : pendingImages) {
                String relId = (String) img.get('relId');
                if (img.containsKey('blob')) {
                    // Base64 for DOCX ZIP embedding and fallback
                    Blob imgBlob = (Blob) img.get('blob');
                    mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode(imgBlob));
                }
                if (img.containsKey('url')) {
                    // URL for PDF rendering via Blob.toPdf()
                    mr.imageUrlByRelId.put(relId, (String) img.get('url'));
                    // Also store in base64 map so PDF image map loop finds the relId
                    if (!img.containsKey('blob')) {
                        mr.imageBase64ByRelId.put(relId, (String) img.get('url'));
                    }
                }
            }
        }

        // Generate document title
        mr.docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
        if (mr.docTitle == null) {
            mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
        }

        return mr;
    }

    /**
     * Recursively walks record data and replaces Salesforce image URLs with
     * base64 data URIs from the LWC-resolved image map. This enables DOCX
     * image embedding without server-side callouts.
     */
    private static void applyResolvedImages(Object data, Map<String, String> resolvedImages) {
        if (data instanceof Map<String, Object>) {
            Map<String, Object> mapData = (Map<String, Object>) data;
            for (String key : new List<String>(mapData.keySet())) {
                Object val = mapData.get(key);
                if (val instanceof String) {
                    String strVal = (String) val;
                    if (strVal.containsIgnoreCase('<img')) {
                        for (String originalUrl : resolvedImages.keySet()) {
                            if (strVal.contains(originalUrl)) {
                                strVal = strVal.replace(originalUrl, resolvedImages.get(originalUrl));
                            }
                            // Also handle &amp; encoded version
                            String encodedUrl = originalUrl.replace('&', '&amp;');
                            if (strVal.contains(encodedUrl)) {
                                strVal = strVal.replace(encodedUrl, resolvedImages.get(originalUrl));
                            }
                        }
                        mapData.put(key, strVal);
                    }
                } else {
                    applyResolvedImages(val, resolvedImages);
                }
            }
        } else if (data instanceof List<Object>) {
            for (Object item : (List<Object>) data) {
                applyResolvedImages(item, resolvedImages);
            }
        }
    }

    /**
     * Attempts to build a MergeResult from pre-decomposed XML parts stored as ContentVersions.
     * Skips full ZIP decompression — saves ~1.5-2MB heap for PDF generation.
     * Returns null if pre-decomposed parts are not available (older templates).
     */
    // Static cache for pre-decomposed XML parts — same template, queried once, reused across batch
    private static Id cachedPreDecompTemplateId;
    private static Map<String, String> cachedXmlParts; // key (e.g. 'rels', 'word__document.xml') → raw XML
    private static Boolean cachedPreDecompAvailable;

    private static MergeResult tryMergeFromPreDecomposed(Id templateId, Map<String, Object> recordDataMap, MergeResult mr) {
        // Cache the template version + XML CV query — identical for every record
        if (cachedPreDecompTemplateId != templateId || cachedXmlParts == null) {
            cachedPreDecompTemplateId = templateId;
            cachedXmlParts = new Map<String, String>();
            cachedPreDecompAvailable = false;

            List<DocGen_Template_Version__c> activeVersions = [
                SELECT Id FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = true
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (activeVersions.isEmpty()) {
                return null;
            }

            String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
            List<ContentVersion> xmlCvs = [
                SELECT Id, Title, VersionData FROM ContentVersion
                WHERE Title LIKE :(xmlPrefix + '%')
                WITH SYSTEM_MODE
            ];

            if (xmlCvs.isEmpty()) {
                return null;
            }

            for (ContentVersion cv : xmlCvs) {
                String key = cv.Title.substring(xmlPrefix.length());
                cachedXmlParts.put(key, cv.VersionData.toString());
            }
            cachedPreDecompAvailable = true;
        }

        if (!cachedPreDecompAvailable || cachedXmlParts.isEmpty()) {
            return null;
        }

        // Process cached XML parts with this record's data
        for (String key : cachedXmlParts.keySet()) {
            String rawXml = cachedXmlParts.get(key);
            if (key == 'rels') {
                mr.relsXml = rawXml;
            } else {
                // Restore original path: word__document.xml → word/document.xml
                String originalPath = key.replace('__', '/');
                currentTemplateType = mr.templateType;
                String xml = mergeRunsInTags(rawXml);
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(originalPath, xml);
                if (originalPath == 'word/document.xml') {
                    mr.documentXml = xml;
                } else if (originalPath.startsWith('word/header') || originalPath.startsWith('word/footer')) {
                    // Headers and footers are already in processedXmlEntries via the put() above
                }
            }
        }

        if (mr.documentXml == null) {
            return null;
        }

        // Process pending images from merge field processing (RTF images, {%Field} images)
        if (!pendingImages.isEmpty()) {
            if (mr.relsXml != null) {
                for (Map<String, Object> img : pendingImages) {
                    // Add relationship for ALL images (blob or URL-only)
                    String relId = (String) img.get('relId');
                    String fName = (String) img.get('fileName');
                    String newRel = '<Relationship Id="' + relId + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' + fName + '"/>';
                    mr.relsXml = mr.relsXml.replace('</Relationships>', newRel + '</Relationships>');
                }
            }
            for (Map<String, Object> img : pendingImages) {
                String relId = (String) img.get('relId');
                if (img.containsKey('blob')) {
                    Blob imgBlob = (Blob) img.get('blob');
                    mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode(imgBlob));
                }
                if (img.containsKey('url')) {
                    mr.imageUrlByRelId.put(relId, (String) img.get('url'));
                    if (!img.containsKey('blob')) {
                        mr.imageBase64ByRelId.put(relId, (String) img.get('url'));
                    }
                }
            }
        }

        return mr;
    }

    /**
     * Assembles a MergeResult into a DOCX/PPTX ZIP Blob.
     */
    private static Blob assembleZip(MergeResult mr) {
        Compression.ZipWriter writer = new Compression.ZipWriter();

        // Add processed XML entries
        for (String name : mr.processedXmlEntries.keySet()) {
            writer.addEntry(name, Blob.valueOf(mr.processedXmlEntries.get(name)));
        }

        // Add passthrough entries
        for (String name : mr.passthroughEntries.keySet()) {
            writer.addEntry(name, mr.passthroughEntries.get(name));
        }

        // Add image blobs (skip URL-only images which are for PDF rendering only)
        for (Map<String, Object> img : pendingImages) {
            if (img.containsKey('blob')) {
                String fName = (String) img.get('fileName');
                Blob imageBlob = (Blob) img.get('blob');
                writer.addEntry(mr.mediaPath + fName, imageBlob);
            }
        }

        // Add content types and rels
        if (mr.contentTypesXml != null) {
            writer.addEntry('[Content_Types].xml', Blob.valueOf(mr.contentTypesXml));
        }
        if (mr.relsXml != null) {
            writer.addEntry(mr.relsPath, Blob.valueOf(mr.relsXml));
        }

        return writer.getArchive();
    }

    /**
     * Processes a template with record data and returns the result as a Map containing
     * the document Blob, title, output format, and template type. Does NOT save to record.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: blob, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId) {
        return processDocument(templateId, recordId, null);
    }

    /**
     * Processes a template with optional pre-resolved images from the LWC.
     * The resolvedImages map contains originalUrl → base64DataUri entries
     * fetched by the browser (which has session access to Salesforce URLs).
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param resolvedImages Map of originalUrl to base64DataUri for LWC-resolved images
     * @return Map with keys: blob, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        MergeResult mr = mergeTemplate(templateId, recordId, resolvedImages);
        Blob resultBlob = assembleZip(mr);

        return new Map<String, Object>{
            'blob' => resultBlob,
            'title' => mr.docTitle,
            'outputFormat' => mr.outputFormat,
            'templateType' => mr.templateType
        };
    }

    /**
     * Returns merged document parts for client-side DOCX assembly.
     * No ZIP assembly on server — just the merged XML, updated rels/content types,
     * shell CV ID, and pending image CV IDs. The browser fetches the shell ZIP and
     * images by URL, then assembles the final DOCX client-side (zero heap for ZIP).
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: allXmlParts, imageBase64Map, imageCvIdMap, title, templateType
     */
    public static Map<String, Object> generateDocumentParts(Id templateId, Id recordId) {
        // Use PDF output format to skip image blob loading during merge.
        // Images are collected as CV URLs only — we deduplicate and load once below.
        currentOutputFormat = 'PDF';
        MergeResult mr = mergeTemplate(templateId, recordId);
        currentOutputFormat = 'Native';

        // Collect ALL XML parts for the client to build the ZIP from scratch.
        // Merged entries (document.xml, headers, footers) come from processXml.
        // Passthrough entries (styles, numbering, theme, etc.) come from the template.
        // All are returned as path→string maps — the client assembles the ZIP.
        Map<String, String> allXmlParts = new Map<String, String>(mr.processedXmlEntries);
        if (mr.contentTypesXml != null) {
            allXmlParts.put('[Content_Types].xml', mr.contentTypesXml);
        }
        if (mr.relsXml != null) {
            allXmlParts.put(mr.relsPath, mr.relsXml);
        }
        // Add passthrough XML entries (styles.xml, numbering.xml, theme, etc.)
        for (String path : mr.passthroughEntries.keySet()) {
            Blob entryBlob = mr.passthroughEntries.get(path);
            if (!path.startsWith(mr.mediaPath)) {
                // Non-media passthrough = XML/text content
                allXmlParts.put(path, entryBlob.toString());
            }
        }

        // Build image map — return CV IDs for client to fetch one at a time.
        // Each client-side Apex call gets its own fresh heap, enabling unlimited images.
        // Template-embedded media from passthrough (small, already in heap)
        Map<String, String> imageBase64Map = new Map<String, String>();
        for (String path : mr.passthroughEntries.keySet()) {
            if (path.startsWith(mr.mediaPath)) {
                imageBase64Map.put(path, EncodingUtil.base64Encode(mr.passthroughEntries.get(path)));
            }
        }

        // Dynamic images: return mediaPath → CV ID mapping (not base64)
        // Client calls getContentVersionBase64() for each unique CV in separate transactions
        Map<String, String> imageCvIdMap = new Map<String, String>();
        Map<String, String> imageUrlMap = new Map<String, String>();
        for (Map<String, Object> img : pendingImages) {
            String fileName = (String) img.get('fileName');
            String mediaPath = 'word/media/' + fileName;
            if (img.containsKey('url')) {
                String url = (String) img.get('url');
                if (url.contains('/version/download/')) {
                    imageCvIdMap.put(mediaPath, url.substringAfterLast('/'));
                } else if (url.contains('/servlet/') || url.contains('/sfc/')) {
                    // Salesforce servlet URLs (rtaImage, etc.) — pass to client for fetching
                    imageUrlMap.put(mediaPath, url);
                }
            }
        }

        return new Map<String, Object>{
            'allXmlParts' => allXmlParts,
            'imageBase64Map' => imageBase64Map,
            'imageCvIdMap' => imageCvIdMap,
            'imageUrlMap' => imageUrlMap,
            'title' => mr.docTitle,
            'templateType' => mr.templateType
        };
    }

    /**
     * Extracts images from a template DOCX/PPTX file and saves them as ContentVersion
     * records linked to the template version. These committed CVs provide stable URLs
     * for Blob.toPdf() which cannot render data URI images (Flying Saucer limitation).
     * Each version gets its own set of images — no duplicates or confusion.
     * @param templateId The DocGen_Template__c record ID
     * @param versionId The DocGen_Template_Version__c record ID to link images to
     */
    public static void extractAndSaveTemplateImages(Id templateId, Id versionId) {
        String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);
        if (fileContent == null) {
            return;
        }

        List<DocGen_Template__c> templates = [
            SELECT Type__c FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1
        ];
        if (templates.isEmpty()) {
            return;
        }
        String templateType = templates[0].Type__c;

        Blob templateBlob = EncodingUtil.base64Decode(fileContent);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);

        // Determine paths based on template type
        String relsPath;
        String mediaPath;
        if (templateType == 'PowerPoint') {
            relsPath = 'ppt/_rels/presentation.xml.rels';
            mediaPath = 'ppt/media/';
        } else {
            relsPath = 'word/_rels/document.xml.rels';
            mediaPath = 'word/media/';
        }

        String relsXml = null;
        List<String> additionalRelsXmls = new List<String>(); // header/footer rels
        Map<String, Blob> mediaEntries = new Map<String, Blob>();
        Map<String, String> xmlEntries = new Map<String, String>();

        // Extract all entries in one pass — ZipReader may not support multiple extractions
        Map<String, Blob> allEntries = new Map<String, Blob>();
        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            allEntries.put(name, reader.extract(name));
        }

        // Classify entries and build shell ZIP
        Compression.ZipWriter shellWriter = new Compression.ZipWriter();
        Set<String> documentXmlPaths = new Set<String>();

        for (String name : allEntries.keySet()) {
            Blob entryBlob = allEntries.get(name);
            Boolean isDocumentXml = false;

            if (name == relsPath) {
                relsXml = entryBlob.toString();
            } else if (templateType == 'Word' && name.startsWith('word/_rels/') &&
                       (name.contains('header') || name.contains('footer')) && name.endsWith('.rels')) {
                // Header/footer relationship files contain image references
                additionalRelsXmls.add(entryBlob.toString());
            } else if (name.startsWith(mediaPath)) {
                mediaEntries.put(name, entryBlob);
            }

            // Identify XML parts that get merged/replaced at generation time
            if (templateType == 'Word') {
                if (name == 'word/document.xml' ||
                    (name.startsWith('word/header') && name.endsWith('.xml')) ||
                    (name.startsWith('word/footer') && name.endsWith('.xml'))) {
                    xmlEntries.put(name, entryBlob.toString());
                    isDocumentXml = true;
                    documentXmlPaths.add(name);
                }
            } else if (templateType == 'PowerPoint') {
                if (name.startsWith('ppt/slides/slide') && name.endsWith('.xml')) {
                    xmlEntries.put(name, entryBlob.toString());
                    isDocumentXml = true;
                    documentXmlPaths.add(name);
                }
            }

            // Shell gets everything EXCEPT document XML, rels, and [Content_Types].xml
            // (rels and content types may be modified during merge for new images)
            if (!isDocumentXml && name != relsPath && name != '[Content_Types].xml') {
                shellWriter.addEntry(name, entryBlob);
            }
        }

        List<ContentVersion> newCvs = new List<ContentVersion>();

        // Save pre-decomposed XML parts as ContentVersions for heap-efficient PDF generation.
        // At render time, these are queried directly instead of decompressing the full ZIP.
        String xmlPrefix = 'docgen_tmpl_xml_' + versionId + '_';
        for (String xmlName : xmlEntries.keySet()) {
            // Use a safe filename: word/document.xml → word__document.xml
            String safeKey = xmlName.replace('/', '__');
            ContentVersion xmlCv = new ContentVersion();
            xmlCv.Title = xmlPrefix + safeKey;
            xmlCv.PathOnClient = xmlPrefix + safeKey;
            xmlCv.VersionData = Blob.valueOf(xmlEntries.get(xmlName));
            xmlCv.FirstPublishLocationId = versionId;
            newCvs.add(xmlCv);
        }

        // Save rels XML for image relId mapping during PDF generation
        // Combine document rels with header/footer rels so all image relIds are resolvable
        String combinedRels = relsXml != null ? relsXml : '';
        for (String hfRels : additionalRelsXmls) {
            combinedRels += hfRels;
        }
        if (String.isNotBlank(combinedRels)) {
            ContentVersion relsCv = new ContentVersion();
            relsCv.Title = xmlPrefix + 'rels';
            relsCv.PathOnClient = xmlPrefix + 'rels.xml';
            relsCv.VersionData = Blob.valueOf(combinedRels);
            relsCv.FirstPublishLocationId = versionId;
            newCvs.add(relsCv);
        }

        // Parse rels (document + header/footer) and save each image as a ContentVersion
        if (!mediaEntries.isEmpty()) {
            String imgPrefix = 'docgen_tmpl_img_' + versionId + '_';
            Set<String> savedRelIds = new Set<String>();

            // Collect all rels XML to parse: main document rels + header/footer rels
            List<String> allRelsXmls = new List<String>();
            if (relsXml != null) { allRelsXmls.add(relsXml); }
            allRelsXmls.addAll(additionalRelsXmls);

            for (String currentRels : allRelsXmls) {
                Integer relCursor = 0;
                while (relCursor < currentRels.length()) {
                    Integer relStart = currentRels.indexOf('<Relationship ', relCursor);
                    if (relStart == -1) {
                        break;
                    }
                    Integer relSelfClose = currentRels.indexOf('/>', relStart);
                    Integer relClose = currentRels.indexOf('>', relStart);
                    if (relClose == -1) {
                        break;
                    }
                    Integer relEnd = (relSelfClose != -1 && relSelfClose < relClose) ? relSelfClose + 2 : relClose + 1;

                    String relTag = currentRels.substring(relStart, relEnd);
                    String relType = extractXmlAttrValue(relTag, 'Type');
                    if (relType != null && relType.contains('/image')) {
                        String relId = extractXmlAttrValue(relTag, 'Id');
                        String target = extractXmlAttrValue(relTag, 'Target');
                        if (relId != null && target != null && target.startsWith('media/') && !savedRelIds.contains(relId)) {
                            String fullPath = mediaPath + target.substringAfter('media/');
                            Blob imgBlob = mediaEntries.get(fullPath);
                            if (imgBlob != null) {
                                String ext = target.substringAfterLast('.');
                                ContentVersion cv = new ContentVersion();
                                cv.Title = imgPrefix + relId;
                                cv.PathOnClient = imgPrefix + relId + '.' + ext;
                                cv.VersionData = imgBlob;
                                cv.FirstPublishLocationId = versionId;
                                newCvs.add(cv);
                                savedRelIds.add(relId);
                            }
                        }
                    }
                    relCursor = relEnd;
                }
            }
        }

        // Save shell ZIP — the template without document XML entries, rels, or content types.
        // Client-side DOCX assembly fetches this shell, adds the server-merged XML, and produces the final DOCX.
        Blob shellBlob = shellWriter.getArchive();
        ContentVersion shellCv = new ContentVersion();
        shellCv.Title = 'docgen_tmpl_shell_' + versionId;
        shellCv.PathOnClient = 'docgen_tmpl_shell_' + versionId + '.docx';
        shellCv.VersionData = shellBlob;
        shellCv.FirstPublishLocationId = versionId;
        newCvs.add(shellCv);

        if (!newCvs.isEmpty()) {
            SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, newCvs);
            insert cvDecision.getRecords();
        }

    }

    /**
     * Builds a URL-based image map for PDF rendering via Blob.toPdf().
     * Looks up pre-committed template image ContentVersions (saved at version publish time)
     * and adds RTF/dynamic image URLs. Returns relId → absolute URL map.
     */
    private static Map<String, String> buildPdfImageMap(MergeResult mr, Id templateId) {
        Map<String, String> pdfImages = new Map<String, String>();
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();

        // 1. Template-embedded images: committed CVs linked to active version
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (!activeVersions.isEmpty()) {
            String prefix = 'docgen_tmpl_img_' + activeVersions[0].Id + '_';
            List<ContentVersion> tmplCvs = [
                SELECT Id, Title FROM ContentVersion
                WHERE Title LIKE :(prefix + '%')
                WITH SYSTEM_MODE
            ];
            for (ContentVersion cv : tmplCvs) {
                String relId = cv.Title.substring(prefix.length());
                pdfImages.put(relId, '/sfc/servlet.shepherd/version/download/' + cv.Id);
            }
        }

        // 2. RTF/dynamic images: use relative Salesforce URLs for Blob.toPdf()
        for (String relId : mr.imageUrlByRelId.keySet()) {
            String url = mr.imageUrlByRelId.get(relId);
            // Strip domain if absolute — Blob.toPdf() only resolves relative paths
            if (url.startsWithIgnoreCase('http')) {
                Integer pathStart = url.indexOf('/sfc/');
                if (pathStart == -1) { pathStart = url.indexOf('/servlet/'); }
                if (pathStart != -1) {
                    url = url.substring(pathStart);
                }
            }
            pdfImages.put(relId, url);
        }

        return pdfImages;
    }

    /**
     * Generates a PDF Blob from a MergeResult using the unified image map.
     * Single entry point for all PDF rendering — used by generateDocument()
     * and generatePdfBlob().
     */
    // Captured HTML from the last renderPdf() call. Used by bulk batch merge mode
    // to accumulate HTML without re-merging the template. Cleared after reading.
    public static String lastRenderedHtml;

    private static Blob renderPdf(MergeResult mr, Id templateId, Id recordId) {
        if (Test.isRunningTest()) {
            lastRenderedHtml = '<html><body><p>Test PDF</p></body></html>';
            return Blob.toPdf(lastRenderedHtml);
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);

        // Render header/footer XML separately for CSS @page positioning
        String headerHtml = '';
        String footerHtml = '';
        if (mr.processedXmlEntries != null) {
            for (String path : mr.processedXmlEntries.keySet()) {
                if (path.startsWith('word/header')) {
                    headerHtml = DocGenHtmlRenderer.convertToHtmlFragment(mr.processedXmlEntries.get(path), pdfImages);
                } else if (path.startsWith('word/footer')) {
                    footerHtml = DocGenHtmlRenderer.convertToHtmlFragment(mr.processedXmlEntries.get(path), pdfImages);
                }
            }
        }

        String html = DocGenHtmlRenderer.convertToHtmlWithHeaderFooter(mr.documentXml, pdfImages, headerHtml, footerHtml);
        lastRenderedHtml = html;

        // Blob.toPdf() with the Spring '26 Release Update resolves relative Salesforce
        // ContentVersion URLs (/sfc/servlet.shepherd/...) natively via the VF rendering engine.
        // Requires: Spring '26 Release Update "Use the Visualforce PDF Rendering Service for Blob.toPdf() Invocations"
        return Blob.toPdf(html);
    }

    /**
     * Generates HTML for browser preview with data URI images.
     * Uses the same merge + image pipeline as the PDF generator (forced PDF mode,
     * pre-decomposed XML, buildPdfImageMap), then converts relative CV URLs
     * to base64 data URIs so guest users can view them without a Salesforce session.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Complete HTML string with embedded base64 data URI images
     */
    public static String renderPreviewHtml(Id templateId, Id recordId) {
        // Same merge path as PDF generation — forced PDF mode
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Preview is only supported for Word templates.');
        }

        // Build the same image map the PDF generator uses
        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);

        // Convert relative CV URLs to data URIs for browser rendering
        Map<String, String> previewImages = new Map<String, String>();
        for (String relId : pdfImages.keySet()) {
            String url = pdfImages.get(relId);
            // Extract CV Id from /sfc/servlet.shepherd/version/download/{cvId}
            if (url != null && url.contains('/version/download/')) {
                String cvId = url.substringAfterLast('/');
                try {
                    ContentVersion cv = [SELECT VersionData, FileExtension FROM ContentVersion WHERE Id = :cvId LIMIT 1]; // NOPMD ApexCRUDViolation - ContentVersion read access required for PDF image preview; gated by template ownership
                    String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : 'png';
                    String mime = (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
                    previewImages.put(relId, 'data:' + mime + ';base64,' + EncodingUtil.base64Encode(cv.VersionData));
                } catch (Exception e) {
                    // Skip unresolvable images
                    System.debug(LoggingLevel.ERROR, 'DocGenService: Unresolvable image skipped: ' + e.getMessage());
                }
            } else if (url != null) {
                previewImages.put(relId, url);
            }
        }

        return DocGenHtmlRenderer.convertToHtml(mr.documentXml, previewImages);
    }

    /**
     * Generates a PDF Blob and title without saving to record.
     * Used by DocGenController for download mode.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: blob (PDF Blob), title (String)
     */
    public static Map<String, Object> generatePdfBlob(Id templateId, Id recordId) {
        // Force PDF output format so we get the heap-efficient path
        // (pre-decomposed XML, relative image URLs, no blob loading)
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Server-side PDF generation is only supported for Word templates.');
        }

        Blob pdfBlob = renderPdf(mr, templateId, recordId);

        return new Map<String, Object>{
            'blob' => pdfBlob,
            'title' => mr.docTitle
        };
    }

    /**
     * Merges a template with record data and returns HTML using a custom image map.
     * Used by the batch PDF renderer to generate HTML with ContentVersion URLs
     * instead of data URIs, allowing Flying Saucer to render images in PDFs.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param imageMap Map of relId to image URL for PDF rendering
     * @return Map with keys: html, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocumentAsHtmlWithImageMap(Id templateId, Id recordId, Map<String, String> imageMap) {
        MergeResult mr = mergeTemplate(templateId, recordId);

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Server-side PDF generation is only supported for Word templates.');
        }

        // Merge the provided URL map with any URL-only entries from the merge result
        // (e.g., Rich Text field images that are accessed by URL, not base64)
        Map<String, String> mergedMap = new Map<String, String>(imageMap);
        for (String relId : mr.imageBase64ByRelId.keySet()) {
            if (!mergedMap.containsKey(relId)) {
                mergedMap.put(relId, mr.imageBase64ByRelId.get(relId));
            }
        }

        String html = DocGenHtmlRenderer.convertToHtml(mr.documentXml, mergedMap);

        return new Map<String, Object>{
            'html' => html,
            'title' => mr.docTitle,
            'outputFormat' => 'PDF',
            'templateType' => mr.templateType
        };
    }

    /**
     * Processes a template and saves the result as a ContentVersion attached to the record.
     * For PDF output, uses the unified renderPdf() path with pre-committed image URLs.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return ContentDocumentId of the saved file
     */
    public static Id generateDocument(Id templateId, Id recordId) {
        MergeResult mr = mergeTemplate(templateId, recordId);

        if (mr.outputFormat == 'PDF' && mr.templateType == 'Word') {
            Blob pdfBlob = renderPdf(mr, templateId, recordId);
            return savePdfFile(pdfBlob, mr.docTitle, recordId);
        }

        // Native DOCX/PPTX path
        Blob resultBlob = assembleZip(mr);
        return saveFile(resultBlob, mr.docTitle, recordId, mr.outputFormat, mr.templateType);
    }

    /**
     * Generates a document using pre-cached record data, bypassing data retrieval SOQL.
     * Sets the static override so mergeTemplate() uses cached data instead of querying.
     * Used by DocGenBatch when bulk data cache is available.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID (used for file attachment)
     * @param preloadedRecordData Pre-fetched record data map to use instead of querying
     * @return ContentDocumentId of the saved file
     */
    public static Id generateDocumentFromData(Id templateId, Id recordId, Map<String, Object> preloadedRecordData) {
        preloadedRecordDataOverride = preloadedRecordData;
        return generateDocument(templateId, recordId);
    }

    /**
     * Generates the HTML for a single record without calling Blob.toPdf() or saving a file.
     * Used by bulk batch to accumulate HTML for all records, then render one merged PDF at the end.
     * Accepts optional pre-loaded record data to skip per-record SOQL.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param preloadedRecordData Optional pre-fetched record data map (null to query fresh)
     * @return HTML string ready for Blob.toPdf() rendering
     */
    public static String generateHtmlForRecord(Id templateId, Id recordId, Map<String, Object> preloadedRecordData) {
        if (preloadedRecordData != null) {
            preloadedRecordDataOverride = preloadedRecordData;
        }
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        // Combine document XML with headers and footers for HTML conversion
        String combinedXml = mr.documentXml;
        if (mr.processedXmlEntries != null) {
            // Prepend headers, append footers
            String headers = '';
            String footers = '';
            List<String> keys = new List<String>(mr.processedXmlEntries.keySet());
            keys.sort();
            for (String key : keys) {
                if (key.startsWith('word/header')) {
                    headers += mr.processedXmlEntries.get(key);
                } else if (key.startsWith('word/footer')) {
                    footers += mr.processedXmlEntries.get(key);
                }
            }
            combinedXml = headers + combinedXml + footers;
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
        return DocGenHtmlRenderer.convertToHtml(combinedXml, pdfImages);
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

        if (contents.isEmpty()) {
            return xml;
        }

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
            if (openBrace == -1) {
                break;
            }
            Integer closeBrace = flatText.indexOf('}', openBrace);
            if (closeBrace == -1) {
                break;
            }

            // Determine which segments contain the { and }
            Integer openSeg = -1;
            Integer closeSeg = -1;
            for (Integer i = 0; i < contents.size(); i++) {
                Integer segStart = flatOffsets.get(i);
                Integer segEnd = segStart + contents.get(i).length();
                if (openBrace >= segStart && openBrace < segEnd) { openSeg = i; }
                if (closeBrace >= segStart && closeBrace < segEnd) { closeSeg = i; }
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

        if (!modified) {
            return xml;
        }

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

            // Strip Salesforce-style {!Field} prefix — treat {!X} the same as {X}
            if (tagContent.startsWith('!')) {
                tagContent = tagContent.substring(1).trim();
            }
            
            if (tagContent.startsWith('#')) {
                String key = tagContent.substring(1).trim();
                Integer sectionEnd = findBalancedEnd(xml, tagClose + 1, key);
                if (sectionEnd == -1) {
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
                    if (trStart == -1) {
                        trStart = xml.lastIndexOf('<w:tr>', cursor);
                    }

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
                    if (val instanceof Boolean && (Boolean)val) {
                         sectionResult = processXml(innerXml, data);
                    } else if (val instanceof Map<String, Object>) {
                        Map<String, Object> mapVal = (Map<String, Object>) val;
                        if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                            List<Object> records = (List<Object>) mapVal.get('records');
                            for (Object item : records) {
                                if (item instanceof Map<String, Object>) {
                                    sectionResult += processXml(innerXml, (Map<String, Object>) item);
                                }
                            }
                        } else {
                             sectionResult = processXml(innerXml, mapVal);
                        }
                    } else if (val instanceof List<Object>) {
                         List<Object> listVal = (List<Object>) val;
                         for (Object item : listVal) {
                              if (item instanceof Map<String, Object>) { sectionResult += processXml(innerXml, (Map<String, Object>) item); }
                         }
                    } else if (val != null) {
                         sectionResult = processXml(innerXml, data);
                    }
                    output += sectionResult;
                }
                
            } else if (tagContent.startsWith('/')) {
                output += '{' + rawTag + '}';
                cursor = tagClose + 1;
            } else if (tagContent.startsWith('%')) {
                // Image tag: {%FieldName} or {%FieldName:WxH}
                // PowerPoint: skip image injection (Word-specific DrawingML corrupts PPTX)
                if (currentTemplateType == 'PowerPoint') {
                    cursor = tagClose + 1;
                    continue;
                }
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
                if (val != null) {
                    String imageXml = buildImageXml(String.valueOf(val), imgWidthPx, imgHeightPx);
                    if (imageXml != null) {
                        output += imageXml;
                    }
                }
                cursor = tagClose + 1;
            } else if (tagContent.startsWith('*')) {
                // Barcode/QR tag: {*Field}, {*Field:qr}, {*Field:qr:200}, {*Field:code128:300x80}
                // Outputs a marker that DocGenHtmlRenderer renders as CSS for PDF
                String barcodeSpec = tagContent.substring(1).trim();
                List<String> bParts = barcodeSpec.split(':');
                String barcodeField = bParts[0].trim();
                String barcodeType = bParts.size() > 1 ? bParts[1].trim().toLowerCase() : 'code128';
                String barcodeSize = bParts.size() > 2 ? bParts[2].trim() : '';
                Object val = resolveValue(data, barcodeField);
                if (val != null) {
                    String barcodeValue = String.valueOf(val).escapeXml();
                    // Marker format: ##BARCODE:type:size:VALUE##
                    output += '##BARCODE:' + barcodeType + ':' + barcodeSize + ':' + barcodeValue + '##';
                }
                cursor = tagClose + 1;
            } else if (tagContent.contains(':') && isAggregateTag(tagContent)) {
                // Aggregate tag: {SUM:ChildList.Field}, {COUNT:ChildList}, {AVG:...}, {MIN:...}, {MAX:...}
                String aggResult = resolveAggregate(tagContent, data);
                if (aggResult != null) {
                    output += aggResult.escapeXml();
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
                    // Apply formatting if a format specifier was provided
                    if (dateFormat != null && val instanceof DateTime) {
                        strVal = ((DateTime) val).format(dateFormat);
                    } else if (dateFormat != null && val instanceof Date) {
                        DateTime dt = DateTime.newInstance((Date) val, Time.newInstance(0, 0, 0, 0));
                        strVal = dt.format(dateFormat);
                    } else if (dateFormat != null && isNumericFormat(dateFormat)) {
                        strVal = formatNumber(val, dateFormat);
                    } else {
                        strVal = String.valueOf(val);
                    }
                    // Rich text HTML — convert to DOCX XML preserving formatting, images, and paragraphs
                    // PowerPoint: strip HTML tags and output plain text (Word XML corrupts PPTX)
                    if (strVal.contains('<') && strVal.contains('>') &&
                        (strVal.containsIgnoreCase('<p') || strVal.containsIgnoreCase('<div') ||
                         strVal.containsIgnoreCase('<span') || strVal.containsIgnoreCase('<br') ||
                         strVal.containsIgnoreCase('<img') || strVal.containsIgnoreCase('<b>') ||
                         strVal.containsIgnoreCase('<i>') || strVal.containsIgnoreCase('<u>') ||
                         strVal.containsIgnoreCase('<strong') || strVal.containsIgnoreCase('<em'))) {
                        if (currentTemplateType == 'PowerPoint') {
                            // Strip HTML tags for plain text in PPTX
                            output += strVal.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim().escapeXml();
                        } else {
                            output += convertRichTextToDocxXml(strVal);
                        }
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
            if (nextStart == -1) {
                return -1;
            }
            Integer nextClose = xml.indexOf('}', nextStart);
            if (nextClose == -1) {
                return -1;
            }
            String content = xml.substring(nextStart + 1, nextClose).trim();
            if (content.equals('#' + key)) {
                depth++;
            }
            else if (content.equals('/' + key)) {
                depth--;
                if (depth == 0) {
                    return nextStart;
                }
            }
            cursor = nextClose + 1;
        }
        return -1;
    }
    
    private static Object resolveValue(Map<String, Object> data, String path) {
        if (data == null) {
            return null;
        }
        List<String> parts = path.split('\\.');
        Object current = data;

        for (Integer i = 0; i < parts.size(); i++) {
            String part = parts[i];
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
                        // If first segment doesn't match, it may be the base object name
                        // (e.g., "Contact" in {!Contact.FirstName}). Skip it and continue.
                        if (i == 0 && parts.size() > 1) {
                            continue;
                        }
                        return null;
                    }
                }
            } else if (current instanceof SObject) {
                 SObject sobj = (SObject) current;
                 try {
                     current = sobj.get(part);
                 } catch(Exception e) {
                     return null;
                 }
            } else {
                return null;
            }
            if (current == null) {
                return null;
            }
        }
        return current;
    }
    
    // ---------------------------------------------------------------------------
    // Aggregate Tags: {SUM:List.Field}, {COUNT:List}, {AVG:...}, {MIN:...}, {MAX:...}
    // ---------------------------------------------------------------------------

    private static final Set<String> AGGREGATE_FUNCTIONS = new Set<String>{
        'SUM', 'COUNT', 'AVG', 'MIN', 'MAX'
    };

    // ---------------------------------------------------------------------------
    // Excel Shared String Inlining
    // ---------------------------------------------------------------------------

    /**
     * Parses xl/sharedStrings.xml and returns an ordered list of string values.
     * Each <si> element at index N is the string referenced by <v>N</v> in cells.
     */
    private static List<String> parseSharedStrings(String xml) {
        List<String> strings = new List<String>();
        if (String.isBlank(xml)) {
            return strings;
        }

        Integer cursor = 0;
        while (cursor < xml.length()) {
            Integer siStart = xml.indexOf('<si>', cursor);
            if (siStart == -1) {
                siStart = xml.indexOf('<si ', cursor);
            }
            if (siStart == -1) {
                break;
            }

            Integer siEnd = xml.indexOf('</si>', siStart);
            if (siEnd == -1) {
                break;
            }

            // Extract all <t> content within this <si>
            String siContent = xml.substring(siStart, siEnd);
            String value = '';
            Integer tCursor = 0;
            while (tCursor < siContent.length()) {
                Integer tStart = siContent.indexOf('<t', tCursor);
                if (tStart == -1) {
                    break;
                }
                Integer tTagEnd = siContent.indexOf('>', tStart);
                if (tTagEnd == -1) {
                    break;
                }
                // Skip self-closing
                if (siContent.substring(tTagEnd - 1, tTagEnd) == '/') {
                    tCursor = tTagEnd + 1;
                    continue;
                }
                Integer tEnd = siContent.indexOf('</t>', tTagEnd);
                if (tEnd == -1) {
                    break;
                }
                value += siContent.substring(tTagEnd + 1, tEnd);
                tCursor = tEnd + 4;
            }
            strings.add(value);
            cursor = siEnd + 5;
        }
        return strings;
    }

    /**
     * Converts cells that reference shared strings (t="s") to inline strings (t="inlineStr").
     * This allows processXml() to find and resolve merge tags inside cell values.
     *
     * Before: <c r="A1" t="s"><v>3</v></c>  (index 3 in shared strings = "{Name}")
     * After:  <c r="A1" t="inlineStr"><is><t>{Name}</t></is></c>
     */
    private static String inlineSharedStrings(String xml, List<String> sharedStrings) {
        if (sharedStrings.isEmpty()) {
            return xml;
        }

        String result = '';
        Integer cursor = 0;

        while (cursor < xml.length()) {
            // Find next cell element
            Integer cStart = xml.indexOf('<c ', cursor);
            if (cStart == -1) {
                result += xml.substring(cursor);
                break;
            }

            // Output everything before this cell
            result += xml.substring(cursor, cStart);

            // Find cell end
            Integer cEnd = xml.indexOf('</c>', cStart);
            if (cEnd == -1) {
                // Self-closing cell
                Integer selfClose = xml.indexOf('/>', cStart);
                if (selfClose == -1) {
                    result += xml.substring(cStart);
                    break;
                }
                result += xml.substring(cStart, selfClose + 2);
                cursor = selfClose + 2;
                continue;
            }

            String cellXml = xml.substring(cStart, cEnd + 4);

            // Check if this is a shared string cell: t="s"
            if (cellXml.contains('t="s"')) {
                // Extract the <v> index
                Integer vStart = cellXml.indexOf('<v>');
                Integer vEnd = cellXml.indexOf('</v>');
                if (vStart != -1 && vEnd != -1) {
                    String indexStr = cellXml.substring(vStart + 3, vEnd).trim();
                    if (indexStr.isNumeric()) {
                        Integer idx = Integer.valueOf(indexStr);
                        if (idx >= 0 && idx < sharedStrings.size()) {
                            String value = sharedStrings[idx];
                            // Rebuild cell as inline string
                            String cellTag = cellXml.substring(0, cellXml.indexOf('>'));
                            cellTag = cellTag.replace('t="s"', 't="inlineStr"');
                            result += cellTag + '><is><t>' + value + '</t></is></c>';
                            cursor = cEnd + 4;
                            continue;
                        }
                    }
                }
            }

            // Not a shared string cell — pass through
            result += cellXml;
            cursor = cEnd + 4;
        }

        return result;
    }

    // ---------------------------------------------------------------------------
    // Number/Currency Formatting
    // {Amount:currency} → $500,000.00
    // {Quantity:#,##0} → 1,234
    // {Price:#,##0.00} → 1,234.56
    // {Rate:percent} → 15.5%
    // ---------------------------------------------------------------------------

    private static final Set<String> NUMERIC_FORMATS = new Set<String>{
        'currency', 'percent', 'number'
    };

    private static Boolean isNumericFormat(String fmt) {
        if (fmt == null) {
            return false;
        }
        String lower = fmt.toLowerCase().trim();
        return NUMERIC_FORMATS.contains(lower) || lower.startsWith('#') || lower.startsWith('0');
    }

    private static String formatNumber(Object val, String fmt) {
        Decimal num;
        try {
            num = Decimal.valueOf(String.valueOf(val));
        } catch (Exception e) {
            return String.valueOf(val); // Not a number — return as-is
        }

        String lower = fmt.toLowerCase().trim();

        if (lower == 'currency') {
            // $1,234.56
            return '$' + formatWithCommas(num.setScale(2, RoundingMode.HALF_UP));
        } else if (lower == 'percent') {
            // 15.5%
            return num.stripTrailingZeros().toPlainString() + '%';
        } else if (lower == 'number') {
            // 1,234 (no decimals)
            return formatWithCommas(num.setScale(0, RoundingMode.HALF_UP));
        } else {
            // Custom pattern: #,##0 or #,##0.00
            Integer decimals = 0;
            if (lower.contains('.')) {
                String afterDot = lower.substringAfter('.');
                decimals = afterDot.length();
            }
            return formatWithCommas(num.setScale(decimals, RoundingMode.HALF_UP));
        }
    }

    private static String formatWithCommas(Decimal num) {
        Boolean negative = num < 0;
        String raw = (negative ? num.abs() : num).toPlainString();

        // Split on decimal point
        String intPart = raw;
        String decPart = '';
        if (raw.contains('.')) {
            intPart = raw.substringBefore('.');
            decPart = '.' + raw.substringAfter('.');
        }

        // Insert commas every 3 digits from the right
        String result = '';
        Integer count = 0;
        for (Integer i = intPart.length() - 1; i >= 0; i--) {
            if (count > 0 && Math.mod(count, 3) == 0) {
                result = ',' + result;
            }
            result = intPart.substring(i, i + 1) + result;
            count++;
        }

        return (negative ? '-' : '') + result + decPart;
    }

    private static Boolean isAggregateTag(String tagContent) {
        Integer colonIdx = tagContent.indexOf(':');
        if (colonIdx <= 0) {
            return false;
        }
        String fn = tagContent.substring(0, colonIdx).trim().toUpperCase();
        return AGGREGATE_FUNCTIONS.contains(fn);
    }

    /**
     * Resolves an aggregate tag like {SUM:QuoteLineItems.TotalPrice}.
     * Walks the data map to find the child list, extracts field values, computes.
     */
    private static String resolveAggregate(String tagContent, Map<String, Object> data) {
        Integer colonIdx = tagContent.indexOf(':');
        String fn = tagContent.substring(0, colonIdx).trim().toUpperCase();
        String path = tagContent.substring(colonIdx + 1).trim();

        // Strip optional format specifier: "List.Field:currency" → path="List.Field", fmt="currency"
        String numberFormat = null;
        Integer dotIdx = path.indexOf('.');
        if (dotIdx > 0) {
            // Check for format specifier after the field name: "List.Field:format"
            String afterDot = path.substring(dotIdx + 1);
            Integer fmtColon = afterDot.indexOf(':');
            if (fmtColon > 0) {
                numberFormat = afterDot.substring(fmtColon + 1).trim();
                path = path.substring(0, dotIdx + 1 + fmtColon);
            }
        } else {
            // COUNT:List:format — format on a no-field aggregate
            Integer fmtColon = path.indexOf(':');
            if (fmtColon > 0) {
                numberFormat = path.substring(fmtColon + 1).trim();
                path = path.substring(0, fmtColon);
            }
        }

        // Split path into list name and optional field: "QuoteLineItems.TotalPrice" → ["QuoteLineItems", "TotalPrice"]
        String listName;
        String fieldName = null;
        dotIdx = path.indexOf('.');
        if (dotIdx > 0) {
            listName = path.substring(0, dotIdx);
            fieldName = path.substring(dotIdx + 1);
        } else {
            listName = path;
        }

        // COUNT doesn't require a field
        if (fn == 'COUNT' && fieldName == null) {
            List<Object> records = getChildRecords(data, listName);
            String countResult = records != null ? String.valueOf(records.size()) : '0';
            if (numberFormat != null && isNumericFormat(numberFormat)) {
                return formatNumber(Decimal.valueOf(countResult), numberFormat);
            }
            return countResult;
        }

        if (fieldName == null) {
            return null;
        }

        // Get child records and extract numeric values
        List<Object> records = getChildRecords(data, listName);
        if (records == null || records.isEmpty()) {
            return '0';
        }

        List<Decimal> values = new List<Decimal>();
        for (Object item : records) {
            if (item instanceof Map<String, Object>) {
                Object fieldVal = resolveValue((Map<String, Object>) item, fieldName);
                if (fieldVal != null) {
                    try {
                        values.add(Decimal.valueOf(String.valueOf(fieldVal)));
                    } catch (Exception e) {
                        // Skip non-numeric values
                        System.debug(LoggingLevel.ERROR, 'DocGenService: Non-numeric value in merge: ' + e.getMessage());
                    }
                }
            }
        }

        if (values.isEmpty()) {
            return '0';
        }

        Decimal result;
        if (fn == 'SUM') {
            result = 0;
            for (Decimal v : values) {
                result += v;
            }
        } else if (fn == 'AVG') {
            result = 0;
            for (Decimal v : values) {
                result += v;
            }
            result = result.divide(values.size(), 2, RoundingMode.HALF_UP);
        } else if (fn == 'MIN') {
            result = values[0];
            for (Decimal v : values) {
                if (v < result) {
                    result = v;
                }
            }
        } else if (fn == 'MAX') {
            result = values[0];
            for (Decimal v : values) {
                if (v > result) {
                    result = v;
                }
            }
        } else if (fn == 'COUNT') {
            String countResult = String.valueOf(values.size());
            if (numberFormat != null && isNumericFormat(numberFormat)) {
                return formatNumber(Decimal.valueOf(countResult), numberFormat);
            }
            return countResult;
        } else {
            return null;
        }

        // Apply format specifier if provided, otherwise strip trailing zeros
        if (numberFormat != null && isNumericFormat(numberFormat)) {
            return formatNumber(result, numberFormat);
        }
        return result.stripTrailingZeros().toPlainString();
    }

    /** Extracts the child record list from the data map. */
    private static List<Object> getChildRecords(Map<String, Object> data, String listName) {
        Object val = resolveValue(data, listName);
        if (val instanceof Map<String, Object>) {
            Map<String, Object> mapVal = (Map<String, Object>) val;
            if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                return (List<Object>) mapVal.get('records');
            }
        } else if (val instanceof List<Object>) {
            return (List<Object>) val;
        }
        return null;
    }

    /**
     * Converts rich text HTML to DOCX XML (w:p, w:r, w:t elements).
     * Preserves text, basic formatting (bold/italic/underline), multiple images, and paragraphs.
     * Returns DOCX XML that closes the current run/paragraph context and reopens it after.
     */
    private static String convertRichTextToDocxXml(String html) {
        // Normalize: replace common entities and whitespace
        html = html.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>');

        // Split into paragraphs by <p>, <div>, and <br> tags
        // First, normalize paragraph boundaries: replace </p><p>, </div><div>, <br>, <br/> with a delimiter
        String delim = '\n__PARA__\n';
        String normalized = html;
        normalized = normalized.replaceAll('(?i)</p>\\s*<p[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)</div>\\s*<div[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)<br\\s*/?>',  delim);
        normalized = normalized.replaceAll('(?i)</?p[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)</?div[^>]*>', delim);

        List<String> paragraphs = normalized.split(delim);

        // Build DOCX XML: close current context, emit paragraphs, reopen context
        String result = '</w:t></w:r>';  // close current run

        Boolean firstPara = true;
        for (String para : paragraphs) {
            String trimmed = para.trim();
            if (String.isBlank(trimmed)) { continue; }

            if (!firstPara) {
                result += '</w:p><w:p>';  // new paragraph
            } else {
                // Continue in the same paragraph as the merge tag
                firstPara = false;
            }

            // Process inline content within this paragraph
            result += processInlineHtml(trimmed);
        }

        // If we never output anything, just return empty text
        if (firstPara) {
            return '';
        }

        // Reopen run/text context for any content after the merge tag
        result += '<w:r><w:t xml:space="preserve">';
        return result;
    }

    /**
     * Processes inline HTML elements within a paragraph into DOCX w:r elements.
     * Handles <b>, <i>, <u>, <strong>, <em>, <span>, <img>, and plain text.
     */
    private static String processInlineHtml(String html) {
        String result = '';
        Integer cursor = 0;

        // Track formatting state
        Boolean isBold = false;
        Boolean isItalic = false;
        Boolean isUnderline = false;

        while (cursor < html.length()) {
            Integer nextTag = html.indexOf('<', cursor);

            if (nextTag == -1) {
                // Remaining plain text
                String text = html.substring(cursor).trim();
                if (String.isNotBlank(text)) {
                    result += buildRun(stripTags(text), isBold, isItalic, isUnderline);
                }
                break;
            }

            // Text before the tag
            if (nextTag > cursor) {
                String text = html.substring(cursor, nextTag);
                if (String.isNotBlank(text)) {
                    result += buildRun(stripTags(text), isBold, isItalic, isUnderline);
                }
            }

            // Find end of tag
            Integer tagEnd = html.indexOf('>', nextTag);
            if (tagEnd == -1) {
                break;
            }
            tagEnd++;

            String tag = html.substring(nextTag, tagEnd).toLowerCase();

            // Handle formatting tags
            if (tag.startsWith('<b>') || tag.startsWith('<b ') || tag.startsWith('<strong')) {
                isBold = true;
            } else if (tag.startsWith('</b>') || tag.startsWith('</strong')) {
                isBold = false;
            } else if (tag.startsWith('<i>') || tag.startsWith('<i ') || tag.startsWith('<em')) {
                isItalic = true;
            } else if (tag.startsWith('</i>') || tag.startsWith('</em')) {
                isItalic = false;
            } else if (tag.startsWith('<u>') || tag.startsWith('<u ')) {
                isUnderline = true;
            } else if (tag.startsWith('</u>')) {
                isUnderline = false;
            } else if (tag.startsWith('<img')) {
                // Extract image from <img> tag
                String imgTag = html.substring(nextTag, tagEnd);
                String imgResult = processRichTextImage(imgTag);
                if (imgResult != null) {
                    result += imgResult;
                }
            }
            // Skip other tags (spans, anchors, etc.) — just process their text content

            cursor = tagEnd;
        }

        return result;
    }

    /**
     * Builds a DOCX w:r (run) element with optional formatting.
     */
    private static String buildRun(String text, Boolean bold, Boolean italic, Boolean underline) {
        if (String.isBlank(text)) {
            return '';
        }
        String rPr = '';
        if (bold || italic || underline) {
            rPr = '<w:rPr>';
            if (bold) { rPr += '<w:b/>'; }
            if (italic) { rPr += '<w:i/>'; }
            if (underline) { rPr += '<w:u w:val="single"/>'; }
            rPr += '</w:rPr>';
        }
        return '<w:r>' + rPr + '<w:t xml:space="preserve">' + text.escapeXml() + '</w:t></w:r>';
    }

    /**
     * Strips any remaining HTML tags from text content.
     */
    private static String stripTags(String text) {
        return text.replaceAll('<[^>]+>', '');
    }

    /**
     * Processes an <img> tag from rich text, fetches the image, and returns DrawingML XML.
     */
    private static String processRichTextImage(String imgTag) {
        // Extract src attribute
        Integer srcIdx = imgTag.indexOfIgnoreCase('src=');
        if (srcIdx == -1) {
            return null;
        }
        srcIdx += 4;
        while (srcIdx < imgTag.length() && imgTag.substring(srcIdx, srcIdx + 1) == ' ') {
            srcIdx++;
        }
        String quoteChar = imgTag.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') {
            return null;
        }
        srcIdx++;
        Integer srcEnd = imgTag.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) {
            return null;
        }
        String src = imgTag.substring(srcIdx, srcEnd).replace('&amp;', '&');

        // Extract optional width/height
        Integer widthPx = null;
        Integer heightPx = null;
        Integer wIdx = imgTag.indexOfIgnoreCase('width=');
        if (wIdx != -1) {
            String wVal = extractHtmlAttrValue(imgTag, wIdx + 6);
            if (wVal != null && wVal.replaceAll('[^0-9]', '').isNumeric()) {
                widthPx = Integer.valueOf(wVal.replaceAll('[^0-9]', ''));
            }
        }
        Integer hIdx = imgTag.indexOfIgnoreCase('height=');
        if (hIdx != -1) {
            String hVal = extractHtmlAttrValue(imgTag, hIdx + 7);
            if (hVal != null && hVal.replaceAll('[^0-9]', '').isNumeric()) {
                heightPx = Integer.valueOf(hVal.replaceAll('[^0-9]', ''));
            }
        }

        // Resolve image: decode data URIs to blobs, store Salesforce URLs for PDF rendering.
        // No HTTP callouts or session IDs — AppExchange safe.
        Blob imageBlob = null;
        String ext = 'png';
        try {
            if (src.startsWith('data:image/')) {
                // Data URI — decode to blob (for DOCX embedding)
                String base64Part = src.substringAfter(',');
                if (src.containsIgnoreCase('jpeg') || src.containsIgnoreCase('jpg')) { ext = 'jpeg'; }
                imageBlob = EncodingUtil.base64Decode(base64Part);
            }
            // For Salesforce URLs (servlet, sfc, https), store URL for PDF rendering.
            // Blob.toPdf() resolves Salesforce URLs natively via the VF engine.
            if (src.containsIgnoreCase('.jpg') || src.containsIgnoreCase('.jpeg')) { ext = 'jpeg'; }
        } catch (Exception e) {
            // Image source parsing failed (invalid data URI, malformed HTML) — fall through to URL handling
            System.debug(LoggingLevel.ERROR, 'DocGenService: Image source parsing failed: ' + e.getMessage());
        }

        // Register image — store blob for DOCX and URL for PDF rendering.
        imageCounter++;
        String relId = 'rIdImg' + imageCounter;
        String fileName = 'docgen_image_' + imageCounter + '.' + ext;

        if (imageBlob != null) {
            Map<String, Object> imgData = new Map<String, Object>{
                'relId' => relId,
                'fileName' => fileName,
                'blob' => imageBlob
            };
            // Store source URL for PDF rendering (Blob.toPdf fetches images via URL)
            if (!src.startsWith('data:')) {
                imgData.put('url', src);
            }
            pendingImages.add(imgData);
        } else if (String.isNotBlank(src) && !src.startsWith('data:')) {
            // URL-only: store the URL. For PDF, Blob.toPdf() resolves Salesforce URLs natively.
            // For DOCX, the client-side assembly path will fetch the blob via browser session.
            pendingImages.add(new Map<String, Object>{
                'relId' => relId,
                'fileName' => fileName,
                'url' => src
            });
        } else {
            return null; // Can't resolve image at all
        }

        // Build DrawingML
        Integer widthEmu = (widthPx != null) ? (widthPx * 9525) : (288 * 12700);
        Integer heightEmu = (heightPx != null) ? (heightPx * 9525) : (216 * 12700);

        return '<w:r><w:drawing>' +
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
            '</w:drawing></w:r>';
    }

    /**
     * Extracts an HTML attribute value starting at the given position (after 'attr=').
     */
    private static String extractHtmlAttrValue(String tag, Integer startAfterEquals) {
        Integer pos = startAfterEquals;
        while (pos < tag.length() && tag.substring(pos, pos + 1) == ' ') {
            pos++;
        }
        if (pos >= tag.length()) {
            return null;
        }
        String ch = tag.substring(pos, pos + 1);
        if (ch == '"' || ch == '\'') {
            Integer end2 = tag.indexOf(ch, pos + 1);
            return end2 != -1 ? tag.substring(pos + 1, end2) : null;
        }
        // Unquoted value
        Integer end2 = pos;
        while (end2 < tag.length() && tag.substring(end2, end2 + 1) != ' ' && tag.substring(end2, end2 + 1) != '>') {
            end2++;
        }
        return tag.substring(pos, end2);
    }

    private static String buildImageXml(String fieldValue) {
        return buildImageXml(fieldValue, null, null);
    }

    private static String buildImageXml(String fieldValue, Integer widthPx, Integer heightPx) {
        if (String.isBlank(fieldValue)) {
            return null;
        }

        Blob imageBlob = null;
        String ext = 'png';
        String cvImageUrl = null;

        try {
            // 1. Rich text HTML containing <img> tags
            if (fieldValue.containsIgnoreCase('<img')) {
                imageBlob = extractImageFromHtml(fieldValue);
            }
            // 2. Base64 data URI
            else if (fieldValue.startsWith('data:image/')) {
                String base64Part = fieldValue.substringAfter(',');
                if (fieldValue.containsIgnoreCase('jpeg') || fieldValue.containsIgnoreCase('jpg')) { ext = 'jpeg'; }
                imageBlob = EncodingUtil.base64Decode(base64Part);
            }
            // 3. Raw base64 (no data URI prefix)
            else if (fieldValue.length() > 100 && !fieldValue.contains('/') && !fieldValue.contains(' ')) {
                imageBlob = EncodingUtil.base64Decode(fieldValue);
            }
            // 4. ContentVersion ID (starts with 068) — works for both DOCX (blob) and PDF (URL)
            else if (fieldValue.startsWith('068') && fieldValue.length() >= 15) {
                if (currentOutputFormat == 'PDF') {
                    // PDF path: only need the URL — Blob.toPdf() fetches images server-side.
                    // Skip loading the blob entirely to save heap.
                    List<ContentVersion> cvs = [SELECT Id, FileExtension FROM ContentVersion WHERE Id = :fieldValue WITH SYSTEM_MODE LIMIT 1];
                    if (!cvs.isEmpty()) {
                        if (cvs[0].FileExtension != null) { ext = cvs[0].FileExtension.toLowerCase(); }
                        cvImageUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                    }
                } else {
                    // DOCX path: need the blob for ZIP embedding
                    List<ContentVersion> cvs = [SELECT Id, VersionData, FileExtension FROM ContentVersion WHERE Id = :fieldValue WITH SYSTEM_MODE LIMIT 1];
                    if (!cvs.isEmpty()) {
                        imageBlob = cvs[0].VersionData;
                        if (cvs[0].FileExtension != null) { ext = cvs[0].FileExtension.toLowerCase(); }
                        cvImageUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                    }
                }
            }
            // 5. Salesforce file URL containing refid (rich text image reference)
            else if (fieldValue.containsIgnoreCase('refid=')) {
                String refId = fieldValue.substringAfterLast('refid=').substringBefore('&');
                if (String.isBlank(refId)) { refId = fieldValue.substringAfterLast('refid='); }
                imageBlob = fetchSalesforceImage(refId);
            }
            // 6. Salesforce servlet/sfc URL
            else if (fieldValue.containsIgnoreCase('/servlet/') || fieldValue.containsIgnoreCase('/sfc/')) {
                String docId = fieldValue.substringAfterLast('/');
                if (docId.contains('?')) { docId = docId.substringBefore('?'); }
                imageBlob = fetchSalesforceImage(docId);
            }
            // 7. Generic HTTPS URL — can't fetch without session ID (AppExchange safe).
            // For {%ImageField} tags, users should use ContentVersion IDs or data URIs.
            else if (fieldValue.startsWith('https://')) {
                // External URL images cannot be fetched without session ID — users should use ContentVersion IDs or data URIs
            }

            // If no blob but we have a URL, store it for PDF rendering
            // (Blob.toPdf resolves Salesforce URLs natively via the VF engine)
            String sourceUrl = cvImageUrl; // Use CV URL if already resolved (PDF path)
            if (imageBlob == null && sourceUrl == null) {
                // Try to extract a URL from the field value for PDF
                if (fieldValue.containsIgnoreCase('<img')) {
                    // HTML with img tag — extract src URL
                    Integer sIdx = fieldValue.indexOfIgnoreCase('src=');
                    if (sIdx != -1) {
                        sIdx += 4;
                        while (sIdx < fieldValue.length() && fieldValue.substring(sIdx, sIdx + 1) == ' ') { sIdx++; }
                        String qc = fieldValue.substring(sIdx, sIdx + 1);
                        if (qc == '"' || qc == '\'') {
                            sIdx++;
                            Integer sEnd = fieldValue.indexOf(qc, sIdx);
                            if (sEnd != -1) { sourceUrl = fieldValue.substring(sIdx, sEnd).replace('&amp;', '&'); }
                        }
                    }
                } else if (fieldValue.startsWithIgnoreCase('http') || fieldValue.startsWith('/')) {
                    sourceUrl = fieldValue;
                }

                if (String.isBlank(sourceUrl) || sourceUrl.startsWith('data:')) {
                    // Could not resolve image source — no blob or usable URL available
                    return null;
                }
            }

            imageCounter++;
            String relId = 'rIdImg' + imageCounter;
            String fileName = 'docgen_image_' + imageCounter + '.' + ext;

            // Register image — blob for DOCX, URL for PDF
            Map<String, Object> imgEntry = new Map<String, Object>{
                'relId' => relId,
                'fileName' => fileName
            };
            if (imageBlob != null) {
                imgEntry.put('blob', imageBlob);
            }
            // Prefer CV URL (committed, works for PDF), fall back to extracted source URL
            if (cvImageUrl != null) {
                imgEntry.put('url', cvImageUrl);
            } else if (sourceUrl != null) {
                imgEntry.put('url', sourceUrl);
            }
            pendingImages.add(imgEntry);

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
            // Image injection failed (invalid CV ID, corrupt base64, etc.) — skip this image
            return null;
        }
    }

    /**
     * Extracts the first image from rich text HTML.
     * Handles data URIs, Salesforce servlet URLs (via session-based auth), and refid references.
     */
    private static Blob extractImageFromHtml(String html) {
        // Use string parsing instead of regex to avoid "Regex too complicated" on large base64 data
        Integer imgIdx = html.indexOfIgnoreCase('<img');
        if (imgIdx == -1) {
            return null;
        }

        Integer srcIdx = html.indexOfIgnoreCase('src=', imgIdx);
        if (srcIdx == -1) {
            return null;
        }

        srcIdx += 4; // skip 'src='
        // Skip optional whitespace
        while (srcIdx < html.length() && html.substring(srcIdx, srcIdx + 1) == ' ') {
            srcIdx++;
        }

        // Determine quote character
        String quoteChar = html.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') {
            return null;
        }
        srcIdx++; // skip opening quote

        Integer srcEnd = html.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) {
            return null;
        }

        String src = html.substring(srcIdx, srcEnd).replace('&amp;', '&');

        // Data URI — decode to blob
        if (src.startsWith('data:image/')) {
            String base64Part = src.substringAfter(',');
            return EncodingUtil.base64Decode(base64Part);
        }

        // Salesforce URLs — can't fetch without session ID (AppExchange limitation).
        // For PDF, Blob.toPdf() resolves these URLs natively via the VF engine.
        // Return null here; the caller will use the URL path for PDF rendering.
        return null;
    }

    // No session-based HTTP fetch methods — AppExchange safe.
    // Blob.toPdf() resolves Salesforce URLs natively via the VF rendering engine.

    /**
     * Fetches image blob from a Salesforce file reference (ContentDocument ID or ContentVersion ID).
     */
    private static Blob fetchSalesforceImage(String fileRef) {
        if (String.isBlank(fileRef)) {
            return null;
        }
        try {
            // Try as ContentVersion ID first
            if (fileRef.startsWith('068')) {
                List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!cvs.isEmpty()) {
                    return cvs[0].VersionData;
                }
            }
            // Try as ContentDocument ID
            if (fileRef.startsWith('069')) {
                List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!docs.isEmpty() && docs[0].LatestPublishedVersionId != null) {
                    Id latestCvId = docs[0].LatestPublishedVersionId;
                    List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :latestCvId WITH SYSTEM_MODE LIMIT 1];
                    if (!cvs.isEmpty()) {
                        return cvs[0].VersionData;
                    }
                }
            }
            // Try as a generic ID that could be linked
            if (fileRef.length() >= 15) {
                List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :fileRef WITH SYSTEM_MODE LIMIT 1];
                if (!cvs.isEmpty()) {
                    return cvs[0].VersionData;
                }
            }
        } catch (Exception e) {
            // Image fetch failed (invalid ID, access denied) — return null to skip this image
            System.debug(LoggingLevel.ERROR, 'DocGenService: Image content fetch failed: ' + e.getMessage());
        }
        return null;
    }


    private static Id saveFile(Blob fileBlob, String title, Id recordId, String format, String type) {
        ContentVersion cv = new ContentVersion();
        String baseName = title != null ? title : 'Generated_Document';

        String ext = (type == 'PowerPoint') ? '.pptx' : '.docx';
        cv.Title = baseName;
        cv.PathOnClient = baseName + ext;
        cv.VersionData = fileBlob;
        cv.FirstPublishLocationId = recordId;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE].ContentDocumentId;
    }

    /**
     * Saves a PDF Blob as a ContentVersion attached to the record.
     */
    private static Id savePdfFile(Blob pdfBlob, String title, Id recordId) {
        ContentVersion cv = new ContentVersion();
        String baseName = title != null ? title : 'Generated_Document';
        cv.Title = baseName;
        cv.PathOnClient = baseName + '.pdf';
        cv.VersionData = pdfBlob;
        cv.FirstPublishLocationId = recordId;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE].ContentDocumentId;
    }
    /**
     * Extracts an attribute value from an XML tag string.
     * E.g., extractXmlAttrValue('<Relationship Id="rId1" Target="media/image1.png"/>', 'Id') returns 'rId1'
     */
    private static String extractXmlAttrValue(String tag, String attrName) {
        String search = attrName + '="';
        Integer start = tag.indexOf(search);
        if (start == -1) {
            return null;
        }
        start += search.length();
        Integer end2 = tag.indexOf('"', start);
        if (end2 == -1) {
            return null;
        }
        return tag.substring(start, end2);
    }

    private static String generateDocTitle(String format, Map<String, Object> data) {
        if (String.isBlank(format)) {
            return null;
        }
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

    // =========================================================================
    // Backward-compatibility stubs for removed signature classes.
    // Old orgs may still have DocGenSignatureSenderController and
    // DocGenSignatureService which reference these methods. The stubs
    // exist solely so those old classes compile during package upgrade.
    // They do nothing — signatures have been removed from DocGen.
    // =========================================================================

    /**
     * Backward-compatibility stub — always throws. Signatures have been removed from DocGen.
     * @param templateId Unused — stub only
     * @param recordIdStr Unused — stub only
     * @return Never returns — always throws DocGenException
     */
    public static Map<String, Object> mergeTemplateForSignature(Id templateId, String recordIdStr) {
        throw new DocGenException('Signatures have been removed from DocGen. Please delete the old signature classes from your org.');
    }
}