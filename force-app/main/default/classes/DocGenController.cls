public with sharing class DocGenController {
    
    @AuraEnabled
    public static Map<String, Object> generateDocumentData(Id templateId, Id recordId) {
        if (templateId == null) throw new DocGenException('Template ID is missing.');

        List<DocGen_Template__c> templates = [
            SELECT Base_Object_API__c, Query_Config__c, Type__c, Output_Format__c, Document_Title_Format__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (templates.isEmpty()) {
            throw new DocGenException('Unable to access template. Verify it exists and you have permission.');
        }
        DocGen_Template__c template = templates[0];

        Map<String, Object> recordData = DocGenDataRetriever.getRecordData(
            recordId,
            template.Base_Object_API__c,
            template.Query_Config__c
        );

        String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);

        if (recordData == null) {
            throw new DocGenException('Record data not found.');
        }

        // Pre-resolve Salesforce rich text image URLs to base64 data URIs
        resolveRichTextImages(recordData);

        return new Map<String, Object>{
            'data' => recordData,
            'templateFile' => fileContent,
            'templateType' => template.Type__c,
            'outputFormat' => template.Output_Format__c,
            'titleFormat' => template.Document_Title_Format__c
        };
    }

    @AuraEnabled
    public static Id saveGeneratedDocument(Id recordId, String fileName, String base64Data, String extension) {
        try {
            ContentVersion cv = new ContentVersion();
            cv.Title = fileName;
            cv.PathOnClient = fileName + (extension.startsWith('.') ? extension : '.' + extension);
            cv.VersionData = EncodingUtil.base64Decode(base64Data);
            cv.IsMajorVersion = true;
            SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
            insert cvDecision.getRecords();
            Id cvId = cvDecision.getRecords()[0].Id;

            Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cvId WITH USER_MODE].ContentDocumentId;

            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = contentDocId;
            cdl.LinkedEntityId = recordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDocumentLink>{ cdl });
            insert cdlDecision.getRecords();

            return contentDocId;
        } catch (System.NoAccessException e) {
            throw new DocGenException('Insufficient access to save document: ' + e.getMessage());
        } catch (Exception e) {
            throw new DocGenException('Error saving document to record: ' + e.getMessage());
        }
    }

    /**
     * Processes a template server-side and returns the document as base64, along with
     * the title, output format, and template type. Used by LWC for download/preview.
     */
    @AuraEnabled
    public static Map<String, Object> processAndReturnDocument(Id templateId, Id recordId) {
        return processAndReturnDocumentWithImages(templateId, recordId, null);
    }

    /**
     * Processes a template with record data and optional pre-resolved images.
     * The LWC can fetch RTF images via the browser session and pass them as
     * a map of originalUrl → base64DataUri. This enables DOCX image embedding
     * without server-side HTTP callouts (AppExchange safe).
     */
    @AuraEnabled
    public static Map<String, Object> processAndReturnDocumentWithImages(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        try {
            Map<String, Object> result = DocGenService.processDocument(templateId, recordId, resolvedImages);
            Blob docBlob = (Blob) result.get('blob');
            return new Map<String, Object>{
                'base64' => EncodingUtil.base64Encode(docBlob),
                'title' => result.get('title'),
                'outputFormat' => result.get('outputFormat'),
                'templateType' => result.get('templateType')
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error generating document: ' + e.getMessage());
            throw new AuraHandledException('Error generating document. Please check the template configuration.');
        }
    }

    /**
     * Returns merged document parts for client-side DOCX assembly.
     * Server merges the XML (lightweight). Client fetches the shell ZIP and images
     * by URL, then assembles the final DOCX — no server-side ZIP, zero heap for large docs.
     */
    @AuraEnabled
    public static Map<String, Object> generateDocumentParts(Id templateId, Id recordId) {
        try {
            return DocGenService.generateDocumentParts(templateId, recordId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error generating document parts: ' + e.getMessage());
            throw new AuraHandledException('Error generating document parts. Please check the template configuration.');
        }
    }

    /**
     * Returns a single ContentVersion's binary data as base64.
     * Called by the client in a loop — each call is its own transaction with fresh heap.
     * This enables client-side DOCX assembly with unlimited images.
     */
    @AuraEnabled
    public static String getContentVersionBase64(Id contentVersionId) {
        List<ContentVersion> cvs = [
            SELECT VersionData FROM ContentVersion WHERE Id = :contentVersionId WITH SYSTEM_MODE LIMIT 1
        ];
        if (cvs.isEmpty()) return null;
        return EncodingUtil.base64Encode(cvs[0].VersionData);
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> previewRecordData(Id recordId, String baseObject, String queryConfig) {
        if (recordId == null || String.isBlank(baseObject) || String.isBlank(queryConfig)) {
            return null;
        }
        
        try {
            return DocGenDataRetriever.getRecordData(recordId, baseObject, queryConfig);
        } catch (Exception e) {
            throw new DocGenException('Error fetching preview data: ' + e.getMessage());
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getTemplatesForObject(String objectApiName) {
        return [
            SELECT Id, Name, Description__c, Type__c, Output_Format__c, Is_Default__c
            FROM DocGen_Template__c
            WHERE Base_Object_API__c = :objectApiName
            WITH SYSTEM_MODE
            ORDER BY Is_Default__c DESC, Name ASC
        ];
    }
    
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getAllTemplates() {
        return [
            SELECT Id, Name, Description__c, Type__c, Base_Object_API__c, Category__c, Query_Config__c,
                   Test_Record_Id__c, Output_Format__c, Document_Title_Format__c, Is_Default__c,
                   (SELECT ContentDocumentId FROM ContentDocumentLinks ORDER BY ContentDocument.CreatedDate DESC LIMIT 1)
            FROM DocGen_Template__c
            WITH SYSTEM_MODE
            ORDER BY Category__c ASC, Name ASC
        ];
    }

    @AuraEnabled
    public static void saveTemplate(Map<String, Object> fields, Boolean createVersion) {
        try {
            // 1. Update Template
            Id templateId = (Id) fields.get('Id');
            DocGen_Template__c template = new DocGen_Template__c(Id = templateId);
            template.Name = (String) fields.get('Name');
            template.Category__c = (String) fields.get('Category__c');
            template.Type__c = (String) fields.get('Type__c');
            template.Base_Object_API__c = (String) fields.get('Base_Object_API__c');
            template.Description__c = (String) fields.get('Description__c');
            template.Query_Config__c = (String) fields.get('Query_Config__c');
            template.Test_Record_Id__c = (String) fields.get('Test_Record_Id__c');
            template.Document_Title_Format__c = (String) fields.get('Document_Title_Format__c');
            
            // Update Output Format if provided
            if (fields.containsKey('Output_Format__c')) {
                template.Output_Format__c = (String) fields.get('Output_Format__c');
            }
            // Update Default flag if provided
            if (fields.containsKey('Is_Default__c')) {
                template.Is_Default__c = (Boolean) fields.get('Is_Default__c');
            }
            // Package-internal object — CRUD controlled by DocGen permission sets
            update template;

            // 2. Create Version if requested
            if (createVersion == true) {
                // Deactivate current active versions
                List<DocGen_Template_Version__c> activeVersions = [
                    SELECT Id FROM DocGen_Template_Version__c
                    WHERE Template__c = :templateId AND Is_Active__c = true
                    WITH SYSTEM_MODE
                ];
                for (DocGen_Template_Version__c av : activeVersions) {
                    av.Is_Active__c = false;
                }
                if (!activeVersions.isEmpty()) {
                    // Package-internal object — CRUD controlled by DocGen permission sets
                    update activeVersions;
                }

                // Get latest ContentVersionId
                List<ContentDocumentLink> links = [
                    SELECT ContentDocument.LatestPublishedVersionId
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId = :templateId
                    WITH USER_MODE
                    ORDER BY ContentDocument.CreatedDate DESC
                    LIMIT 1
                ];

                String cvId = null;
                if (!links.isEmpty()) {
                    cvId = links[0].ContentDocument.LatestPublishedVersionId;
                }

                DocGen_Template_Version__c version = new DocGen_Template_Version__c();
                version.Template__c = templateId;
                version.Query_Config__c = (String) fields.get('Query_Config__c');
                version.Content_Version_Id__c = cvId;
                version.Is_Active__c = true;

                // Snapshot Headers
                version.Category__c = (String) fields.get('Category__c');
                version.Description__c = (String) fields.get('Description__c');
                version.Type__c = (String) fields.get('Type__c');
                version.Base_Object_API__c = (String) fields.get('Base_Object_API__c');

                // Package-internal object — CRUD controlled by DocGen permission sets
                insert version;

                // Extract images from DOCX/PPTX and save as ContentVersions linked to the version.
                // Blob.toPdf() cannot render data URI images — needs committed CV URLs.
                try {
                    DocGenService.extractAndSaveTemplateImages(templateId, version.Id);
                } catch (Exception imgErr) {
                    System.debug(LoggingLevel.WARN, 'DocGen: Template image extraction: ' + imgErr.getMessage());
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error saving template: ' + e.getMessage());
            throw new AuraHandledException('Error saving template. Please verify your inputs and permissions.');
        }
    }

    @AuraEnabled
    public static void deleteTemplate(Id templateId) {
        try {
            if (!Schema.sObjectType.DocGen_Template__c.isDeletable()) {
                throw new AuraHandledException('Insufficient access.');
            }
            delete new DocGen_Template__c(Id = templateId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error deleting template: ' + e.getMessage());
            throw new AuraHandledException('Error deleting template. Please check your permissions.');
        }
    }

    @AuraEnabled
    public static List<DocGen_Template_Version__c> getTemplateVersions(Id templateId) {
        return [
            SELECT Id, Name, CreatedDate, CreatedBy.Name, Query_Config__c, Content_Version_Id__c, 
                   Category__c, Description__c, Type__c, Base_Object_API__c, Is_Active__c
            FROM DocGen_Template_Version__c 
            WHERE Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    @AuraEnabled
    public static void activateVersion(Id versionId) {
        try {
            DocGen_Template_Version__c version = [
                SELECT Template__c, Query_Config__c, Content_Version_Id__c, Category__c, Description__c, Type__c, Base_Object_API__c
                FROM DocGen_Template_Version__c 
                WHERE Id = :versionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            
            // 1. Deactivate others
            List<DocGen_Template_Version__c> others = [
                SELECT Id FROM DocGen_Template_Version__c 
                WHERE Template__c = :version.Template__c AND Is_Active__c = true
                WITH SYSTEM_MODE
            ];
            for (DocGen_Template_Version__c v : others) {
                v.Is_Active__c = false;
            }
            // Package-internal objects — CRUD controlled by DocGen permission sets
            if (!others.isEmpty()) {
                update others;
            }

            // 2. Activate this one
            version.Is_Active__c = true;
            // Package-internal object — CRUD controlled by DocGen permission sets
            update version;

            // 3. Update Template Record Headline
            DocGen_Template__c template = new DocGen_Template__c(Id = version.Template__c);
            template.Query_Config__c = version.Query_Config__c;
            template.Category__c = version.Category__c;
            template.Description__c = version.Description__c;
            template.Type__c = version.Type__c;
            template.Base_Object_API__c = version.Base_Object_API__c;

            // Package-internal object — CRUD controlled by DocGen permission sets
            update template;
            
        } catch (Exception e) {
            throw new DocGenException('Error activating version: ' + e.getMessage());
        }
    }

    /**
     * Unified PDF generation. Uses the same code path as bulk batch generation.
     * For "save" mode: saves PDF to record via DocGenService.generateDocument().
     * For "download" mode: returns base64 PDF via DocGenService.generatePdfBlob().
     */
    @AuraEnabled
    public static Map<String, Object> generatePdf(Id templateId, Id recordId, Boolean saveToRecord) {
        try {
            if (saveToRecord) {
                Id contentDocId = DocGenService.generateDocument(templateId, recordId);
                return new Map<String, Object>{
                    'saved' => true,
                    'contentDocumentId' => contentDocId
                };
            } else {
                Map<String, Object> result = DocGenService.generatePdfBlob(templateId, recordId);
                Blob pdfBlob = (Blob) result.get('blob');
                String docTitle = (String) result.get('title');
                return new Map<String, Object>{
                    'base64' => EncodingUtil.base64Encode(pdfBlob),
                    'title' => docTitle
                };
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error generating PDF: ' + e.getMessage());
            throw new AuraHandledException('Error generating PDF document. Please check the template configuration.');
        }
    }

    // --- Schema Methods for Query Builder ---

    public class Option implements Comparable {
         public String label;
         public String value;
         public String childObjectApiName;

         public Option(String label, String value) {
             this.label = label;
             this.value = value;
         }
         
         public Option(String label, String value, String childObjectApiName) {
             this.label = label;
             this.value = value;
             this.childObjectApiName = childObjectApiName;
         }

         public Integer compareTo(Object compareTo) {
             Option other = (Option) compareTo;
             if (label == other.label) return 0;
             if (label > other.label) return 1;
             return -1;
         }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectOptions() {
        List<Option> sortedOptions = new List<Option>();
        for (Schema.SObjectType sobj : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult describe = sobj.getDescribe();
            if (describe.isQueryable() && !describe.isDeprecatedAndHidden()) {
                sortedOptions.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
            }
        }
        sortedOptions.sort();
        
        List<Map<String, String>> options = new List<Map<String, String>>();
        for (Option opt : sortedOptions) {
            options.add(new Map<String, String>{'label' => opt.label, 'value' => opt.value});
        }
        return options;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectFields(String objectName) {
        List<Option> sortedFields = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return new List<Map<String, String>>();

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.isAccessible()) {
                sortedFields.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
            }
        }
        sortedFields.sort();

        List<Map<String, String>> fields = new List<Map<String, String>>();
        for (Option opt : sortedFields) {
            fields.add(new Map<String, String>{'label' => opt.label, 'value' => opt.value});
        }
        return fields;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getChildRelationships(String objectName) {
        List<Option> sortedRels = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return new List<Map<String, String>>();

        for (Schema.ChildRelationship child : objType.getDescribe().getChildRelationships()) {
            if (child.getRelationshipName() != null) {
                sortedRels.add(new Option(
                    child.getRelationshipName() + ' (' + child.getChildSObject().getDescribe().getLabel() + ')',
                    child.getRelationshipName(),
                    child.getChildSObject().getDescribe().getName()
                ));
            }
        }
        sortedRels.sort();

        List<Map<String, String>> relationships = new List<Map<String, String>>();
        for (Option opt : sortedRels) {
            relationships.add(new Map<String, String>{
                'label' => opt.label, 
                'value' => opt.value,
                'childObjectApiName' => opt.childObjectApiName
            });
        }
        return relationships;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getParentRelationships(String objectName) {
        List<Option> sortedParents = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return new List<Map<String, String>>();

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
             Schema.DescribeFieldResult describe = field.getDescribe();
             if (describe.getType() == Schema.DisplayType.REFERENCE) {
                 // Ignore polymorphic for now or handle carefully
                 if (describe.getReferenceTo().size() > 0) {
                     String relationshipName = describe.getRelationshipName();
                     String targetObject = describe.getReferenceTo()[0].getDescribe().getName(); // Take first parent for now
                     if (relationshipName != null) {
                        sortedParents.add(new Option(
                            describe.getLabel() + ' (' + relationshipName + ')',
                            relationshipName,
                            targetObject
                        ));
                     }
                 }
             }
        }
        sortedParents.sort();

        List<Map<String, String>> parents = new List<Map<String, String>>();
        for (Option opt : sortedParents) {
            parents.add(new Map<String, String>{
                'label' => opt.label, 
                'value' => opt.value, 
                'targetObject' => opt.childObjectApiName // Reusing field
            });
        }
        return parents;
    }

    // Sample data creation method removed per cleanup request.

    // --- Template Sharing Logic ---

    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getTemplateShares(Id templateId) {
        List<Map<String, String>> shares = new List<Map<String, String>>();
        
        List<SObject> shareRecords = Database.query(
            'SELECT Id, UserOrGroupId, UserOrGroup.Name, AccessLevel, RowCause ' +
            'FROM DocGen_Template__Share ' +
            'WHERE ParentId = :templateId AND RowCause != \'Owner\' WITH SYSTEM_MODE'
        );

        for (SObject s : shareRecords) {
            Map<String, String> row = new Map<String, String>();
            row.put('Id', (String)s.get('Id'));
            row.put('UserOrGroupId', (String)s.get('UserOrGroupId'));
            row.put('UserOrGroupName', (String)s.getSObject('UserOrGroup').get('Name'));
            row.put('AccessLevel', (String)s.get('AccessLevel'));
            row.put('RowCause', (String)s.get('RowCause'));
            shares.add(row);
        }
        return shares;
    }

    @AuraEnabled
    public static void shareTemplate(Id templateId, Id userOrGroupId, String accessLevel) {
        SObject share = Schema.getGlobalDescribe().get('DocGen_Template__Share').newSObject();
        share.put('ParentId', templateId);
        share.put('UserOrGroupId', userOrGroupId);
        share.put('AccessLevel', accessLevel);
        share.put('RowCause', 'Manual');
        
        try {
            SObjectAccessDecision shareDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<SObject>{ share });
            insert shareDecision.getRecords();
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error sharing template: ' + e.getMessage());
            throw new AuraHandledException('Error sharing template. Please check permissions.');
        }
    }

    @AuraEnabled
    public static void removeShare(Id shareId) {
        try {
            if (!Schema.sObjectType.DocGen_Template__c.isDeletable()) {
                throw new AuraHandledException('Insufficient access.');
            }
            delete new DocGen_Template__Share(Id = shareId);
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error removing share: ' + e.getMessage());
            throw new AuraHandledException('Error removing share. Please check permissions.');
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchUsersAndGroups(String searchTerm) {
        String key = '%' + searchTerm + '%';
        List<Map<String, String>> results = new List<Map<String, String>>();

        for (User u : [SELECT Id, Name FROM User WHERE Name LIKE :key AND IsActive = TRUE WITH USER_MODE LIMIT 10]) {
             Map<String, String> row = new Map<String, String>();
             row.put('Id', u.Id);
             row.put('Name', u.Name);
             row.put('Type', 'User');
             row.put('Icon', 'standard:user');
             results.add(row);
        }

        for (Group g : [SELECT Id, Name FROM Group WHERE Name LIKE :key AND Type = 'Regular' WITH USER_MODE LIMIT 10]) {
             Map<String, String> row = new Map<String, String>();
             row.put('Id', g.Id);
             row.put('Name', g.Name);
             row.put('Type', 'Group');
             row.put('Icon', 'standard:groups');
             results.add(row);
        }
        return results;
    }

    // --- Rich Text Image Resolution ---

    /**
     * Recursively walks record data and normalizes Salesforce image URLs in rich text
     * fields to absolute URLs. No HTTP callouts — Blob.toPdf() resolves Salesforce URLs
     * natively via the VF rendering engine. For DOCX, processRichTextImage fetches blobs
     * using the URL. No session IDs needed (AppExchange safe).
     */
    private static void resolveRichTextImages(Object data) {
        if (data instanceof Map<String, Object>) {
            Map<String, Object> mapData = (Map<String, Object>) data;

            for (String key : new List<String>(mapData.keySet())) {
                Object val = mapData.get(key);
                if (val instanceof String) {
                    String strVal = (String) val;
                    if (strVal.containsIgnoreCase('<img') &&
                        (strVal.containsIgnoreCase('refid=') || strVal.containsIgnoreCase('/servlet/') || strVal.containsIgnoreCase('/sfc/'))) {
                        mapData.put(key, normalizeImageUrls(strVal));
                    }
                } else {
                    resolveRichTextImages(val);
                }
            }
        } else if (data instanceof List<Object>) {
            for (Object item : (List<Object>) data) {
                resolveRichTextImages(item);
            }
        }
    }

    /**
     * Normalizes relative Salesforce image URLs to absolute URLs.
     * No HTTP callouts, no session IDs. Blob.toPdf() resolves these natively.
     */
    private static String normalizeImageUrls(String html) {
        try {
            String baseUrl = URL.getOrgDomainUrl().toExternalForm();
            html = html.replaceAll('(?i)(src\\s*=\\s*["\'])(/servlet/)', '$1' + baseUrl + '$2');
            html = html.replaceAll('(?i)(src\\s*=\\s*["\'])(/sfc/)', '$1' + baseUrl + '$2');
            return html;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: normalizeImageUrls failed: ' + e.getMessage());
            return html;
        }
    }

    // =========================================================================
    // Report Import — extract columns and filters from existing Salesforce Reports
    // =========================================================================

    /**
     * Returns PDF files attached to a record (for PDF merger).
     * Each entry has a label (file title) and value (ContentVersion ID).
     */
    @AuraEnabled
    public static List<Map<String, String>> getRecordPdfs(Id recordId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, ContentDocument.LatestPublishedVersionId,
                   ContentDocument.Title, ContentDocument.FileExtension
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            AND ContentDocument.FileExtension = 'pdf'
            WITH SYSTEM_MODE
            ORDER BY ContentDocument.Title
        ];

        List<Map<String, String>> result = new List<Map<String, String>>();
        for (ContentDocumentLink link : links) {
            result.add(new Map<String, String>{
                'label' => link.ContentDocument.Title + '.pdf',
                'value' => link.ContentDocument.LatestPublishedVersionId
            });
        }
        return result;
    }

    /**
     * Returns available reports the user can access.
     * Searches by name if a search term is provided.
     */
    @AuraEnabled
    public static List<Map<String, String>> getAvailableReports(String searchTerm) {
        String query = 'SELECT Id, Name, DeveloperName, FolderName FROM Report';
        if (String.isNotBlank(searchTerm)) {
            String safeTerm = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' WHERE Name LIKE :safeTerm';
        }
        query += ' ORDER BY Name LIMIT 50';

        List<Map<String, String>> results = new List<Map<String, String>>();
        for (Report r : Database.query(query)) {
            results.add(new Map<String, String>{
                'id' => r.Id,
                'name' => r.Name,
                'folder' => r.FolderName
            });
        }
        return results;
    }

    /**
     * Imports a report's columns and filters as a DocGen query config.
     * Uses the Reports API to describe the report, then normalizes
     * column names to SOQL field API names.
     */
    @AuraEnabled
    public static Map<String, Object> importReportConfig(Id reportId) {
        if (reportId == null) {
            throw new AuraHandledException('Report ID is required.');
        }

        Reports.ReportDescribeResult describe = Reports.ReportManager.describeReport(reportId);
        Reports.ReportMetadata metadata = describe.getReportMetadata();
        Reports.ReportExtendedMetadata extMeta = describe.getReportExtendedMetadata();

        // Determine base object from report type
        String reportTypeName = metadata.getReportType().getType();
        String reportTypeLabel = metadata.getReportType().getLabel();
        String baseObject = resolveReportBaseObject(reportTypeName, reportTypeLabel);
        if (baseObject == null) {
            throw new AuraHandledException('Could not determine the base object for this report. Report type: ' + reportTypeName);
        }

        // Get the field map for normalization
        SObjectType objType = Schema.getGlobalDescribe().get(baseObject);
        if (objType == null) {
            throw new AuraHandledException('Object not found: ' + baseObject);
        }
        Map<String, SObjectField> fieldMap = objType.getDescribe().fields.getMap();

        // Build label → proper API name map, and lowercase key → proper API name map
        Map<String, String> labelToApiName = new Map<String, String>();
        Map<String, String> properCaseMap = new Map<String, String>();
        for (String apiName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
            String properName = dfr.getName(); // Proper-cased: 'BillingState', 'Name', etc.
            labelToApiName.put(dfr.getLabel().toLowerCase(), properName);
            properCaseMap.put(apiName.toLowerCase(), properName);
        }

        // Build parent relationship prefix map: USERS → Owner, ACCOUNT → Account, etc.
        Map<String, String> parentPrefixMap = new Map<String, String>();
        for (SObjectField sof : fieldMap.values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getRelationshipName() != null && dfr.getReferenceTo() != null && !dfr.getReferenceTo().isEmpty()) {
                String refObjName = dfr.getReferenceTo()[0].getDescribe().getName().toUpperCase();
                parentPrefixMap.put(refObjName, dfr.getRelationshipName());
                if (dfr.getName() == 'OwnerId') parentPrefixMap.put('USERS', dfr.getRelationshipName());
                if (dfr.getName() == 'CreatedById') parentPrefixMap.put('CREATED_BY', dfr.getRelationshipName());
            }
        }

        // For cross-object reports (OpportunityContactProduct), build child object field maps
        // so we can route columns like FIRST_NAME to the Contact child, PRODUCT_NAME to LineItems
        Map<String, String> childRelNameByObject = new Map<String, String>();
        Map<String, Map<String, SObjectField>> childFieldMaps = new Map<String, Map<String, SObjectField>>();
        Map<String, Map<String, String>> childLabelMaps = new Map<String, Map<String, String>>();
        Map<String, Map<String, String>> childProperCaseMaps = new Map<String, Map<String, String>>();

        // Detect child objects from the report type name
        Map<String, String> reportTypeChildObjects = new Map<String, String>{
            'OpportunityContactProduct' => 'Contact,OpportunityLineItem',
            'OpportunityContact' => 'Contact',
            'OpportunityProduct' => 'OpportunityLineItem',
            'OpportunityLead' => 'Lead',
            'AccountContact' => 'Contact',
            'AccountCase' => 'Case',
            'CaseContact' => 'Contact',
            'CampaignMember' => 'Contact,Lead',
            'QuoteProduct' => 'Quote',
            'QuoteList' => 'Quote'
        };

        if (reportTypeChildObjects.containsKey(reportTypeName)) {
            for (String childObjName : reportTypeChildObjects.get(reportTypeName).split(',')) {
                // Find the relationship name for this child on the base object
                Boolean found = false;
                for (Schema.ChildRelationship cr : objType.getDescribe().getChildRelationships()) {
                    if (cr.getChildSObject().getDescribe().getName() == childObjName && cr.getRelationshipName() != null) {
                        childRelNameByObject.put(childObjName, cr.getRelationshipName());
                        found = true;
                        break;
                    }
                }
                // If not a direct child (e.g., Contact via OpportunityContactRole), skip SOQL routing
                // but still build the field map for label-based column detection
                if (!found) {
                    // Not a direct child — find the known junction relationship
                    // Known junction paths by base+target object
                    Map<String, String> knownJunctions = new Map<String, String>{
                        'Opportunity:Contact' => 'OpportunityContactRoles',
                        'Account:Contact' => 'AccountContactRelations',
                        'Campaign:Contact' => 'CampaignMembers',
                        'Campaign:Lead' => 'CampaignMembers'
                    };
                    String junctionKey = baseObject + ':' + childObjName;
                    String junctionRelName = knownJunctions.get(junctionKey);

                    // Fallback: scan child relationships for a junction object
                    if (junctionRelName == null) {
                        for (Schema.ChildRelationship cr : objType.getDescribe().getChildRelationships()) {
                            if (cr.getRelationshipName() == null) continue;
                            String jObjName = cr.getChildSObject().getDescribe().getName();
                            // Skip known non-junction objects
                            if (jObjName.endsWith('History') || jObjName.endsWith('Share') || jObjName.endsWith('Feed')) continue;
                            for (Schema.SObjectField jf : cr.getChildSObject().getDescribe().fields.getMap().values()) {
                                Schema.DescribeFieldResult jdfr = jf.getDescribe();
                                if (jdfr.getType() == Schema.DisplayType.REFERENCE && jdfr.getReferenceTo() != null) {
                                    for (Schema.SObjectType ref : jdfr.getReferenceTo()) {
                                        if (ref.getDescribe().getName() == childObjName) {
                                            junctionRelName = cr.getRelationshipName();
                                            break;
                                        }
                                    }
                                }
                                if (junctionRelName != null) break;
                            }
                            if (junctionRelName != null) break;
                        }
                    }
                    childRelNameByObject.put(childObjName,
                        junctionRelName != null ? '__junction_' + childObjName + ':' + junctionRelName : '__junction_' + childObjName);
                }

                // Build field maps for label matching regardless
                SObjectType childType = Schema.getGlobalDescribe().get(childObjName);
                if (childType != null) {
                    Map<String, SObjectField> cfm = childType.getDescribe().fields.getMap();
                    childFieldMaps.put(childObjName, cfm);
                    Map<String, String> clm = new Map<String, String>();
                    Map<String, String> cpm = new Map<String, String>();
                    for (String fn : cfm.keySet()) {
                        Schema.DescribeFieldResult cdfr = cfm.get(fn).getDescribe();
                        clm.put(cdfr.getLabel().toLowerCase(), cdfr.getName());
                        cpm.put(fn.toLowerCase(), cdfr.getName());
                    }
                    childLabelMaps.put(childObjName, clm);
                    childProperCaseMaps.put(childObjName, cpm);
                }
            }
        }

        // Also discover grandchildren (e.g., Quote → QuoteLineItems) so their
        // field labels can match against report columns dynamically.
        Map<String, String> grandchildRelNames = new Map<String, String>();
        for (String childObjName : new List<String>(childRelNameByObject.keySet())) {
            String relName = childRelNameByObject.get(childObjName);
            if (relName.startsWith('__junction_')) continue; // Skip junctions
            SObjectType childType = Schema.getGlobalDescribe().get(childObjName);
            if (childType == null) continue;
            for (Schema.ChildRelationship gcr : childType.getDescribe().getChildRelationships()) {
                if (gcr.getRelationshipName() == null) continue;
                String gcObjName = gcr.getChildSObject().getDescribe().getName();
                // Skip if already tracked or if it's a system object
                if (childFieldMaps.containsKey(gcObjName)) continue;
                if (gcObjName.endsWith('History') || gcObjName.endsWith('Share') || gcObjName.endsWith('Feed')) continue;
                // Only add grandchildren that might have report columns
                // Check if the grandchild object has meaningful fields
                Map<String, SObjectField> gcfm = gcr.getChildSObject().getDescribe().fields.getMap();
                if (gcfm.size() < 3) continue; // Skip trivial objects
                childFieldMaps.put(gcObjName, gcfm);
                childRelNameByObject.put(gcObjName, gcr.getRelationshipName());
                Map<String, String> gclm = new Map<String, String>();
                Map<String, String> gcpm = new Map<String, String>();
                for (String fn : gcfm.keySet()) {
                    Schema.DescribeFieldResult gcdfr = gcfm.get(fn).getDescribe();
                    gclm.put(gcdfr.getLabel().toLowerCase(), gcdfr.getName());
                    gcpm.put(fn.toLowerCase(), gcdfr.getName());
                }
                childLabelMaps.put(gcObjName, gclm);
                childProperCaseMaps.put(gcObjName, gcpm);
            }
        }

        // Report column abbreviation prefixes → target object
        Map<String, String> reportPrefixToObject = new Map<String, String>{
            'QLI' => 'QuoteLineItem',
            'Q' => 'Quote',
            'OLI' => 'OpportunityLineItem',
            'CM' => 'CampaignMember'
        };

        Map<String, Map<String, String>> reportKeyOverrides = new Map<String, Map<String, String>>{
            'PRODUCT_NAME' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'Name' },
            'QUANTITY' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'Quantity' },
            'TOTAL_PRICE' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'TotalPrice' },
            'UNIT_PRICE' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'UnitPrice' },
            'QUOTE_LINEITEM_NAME' => new Map<String, String>{ 'object' => 'QuoteLineItem', 'field' => 'Name' },
            'PHONE1' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'Phone' },
            'PHONE2' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'HomePhone' },
            'PHONE3' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'MobilePhone' }
        };

        // Normalize report columns — route to base, parent, or child
        List<String> detailColumns = metadata.getDetailColumns();
        Map<String, Reports.DetailColumn> columnInfo = extMeta.getDetailColumnInfo();
        List<String> normalizedFields = new List<String>();
        List<String> parentFields = new List<String>();
        Map<String, List<String>> childFields = new Map<String, List<String>>();

        for (String colKey : detailColumns) {
            Reports.DetailColumn col = columnInfo.get(colKey);
            String colLabel = (col != null) ? col.getLabel() : null;
            Boolean mapped = false;

            // 0a. Dynamic label matching against ALL child objects
            // If the column label matches a field label on ANY known child object,
            // route it there. This works for any report type without hardcoding.
            if (!mapped && String.isNotBlank(colLabel) && !childFieldMaps.isEmpty()) {
                String labelLower = colLabel.toLowerCase();
                // Strip common label prefixes like "Quote Line Item: " or "Product: "
                String cleanLabel = labelLower;
                if (cleanLabel.contains(': ')) {
                    cleanLabel = cleanLabel.substringAfter(': ');
                }

                for (String childObjName : childLabelMaps.keySet()) {
                    Map<String, String> clm = childLabelMaps.get(childObjName);
                    String relName = childRelNameByObject.get(childObjName);
                    if (relName == null) continue;

                    // Try full label first, then cleaned label
                    String childFieldName = clm.get(labelLower);
                    if (childFieldName == null) childFieldName = clm.get(cleanLabel);

                    if (childFieldName != null) {
                        // Make sure it's NOT also a base object field (avoid stealing base fields)
                        if (!labelToApiName.containsKey(labelLower) || colKey.contains('.')) {
                            if (!childFields.containsKey(relName)) childFields.put(relName, new List<String>());
                            if (!childFields.get(relName).contains(childFieldName)) childFields.get(relName).add(childFieldName);
                            mapped = true;
                            break;
                        }
                    }
                }
            }

            // 0b. Check hardcoded overrides for remaining unmapped columns
            if (!mapped && reportKeyOverrides.containsKey(colKey)) {
                Map<String, String> override_info = reportKeyOverrides.get(colKey);
                String targetObj = override_info.get('object');
                String targetField = override_info.get('field');
                String relName = childRelNameByObject.get(targetObj);
                if (relName != null) {
                    if (!childFields.containsKey(relName)) childFields.put(relName, new List<String>());
                    if (!childFields.get(relName).contains(targetField)) childFields.get(relName).add(targetField);
                    mapped = true;
                }
            }

            // 1. Check parent prefix (USERS.NAME, ACCOUNT.NAME on non-Account base)
            if (!mapped && colKey.contains('.')) {
                String prefix = colKey.substringBefore('.').toUpperCase();
                String childField = colKey.substringAfter('.');
                Boolean isSelfPrefix = prefix.equalsIgnoreCase(baseObject) ||
                    prefix.equalsIgnoreCase(baseObject.removeEnd('__c')) ||
                    (baseObject == 'Opportunity' && prefix == 'OPPORTUNITY');
                if (isSelfPrefix) {
                    // Base object's own field — normalize the field part
                    String fieldName = normalizeReportColumn(childField, colLabel, fieldMap, labelToApiName, properCaseMap);
                    if (fieldName != null && !normalizedFields.contains(fieldName)) {
                        normalizedFields.add(fieldName);
                    }
                    mapped = true;
                } else if (parentPrefixMap.containsKey(prefix)) {
                    String relName = parentPrefixMap.get(prefix);
                    String parentFieldName = resolveParentFieldName(relName, childField, colLabel, fieldMap);
                    if (parentFieldName != null) {
                        String fullPath = relName + '.' + parentFieldName;
                        if (!parentFields.contains(fullPath)) parentFields.add(fullPath);
                        mapped = true;
                    }
                }
            }

            // 2. Check hardcoded owner mapping
            if (!mapped && colKey == 'OWNER_FULL_NAME') {
                if (!parentFields.contains('Owner.Name')) parentFields.add('Owner.Name');
                mapped = true;
            }

            // 3. Try to route to a child object by label matching
            if (!mapped && !childFieldMaps.isEmpty()) {
                for (String childObjName : childFieldMaps.keySet()) {
                    Map<String, String> clm = childLabelMaps.get(childObjName);
                    Map<String, String> cpm = childProperCaseMaps.get(childObjName);
                    Map<String, SObjectField> cfm = childFieldMaps.get(childObjName);
                    String relName = childRelNameByObject.get(childObjName);

                    // Try label match on child object
                    String childFieldName = null;
                    if (String.isNotBlank(colLabel) && clm.containsKey(colLabel.toLowerCase())) {
                        childFieldName = clm.get(colLabel.toLowerCase());
                    }
                    // Try direct key match
                    if (childFieldName == null) {
                        childFieldName = normalizeReportColumn(colKey, colLabel, cfm, clm, cpm);
                    }

                    if (childFieldName != null) {
                        if (!childFields.containsKey(relName)) childFields.put(relName, new List<String>());
                        if (!childFields.get(relName).contains(childFieldName)) {
                            childFields.get(relName).add(childFieldName);
                        }
                        mapped = true;
                        break;
                    }
                }
            }

            // 4. Fall through: try base object normalization
            if (!mapped) {
                String fieldName = normalizeReportColumn(colKey, colLabel, fieldMap, labelToApiName, properCaseMap);
                if (fieldName != null && !normalizedFields.contains(fieldName)) {
                    normalizedFields.add(fieldName);
                }
            }
        }

        // Convert report filters to a simple list
        List<Map<String, String>> filters = new List<Map<String, String>>();
        for (Reports.ReportFilter rf : metadata.getReportFilters()) {
            Reports.DetailColumn filterCol = columnInfo.get(rf.getColumn());
            String filterLabel = (filterCol != null) ? filterCol.getLabel() : null;
            String filterField = normalizeReportColumn(rf.getColumn(), filterLabel, fieldMap, labelToApiName, properCaseMap);
            if (filterField != null) {
                filters.add(new Map<String, String>{
                    'field' => filterField,
                    'operator' => mapReportOperator(rf.getOperator()),
                    'value' => rf.getValue()
                });
            }
        }

        // Capture standard date filter as a WHERE clause
        Reports.StandardDateFilter stdDateFilter = metadata.getStandardDateFilter();
        String whereClause = '';
        if (stdDateFilter != null) {
            String dateCol = stdDateFilter.getColumn();
            String dateField = normalizeReportColumn(dateCol, null, fieldMap, labelToApiName, properCaseMap);
            if (dateField == null) {
                // Common date column mappings
                Map<String, String> dateMap = new Map<String, String>{
                    'CREATED_DATE' => 'CreatedDate',
                    'CLOSE_DATE' => 'CloseDate',
                    'LAST_UPDATE' => 'LastModifiedDate'
                };
                dateField = dateMap.get(dateCol);
            }
            if (dateField != null) {
                String duration = stdDateFilter.getDurationValue();
                String startDate = stdDateFilter.getStartDate();
                String endDate = stdDateFilter.getEndDate();

                if (duration != null && duration != 'CUSTOM') {
                    // Relative date: THIS_MONTH, LAST_YEAR, etc.
                    whereClause = dateField + ' = ' + duration;
                } else {
                    if (String.isNotBlank(startDate) && String.isNotBlank(endDate)) {
                        whereClause = dateField + ' >= ' + startDate + ' AND ' + dateField + ' <= ' + endDate;
                    } else if (String.isNotBlank(startDate)) {
                        whereClause = dateField + ' >= ' + startDate;
                    } else if (String.isNotBlank(endDate)) {
                        whereClause = dateField + ' <= ' + endDate;
                    }
                }
            }
        }

        // Build WHERE string from custom filters too
        List<String> filterParts = new List<String>();
        if (String.isNotBlank(whereClause)) filterParts.add(whereClause);
        for (Map<String, String> f : filters) {
            String op = f.get('operator');
            String val = f.get('value');
            String fieldName = f.get('field');

            // Detect multi-value equals: "Value1,Value2,Value3" → convert to IN
            // But not formatted numbers like "2,000" (those start with " or are purely numeric)
            if ((op == '=' || op == '!=') && val.contains(',') && !val.startsWith('"')) {
                String stripped = val.replaceAll('[,\\d\\.\\s]', '');
                if (stripped.length() > 0) {
                    // Has non-numeric chars after stripping commas/digits → it's multi-value text
                    op = (op == '=') ? 'IN' : 'NOT IN';
                }
            }

            if (op == 'LIKE') {
                filterParts.add(fieldName + ' LIKE \'%' + String.escapeSingleQuotes(val) + '%\'');
            } else if (op == 'IN' || op == 'NOT IN') {
                // IN/NOT IN: value may be comma-separated list
                // Format: StageName IN ('Closed Won', 'Negotiation')
                List<String> vals = val.split(',');
                List<String> quotedVals = new List<String>();
                for (String v : vals) {
                    quotedVals.add('\'' + String.escapeSingleQuotes(v.trim()) + '\'');
                }
                filterParts.add(fieldName + ' ' + op + ' (' + String.join(quotedVals, ', ') + ')');
            } else {
                // Check if value is a SOQL date literal (no quotes needed)
                Set<String> dateLiterals = new Set<String>{
                    'TODAY', 'YESTERDAY', 'TOMORROW', 'LAST_WEEK', 'THIS_WEEK', 'NEXT_WEEK',
                    'LAST_MONTH', 'THIS_MONTH', 'NEXT_MONTH', 'LAST_QUARTER', 'THIS_QUARTER',
                    'NEXT_QUARTER', 'LAST_YEAR', 'THIS_YEAR', 'NEXT_YEAR', 'LAST_90_DAYS',
                    'NEXT_90_DAYS', 'LAST_N_DAYS', 'NEXT_N_DAYS'
                };
                String upperVal = val.toUpperCase().trim();
                Boolean isDateLiteral = dateLiterals.contains(upperVal) || upperVal.startsWith('LAST_N_') || upperVal.startsWith('NEXT_N_');
                Boolean isNumeric = val.trim().isNumeric() || Pattern.matches('-?\\d+\\.?\\d*', val.trim());
                Boolean isDateFormat = Pattern.matches('\\d{4}-\\d{2}-\\d{2}(T.*)?', val.trim());
                Boolean isBoolVal = upperVal == 'TRUE' || upperVal == 'FALSE' || upperVal == 'NULL';

                if (isDateLiteral || isNumeric || isDateFormat || isBoolVal) {
                    filterParts.add(fieldName + ' ' + op + ' ' + val.trim());
                } else {
                    filterParts.add(fieldName + ' ' + op + ' \'' + String.escapeSingleQuotes(val) + '\'');
                }
            }
        }
        String bulkWhereClause = String.join(filterParts, ' AND ');

        // Build child subqueries for the query config (skip junction-based children)
        List<String> childSubqueries = new List<String>();
        for (String relName : childFields.keySet()) {
            List<String> fields = childFields.get(relName);
            if (!fields.isEmpty() && !relName.startsWith('__junction_')) {
                childSubqueries.add('(SELECT ' + String.join(fields, ', ') + ' FROM ' + relName + ')');
            }
        }

        // Build junction info for the LWC
        List<Map<String, String>> junctionInfo = new List<Map<String, String>>();
        for (String relName : childFields.keySet()) {
            if (relName.startsWith('__junction_')) {
                // Parse: __junction_Contact or __junction_Contact:OpportunityContactRoles
                String remainder = relName.substring(11); // strip '__junction_'
                String targetObj;
                String junctionRel = '';
                if (remainder.contains(':')) {
                    targetObj = remainder.substringBefore(':');
                    junctionRel = remainder.substringAfter(':');
                } else {
                    targetObj = remainder;
                }
                junctionInfo.add(new Map<String, String>{
                    'targetObject' => targetObj,
                    'junctionRel' => junctionRel,
                    'fields' => String.join(childFields.get(relName), ',')
                });
            }
        }

        Integer totalChildFields = 0;
        for (String relKey : childFields.keySet()) {
            totalChildFields += childFields.get(relKey).size();
        }

        // Build hierarchy map: relationship name → parent object
        // So LWC knows QuoteLineItems belongs under Quote, not Opportunity
        Map<String, Map<String, String>> childHierarchy = new Map<String, Map<String, String>>();
        for (String childObjName : childRelNameByObject.keySet()) {
            String relName = childRelNameByObject.get(childObjName);
            if (relName.startsWith('__junction_')) continue;
            if (!childFields.containsKey(relName)) continue; // Only include objects with matched fields

            // Find which parent this child belongs to
            String parentObj = baseObject; // Default to base
            // Check if this is a grandchild by seeing if its parent is a child object
            SObjectType childSobjType = Schema.getGlobalDescribe().get(childObjName);
            if (childSobjType != null) {
                // Find the lookup field to determine parent
                for (Schema.SObjectField sof : childSobjType.getDescribe().fields.getMap().values()) {
                    Schema.DescribeFieldResult dfr = sof.getDescribe();
                    if (dfr.getType() == Schema.DisplayType.REFERENCE && dfr.getReferenceTo() != null) {
                        for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                            String refName = ref.getDescribe().getName();
                            // If the lookup points to another child object, it's a grandchild
                            if (childRelNameByObject.containsKey(refName) && refName != baseObject) {
                                parentObj = refName;
                                break;
                            }
                        }
                    }
                    if (parentObj != baseObject) break;
                }
            }

            childHierarchy.put(relName, new Map<String, String>{
                'objectName' => childObjName,
                'parentObject' => parentObj,
                'lookupField' => parentObj + 'Id'
            });
        }

        return new Map<String, Object>{
            'baseObject' => baseObject,
            'fields' => normalizedFields,
            'parentFields' => parentFields,
            'childSubqueries' => childSubqueries,
            'childFields' => childFields,
            'childHierarchy' => childHierarchy,
            'junctions' => junctionInfo,
            'filters' => filters,
            'bulkWhereClause' => bulkWhereClause,
            'reportName' => metadata.getName(),
            'fieldCount' => normalizedFields.size() + parentFields.size() + totalChildFields,
            'filterCount' => filters.size()
        };
    }

    /**
     * Resolves a field name on a parent object from a report column.
     * E.g., for Owner relationship with child field 'NAME', resolves to 'Name'.
     */
    private static String resolveParentFieldName(String relName, String childFieldKey,
            String columnLabel, Map<String, SObjectField> baseFieldMap) {
        // Find the lookup field to get the referenced object
        for (SObjectField sof : baseFieldMap.values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getRelationshipName() == relName && dfr.getReferenceTo() != null && !dfr.getReferenceTo().isEmpty()) {
                Map<String, SObjectField> parentFieldMap = dfr.getReferenceTo()[0].getDescribe().fields.getMap();

                // Try direct match
                if (parentFieldMap.containsKey(childFieldKey)) {
                    return parentFieldMap.get(childFieldKey).getDescribe().getName();
                }

                // Try label match on parent object
                if (String.isNotBlank(columnLabel)) {
                    // Strip parent context from label: "Account Owner" → might just be "Name" on User
                    for (String pKey : parentFieldMap.keySet()) {
                        Schema.DescribeFieldResult pDfr = parentFieldMap.get(pKey).getDescribe();
                        if (pDfr.getLabel().equalsIgnoreCase(columnLabel) ||
                            pDfr.getLabel().equalsIgnoreCase('Name') && childFieldKey.equalsIgnoreCase('NAME')) {
                            return pDfr.getName();
                        }
                    }
                }

                // Common: NAME → Name, EMAIL → Email
                for (String pKey : parentFieldMap.keySet()) {
                    if (pKey.equalsIgnoreCase(childFieldKey)) {
                        return parentFieldMap.get(pKey).getDescribe().getName();
                    }
                }
                break;
            }
        }
        return null;
    }

    /**
     * Resolves a report type name to a base object API name.
     * Handles standard patterns like 'AccountList', 'OpportunityList', 'Contact', etc.
     */
    /**
     * Resolves a report type to its base Salesforce object.
     * Uses multiple strategies — works for ANY report type, not just hardcoded ones.
     */
    private static String resolveReportBaseObject(String reportTypeName) {
        return resolveReportBaseObject(reportTypeName, null);
    }

    private static String resolveReportBaseObject(String reportTypeName, String reportTypeLabel) {
        if (String.isBlank(reportTypeName)) return null;
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        // Strategy 1: Direct match (report type name IS the object name)
        if (globalDescribe.containsKey(reportTypeName)) return reportTypeName;

        // Strategy 2: Strip 'List' suffix — AccountList → Account
        if (reportTypeName.endsWith('List')) {
            String stripped = reportTypeName.removeEnd('List');
            if (globalDescribe.containsKey(stripped)) return stripped;
        }

        // Strategy 3: Custom report types ending in __c — query the DeveloperName
        if (reportTypeName.endsWith('__c')) {
            // Custom report type — the first column's prefix is often the base object
            // This is handled in Strategy 6 below
        }

        // Strategy 4: Match the report type label against object labels
        // "Accounts" → Account, "Opportunities with Contact Roles and Products" → Opportunity
        if (String.isNotBlank(reportTypeLabel)) {
            String labelLower = reportTypeLabel.toLowerCase();
            for (String objName : globalDescribe.keySet()) {
                Schema.DescribeSObjectResult objDesc = globalDescribe.get(objName).getDescribe();
                if (!objDesc.isQueryable() || objDesc.isDeprecatedAndHidden()) continue;
                String objLabel = objDesc.getLabel().toLowerCase();
                String objLabelPlural = objDesc.getLabelPlural() != null ? objDesc.getLabelPlural().toLowerCase() : '';
                // "Accounts" starts with "Account" label plural
                if (String.isNotBlank(objLabelPlural) && labelLower.startsWith(objLabelPlural)) {
                    return objDesc.getName();
                }
                if (labelLower.startsWith(objLabel)) {
                    return objDesc.getName();
                }
            }
        }

        // Strategy 5: Match standard object names as prefix of the report type name
        // OpportunityLead → Opportunity, AccountCase → Account
        List<String> commonObjects = new List<String>{
            'Opportunity', 'Account', 'Contact', 'Lead', 'Case', 'Campaign',
            'Contract', 'Order', 'Task', 'Event', 'User', 'Solution', 'Product'
        };
        for (String objName : commonObjects) {
            if (reportTypeName.startsWith(objName) && globalDescribe.containsKey(objName)) {
                return objName;
            }
        }

        // Strategy 6: Custom report type with __c — try to resolve via name minus suffix
        if (reportTypeName.contains('__c')) {
            String basePart = reportTypeName.substringBefore('__c');
            // Remove common prefixes/suffixes from custom report type developer names
            for (String objName : commonObjects) {
                if (basePart.containsIgnoreCase(objName) && globalDescribe.containsKey(objName)) {
                    return objName;
                }
            }
        }

        return null;
    }

    /**
     * Normalizes a report column key to a SOQL field API name.
     *
     * Report columns use internal identifiers (ACCOUNT.NAME, ADDRESS1_STATE, DUE_DATE)
     * that don't match SOQL field API names. We use a multi-strategy approach:
     *   1. Direct API name match
     *   2. Label-based matching (report label → field label → API name)
     *   3. Hardcoded mappings for common report columns
     */
    private static String normalizeReportColumn(String columnKey, String columnLabel,
            Map<String, SObjectField> fieldMap, Map<String, String> labelToApiName,
            Map<String, String> properCaseMap) {
        if (String.isBlank(columnKey)) return null;

        // Skip owner/user columns (parent lookups, not direct fields)
        if (columnKey.startsWith('USERS.')) return null;

        // 1. Label-based matching — most reliable for standard fields
        // Report labels like "Billing State/Province" map precisely to field labels
        if (String.isNotBlank(columnLabel) && labelToApiName.containsKey(columnLabel.toLowerCase())) {
            return labelToApiName.get(columnLabel.toLowerCase());
        }

        // 2. Direct API name match (works for custom fields like MyField__c)
        if (fieldMap.containsKey(columnKey)) {
            return properCaseMap.get(columnKey.toLowerCase());
        }

        // Strip object prefix: ACCOUNT.NAME → NAME
        String fieldPart = columnKey;
        if (columnKey.contains('.')) {
            fieldPart = columnKey.substringAfter('.');
        }
        if (fieldMap.containsKey(fieldPart)) {
            return properCaseMap.get(fieldPart.toLowerCase());
        }

        // 3. Hardcoded mappings for report-specific column keys that don't match labels
        Map<String, String> reportKeyMappings = new Map<String, String>{
            'CREATED_DATE' => 'CreatedDate',
            'LAST_UPDATE' => 'LastModifiedDate',
            'DUE_DATE' => 'LastActivityDate',
            'CLOSE_DATE' => 'CloseDate',
            'AMOUNT' => 'Amount',
            'FULL_NAME' => 'Name',
            'FIRST_NAME' => 'FirstName',
            'LAST_NAME' => 'LastName',
            'STAGE_NAME' => 'StageName',
            'ADDRESS1_STREET' => 'BillingStreet',
            'ADDRESS1_CITY' => 'BillingCity',
            'ADDRESS1_STATE' => 'BillingState',
            'ADDRESS1_ZIP' => 'BillingPostalCode',
            'ADDRESS1_COUNTRY' => 'BillingCountry',
            'ADDRESS2_STREET' => 'ShippingStreet',
            'ADDRESS2_CITY' => 'ShippingCity',
            'ADDRESS2_STATE' => 'ShippingState',
            'ADDRESS2_ZIP' => 'ShippingPostalCode',
            'ADDRESS2_COUNTRY' => 'ShippingCountry',
            'ACCOUNT_ID' => 'AccountId',
            'CONTACT_ID' => 'ContactId'
        };

        String upperKey = fieldPart.toUpperCase();
        if (reportKeyMappings.containsKey(upperKey)) {
            String mapped = reportKeyMappings.get(upperKey);
            if (fieldMap.containsKey(mapped)) return mapped;
        }

        // 4. Try with __c suffix for custom fields
        if (!fieldPart.endsWithIgnoreCase('__c') && fieldMap.containsKey(fieldPart + '__c')) {
            return properCaseMap.get((fieldPart + '__c').toLowerCase());
        }

        System.debug(LoggingLevel.FINE, 'DocGen: Could not normalize report column: ' + columnKey + ' (label: ' + columnLabel + ')');
        return null;
    }

    /**
     * Maps report filter operators to SOQL operators.
     */
    private static String mapReportOperator(String reportOperator) {
        if (String.isBlank(reportOperator)) return '=';

        Map<String, String> operatorMap = new Map<String, String>{
            'equals' => '=',
            'notEqual' => '!=',
            'greaterThan' => '>',
            'lessThan' => '<',
            'greaterOrEqual' => '>=',
            'lessOrEqual' => '<=',
            'contains' => 'LIKE',
            'startsWith' => 'LIKE',
            'includes' => 'IN',
            'excludes' => 'NOT IN'
        };

        return operatorMap.containsKey(reportOperator) ? operatorMap.get(reportOperator) : '=';
    }
}