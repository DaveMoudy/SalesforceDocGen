public with sharing class DocGenService {

    // Collector for images to inject after XML processing
    private static List<Map<String, Object>> pendingImages = new List<Map<String, Object>>();
    private static Integer imageCounter = 0;
    private static String currentTemplateType = 'Word'; // Set before processXml calls
    private static String currentOutputFormat = 'Native'; // Set before processXml — PDF skips blob loading for images

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
        return mergeTemplate(templateId, recordId, null);
    }

    private static MergeResult mergeTemplate(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            dataMap = DocGenController.generateDocumentData(templateId, recordId);
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

        if (base64File == null) throw new DocGenException('Template file content is missing.');

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
        mr.relsPath = (templateType == 'PowerPoint')
            ? 'ppt/_rels/presentation.xml.rels'
            : 'word/_rels/document.xml.rels';
        mr.mediaPath = (templateType == 'PowerPoint') ? 'ppt/media/' : 'word/media/';

        // For PDF output, try the heap-efficient path: use pre-decomposed XML parts
        // saved as ContentVersions during template version save, skipping full ZIP decompression.
        // Saves ~1.5-2MB heap by avoiding base64 decode + ZIP reader + passthrough extraction.
        if (outputFormat == 'PDF' && templateType == 'Word') {
            currentOutputFormat = 'PDF';
            MergeResult pdfResult = tryMergeFromPreDecomposed(templateId, recordDataMap, mr);
            if (pdfResult != null) {
                mr = pdfResult;
                mr.docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
                if (mr.docTitle == null) mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
                return mr;
            }
        }

        // Full ZIP decompression path — used for DOCX/PPTX output or when pre-decomposed parts are unavailable
        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);

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
                currentTemplateType = templateType;
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

        // Collect existing template images into imageBase64ByRelId for HTML rendering.
        // Parse rels XML to map relId → media filename, then look up in passthroughEntries.
        if (mr.relsXml != null) {
            Integer relCursor = 0;
            while (relCursor < mr.relsXml.length()) {
                Integer relStart = mr.relsXml.indexOf('<Relationship ', relCursor);
                if (relStart == -1) break;
                Integer relSelfClose = mr.relsXml.indexOf('/>', relStart);
                Integer relClose = mr.relsXml.indexOf('>', relStart);
                if (relClose == -1) break;
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
        if (mr.docTitle == null) mr.docTitle = (String) resolveValue(recordDataMap, 'Name');

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
    private static MergeResult tryMergeFromPreDecomposed(Id templateId, Map<String, Object> recordDataMap, MergeResult mr) {
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (activeVersions.isEmpty()) return null;

        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
        List<ContentVersion> xmlCvs = [
            SELECT Id, Title, VersionData FROM ContentVersion
            WHERE Title LIKE :(xmlPrefix + '%')
            WITH SYSTEM_MODE
        ];

        if (xmlCvs.isEmpty()) return null;

        // Reconstruct XML entries and rels from pre-stored CVs
        for (ContentVersion cv : xmlCvs) {
            String key = cv.Title.substring(xmlPrefix.length());
            if (key == 'rels') {
                mr.relsXml = cv.VersionData.toString();
            } else {
                // Restore original path: word__document.xml → word/document.xml
                String originalPath = key.replace('__', '/');
                String xml = cv.VersionData.toString();
                currentTemplateType = mr.templateType;
                xml = mergeRunsInTags(xml);
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(originalPath, xml);
                if (originalPath == 'word/document.xml') {
                    mr.documentXml = xml;
                }
            }
        }

        if (mr.documentXml == null) return null;

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
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId) {
        return processDocument(templateId, recordId, null);
    }

    /**
     * Processes a template with optional pre-resolved images from the LWC.
     * The resolvedImages map contains originalUrl → base64DataUri entries
     * fetched by the browser (which has session access to Salesforce URLs).
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
        for (Map<String, Object> img : pendingImages) {
            String fileName = (String) img.get('fileName');
            String mediaPath = 'word/media/' + fileName;
            if (img.containsKey('url')) {
                String url = (String) img.get('url');
                if (url.contains('/version/download/')) {
                    imageCvIdMap.put(mediaPath, url.substringAfterLast('/'));
                }
            }
        }

        return new Map<String, Object>{
            'allXmlParts' => allXmlParts,
            'imageBase64Map' => imageBase64Map,
            'imageCvIdMap' => imageCvIdMap,
            'title' => mr.docTitle,
            'templateType' => mr.templateType
        };
    }

    /**
     * Extracts images from a template DOCX/PPTX file and saves them as ContentVersion
     * records linked to the template version. These committed CVs provide stable URLs
     * for Blob.toPdf() which cannot render data URI images (Flying Saucer limitation).
     * Each version gets its own set of images — no duplicates or confusion.
     */
    public static void extractAndSaveTemplateImages(Id templateId, Id versionId) {
        String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);
        if (fileContent == null) return;

        List<DocGen_Template__c> templates = [
            SELECT Type__c FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1
        ];
        if (templates.isEmpty()) return;
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
        if (relsXml != null) {
            ContentVersion relsCv = new ContentVersion();
            relsCv.Title = xmlPrefix + 'rels';
            relsCv.PathOnClient = xmlPrefix + 'rels.xml';
            relsCv.VersionData = Blob.valueOf(relsXml);
            relsCv.FirstPublishLocationId = versionId;
            newCvs.add(relsCv);
        }

        // Parse rels and save each image as a ContentVersion linked to the version record
        if (relsXml != null && !mediaEntries.isEmpty()) {
            String imgPrefix = 'docgen_tmpl_img_' + versionId + '_';

            Integer relCursor = 0;
            while (relCursor < relsXml.length()) {
                Integer relStart = relsXml.indexOf('<Relationship ', relCursor);
                if (relStart == -1) break;
                Integer relSelfClose = relsXml.indexOf('/>', relStart);
                Integer relClose = relsXml.indexOf('>', relStart);
                if (relClose == -1) break;
                Integer relEnd = (relSelfClose != -1 && relSelfClose < relClose) ? relSelfClose + 2 : relClose + 1;

                String relTag = relsXml.substring(relStart, relEnd);
                String relType = extractXmlAttrValue(relTag, 'Type');
                if (relType != null && relType.contains('/image')) {
                    String relId = extractXmlAttrValue(relTag, 'Id');
                    String target = extractXmlAttrValue(relTag, 'Target');
                    if (relId != null && target != null && target.startsWith('media/')) {
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
                        }
                    }
                }
                relCursor = relEnd;
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
                if (pathStart == -1) pathStart = url.indexOf('/servlet/');
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
    private static Blob renderPdf(MergeResult mr, Id templateId, Id recordId) {
        if (Test.isRunningTest()) {
            return Blob.toPdf('<html><body><p>Test PDF</p></body></html>');
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
        String html = DocGenHtmlRenderer.convertToHtml(mr.documentXml, pdfImages);

        // Blob.toPdf() with the Spring '26 Release Update resolves relative Salesforce
        // ContentVersion URLs (/sfc/servlet.shepherd/...) natively via the VF rendering engine.
        // If it fails (pre-Spring '26 or Release Update not enabled), fall back to
        // VF page renderAs="pdf" which resolves image URLs via session.
        try {
            return Blob.toPdf(html);
        } catch (Exception e) {
            System.debug(LoggingLevel.INFO, 'DocGen: Blob.toPdf() failed, using VF page fallback: ' + e.getMessage());
        }

        PageReference pdfPage = Page.DocGenPdfRenderer;
        pdfPage.getParameters().put('mode', 'document');
        pdfPage.getParameters().put('templateId', String.valueOf(templateId));
        pdfPage.getParameters().put('recordId', String.valueOf(recordId));
        return pdfPage.getContentAsPDF();
    }

    /**
     * Generates HTML for a document PDF using pre-committed template image URLs.
     * Called by DocGenPdfRendererController to render via VF renderAs="pdf".
     */
    public static String renderDocumentHtml(Id templateId, Id recordId) {
        MergeResult mr = mergeTemplate(templateId, recordId);

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Server-side PDF generation is only supported for Word templates.');
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
        return DocGenHtmlRenderer.convertToHtml(mr.documentXml, pdfImages);
    }

    /**
     * Generates a PDF Blob and title without saving to record.
     * Used by DocGenController for download mode.
     */
    public static Map<String, Object> generatePdfBlob(Id templateId, Id recordId) {
        MergeResult mr = mergeTemplate(templateId, recordId);

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
     * Deletes temporary image ContentVersion records (used by signature flow).
     */
    public static void cleanupTempImages(String batchKey) {
        if (String.isBlank(batchKey)) return;
        List<ContentVersion> tempCvs = [
            SELECT ContentDocumentId FROM ContentVersion
            WHERE Title LIKE :('docgen_tmp_' + batchKey + '_%')
            WITH SYSTEM_MODE
        ];
        if (!tempCvs.isEmpty()) {
            Set<Id> docIds = new Set<Id>();
            for (ContentVersion cv : tempCvs) {
                docIds.add(cv.ContentDocumentId);
            }
            if (!Schema.sObjectType.ContentDocument.isDeletable()) {
                throw new DocGenException('Insufficient access to delete temporary images.');
            }
            delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds];
        }
    }

    /**
     * Merges a template with record data and returns HTML using a custom image map.
     * Used by the batch PDF renderer to generate HTML with ContentVersion URLs
     * instead of data URIs, allowing Flying Saucer to render images in PDFs.
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
     * Returns ContentDocumentId.
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
                    if (val instanceof Boolean && (Boolean)val) {
                         sectionResult = processXml(innerXml, data);
                    } else if (val instanceof Map<String, Object>) {
                        Map<String, Object> mapVal = (Map<String, Object>) val;
                         if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                            List<Object> records = (List<Object>) mapVal.get('records');
                            for (Object item : records) {
                                if (item instanceof Map<String, Object>) sectionResult += processXml(innerXml, (Map<String, Object>) item);
                            }
                        } else {
                             sectionResult = processXml(innerXml, mapVal);
                        }
                    } else if (val instanceof List<Object>) {
                         List<Object> listVal = (List<Object>) val;
                         for (Object item : listVal) {
                              if (item instanceof Map<String, Object>) sectionResult += processXml(innerXml, (Map<String, Object>) item);
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
            if (current == null) return null;
        }
        return current;
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
            if (String.isBlank(trimmed)) continue;

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
            if (tagEnd == -1) break;
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
        if (String.isBlank(text)) return '';
        String rPr = '';
        if (bold || italic || underline) {
            rPr = '<w:rPr>';
            if (bold) rPr += '<w:b/>';
            if (italic) rPr += '<w:i/>';
            if (underline) rPr += '<w:u w:val="single"/>';
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
        if (srcIdx == -1) return null;
        srcIdx += 4;
        while (srcIdx < imgTag.length() && imgTag.substring(srcIdx, srcIdx + 1) == ' ') srcIdx++;
        String quoteChar = imgTag.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') return null;
        srcIdx++;
        Integer srcEnd = imgTag.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) return null;
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
                if (src.containsIgnoreCase('jpeg') || src.containsIgnoreCase('jpg')) ext = 'jpeg';
                imageBlob = EncodingUtil.base64Decode(base64Part);
            }
            // For Salesforce URLs (servlet, sfc, https), store URL for PDF rendering.
            // Blob.toPdf() resolves Salesforce URLs natively via the VF engine.
            if (src.containsIgnoreCase('.jpg') || src.containsIgnoreCase('.jpeg')) ext = 'jpeg';
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Rich text image processing error: ' + e.getMessage());
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
            // URL-only: no blob available, store URL for PDF rendering
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
        while (pos < tag.length() && tag.substring(pos, pos + 1) == ' ') pos++;
        if (pos >= tag.length()) return null;
        String ch = tag.substring(pos, pos + 1);
        if (ch == '"' || ch == '\'') {
            Integer end2 = tag.indexOf(ch, pos + 1);
            return end2 != -1 ? tag.substring(pos + 1, end2) : null;
        }
        // Unquoted value
        Integer end2 = pos;
        while (end2 < tag.length() && tag.substring(end2, end2 + 1) != ' ' && tag.substring(end2, end2 + 1) != '>') end2++;
        return tag.substring(pos, end2);
    }

    private static String buildImageXml(String fieldValue) {
        return buildImageXml(fieldValue, null, null);
    }

    private static String buildImageXml(String fieldValue, Integer widthPx, Integer heightPx) {
        if (String.isBlank(fieldValue)) return null;

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
                if (fieldValue.containsIgnoreCase('jpeg') || fieldValue.containsIgnoreCase('jpg')) ext = 'jpeg';
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
                        if (cvs[0].FileExtension != null) ext = cvs[0].FileExtension.toLowerCase();
                        cvImageUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                    }
                } else {
                    // DOCX path: need the blob for ZIP embedding
                    List<ContentVersion> cvs = [SELECT Id, VersionData, FileExtension FROM ContentVersion WHERE Id = :fieldValue WITH SYSTEM_MODE LIMIT 1];
                    if (!cvs.isEmpty()) {
                        imageBlob = cvs[0].VersionData;
                        if (cvs[0].FileExtension != null) ext = cvs[0].FileExtension.toLowerCase();
                        cvImageUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                    }
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
            // 7. Generic HTTPS URL — can't fetch without session ID (AppExchange safe).
            // For {%ImageField} tags, users should use ContentVersion IDs or data URIs.
            else if (fieldValue.startsWith('https://')) {
                System.debug(LoggingLevel.WARN, 'DocGen: External URL images require ContentVersion ID or data URI: ' + fieldValue.left(200));
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
                        while (sIdx < fieldValue.length() && fieldValue.substring(sIdx, sIdx + 1) == ' ') sIdx++;
                        String qc = fieldValue.substring(sIdx, sIdx + 1);
                        if (qc == '"' || qc == '\'') {
                            sIdx++;
                            Integer sEnd = fieldValue.indexOf(qc, sIdx);
                            if (sEnd != -1) sourceUrl = fieldValue.substring(sIdx, sEnd).replace('&amp;', '&');
                        }
                    }
                } else if (fieldValue.startsWithIgnoreCase('http') || fieldValue.startsWith('/')) {
                    sourceUrl = fieldValue;
                }

                if (String.isBlank(sourceUrl) || sourceUrl.startsWith('data:')) {
                    System.debug(LoggingLevel.WARN, 'DocGen: Could not resolve image from: ' + fieldValue.left(200));
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
            System.debug(LoggingLevel.ERROR, 'DocGen: Image injection error: ' + e.getMessage());
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
        if (start == -1) return null;
        start += search.length();
        Integer end2 = tag.indexOf('"', start);
        if (end2 == -1) return null;
        return tag.substring(start, end2);
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