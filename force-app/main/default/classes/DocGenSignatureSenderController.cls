public with sharing class DocGenSignatureSenderController {

    public class SignerResult {
        @AuraEnabled public String signerName;
        @AuraEnabled public String roleName;
        @AuraEnabled public String signerUrl;
        @AuraEnabled public String signerEmail;
    }

    /**
     * Returns all active DocGen templates for the signature sender template picker.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getDocGenTemplates() {
        return [
            SELECT Id, Name
            FROM DocGen_Template__c
            WITH USER_MODE
            ORDER BY Name ASC
        ];
    }

    /**
     * Scans a DocGen template's pre-decomposed XML for {#Signature_XXX} placeholders.
     * No ZIP decompression needed — reads from stored XML ContentVersions.
     */
    @AuraEnabled
    public static List<String> getTemplateSignatureRoles(Id templateId) {
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = true
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (activeVersions.isEmpty()) return new List<String>();

        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
        List<ContentVersion> xmlCvs = [
            SELECT Title, VersionData FROM ContentVersion
            WHERE Title LIKE :(xmlPrefix + '%')
            WITH SYSTEM_MODE
        ];

        // Find the document.xml entry
        String documentXml = null;
        for (ContentVersion cv : xmlCvs) {
            String key = cv.Title.substring(xmlPrefix.length());
            String originalPath = key.replace('__', '/');
            if (originalPath == 'word/document.xml') {
                documentXml = cv.VersionData.toString();
                break;
            }
        }
        if (documentXml == null) return new List<String>();

        // Extract text from <w:t> elements
        String plainText = '';
        Pattern wtPat = Pattern.compile('<w:t[^>]*>([^<]*)</w:t>');
        Matcher wtMatch = wtPat.matcher(documentXml);
        while (wtMatch.find()) {
            plainText += wtMatch.group(1);
        }

        // Find {#Signature_RoleName} placeholders
        List<String> roles = new List<String>();
        Pattern sigPat = Pattern.compile('\\{#Signature_([^}]+)\\}');
        Matcher sigMatch = sigPat.matcher(plainText);
        while (sigMatch.find()) {
            String roleName = sigMatch.group(1).replaceAll('_', ' ');
            if (!roles.contains(roleName)) {
                roles.add(roleName);
            }
        }

        if (roles.isEmpty() && plainText.contains('{#Signature}')) {
            roles.add('Signer');
        }

        return roles;
    }

    /**
     * Creates a template-based multi-signer signature request.
     * No pre-generated DOCX needed — PDF is merged from template at signing time.
     */
    @AuraEnabled
    public static List<SignerResult> createTemplateSignerRequest(Id templateId, String relatedRecordId, String signersJson) {
        // Validate template exists
        List<DocGen_Template__c> templates = [SELECT Id, Name FROM DocGen_Template__c WHERE Id = :templateId WITH SYSTEM_MODE LIMIT 1];
        if (templates.isEmpty()) {
            throw new AuraHandledException('Template not found.');
        }

        // Parse signers JSON
        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // Create parent request with template reference (no Source_Document_Id__c)
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Template__c = templateId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        // Package-internal object — CRUD controlled by DocGen permission sets
        insert req;

        // Pre-compute everything while we have admin access.
        // Guest users can't query template data or ContentVersions (content sharing).
        // Store on the request record which the guest accesses via token + SYSTEM_MODE.
        try {
            Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, relatedRecordId);
            Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');

            // Build preview HTML with public URLs for images (not data URIs — keeps size small).
            // Create ContentDistributions for each template image so guest browser can load them.
            Map<String, String> previewImageMap = new Map<String, String>();
            for (String relId : pdfImageMap.keySet()) {
                String url = pdfImageMap.get(relId);
                if (url != null && url.contains('/version/download/')) {
                    String cvId = url.substringAfterLast('/');
                    try {
                        ContentDistribution dist = new ContentDistribution();
                        dist.Name = 'sig_preview_' + relId;
                        dist.ContentVersionId = cvId;
                        dist.PreferencesAllowViewInBrowser = true;
                        dist.PreferencesLinkLatestVersion = false;
                        dist.PreferencesExpires = false;
                        insert dist;
                        dist = [SELECT ContentDownloadUrl FROM ContentDistribution WHERE Id = :dist.Id];
                        previewImageMap.put(relId, dist.ContentDownloadUrl);
                    } catch (Exception e) {
                        System.debug(LoggingLevel.WARN, 'DocGen: Could not create public link for ' + relId + ': ' + e.getMessage());
                    }
                }
            }

            // Render preview HTML using public URLs (small, no base64 bloat)
            String docXml = (String) mergeData.get('documentXml');
            String previewHtml = DocGenHtmlRenderer.convertToHtml(docXml, previewImageMap);

            // Store image map (for Queueable) + preview HTML (for guest VF page)
            Map<String, Object> cachedData = new Map<String, Object>{
                'imageMap' => pdfImageMap,
                'previewHtml' => previewHtml
            };
            req.Signature_Data__c = JSON.serialize(cachedData);
            update req;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Failed to pre-compute signature data: ' + e.getMessage());
        }

        // Create individual signer records + send emails (shared logic)
        return createSignersAndNotify(req.Id, templateId, templates[0].Name, signerInputs);
    }

    @AuraEnabled(cacheable=true)
    public static List<ContentVersion> getRelatedDocuments(Id recordId) {
        List<ContentDocumentLink> links = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :recordId WITH USER_MODE];
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links) docIds.add(link.ContentDocumentId);

        return [
            SELECT Id, Title, FileExtension, ContentDocumentId
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = true
            AND FileExtension = 'docx'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Creates a multi-signer signature request with individual tokens per signer.
     * Legacy DOCX-based flow — requires a pre-generated DOCX on the record.
     * signersJson: [{roleName, contactId, signerName, signerEmail}, ...]
     */
    @AuraEnabled
    public static List<SignerResult> createMultiSignerRequest(Id contentDocumentId, String relatedRecordId, String signersJson) {
        // Resolve latest ContentVersionId
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        // Parse signers JSON
        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // Create parent request
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        // Package-internal object — CRUD controlled by DocGen permission sets
        insert req;

        String documentTitle = getDocumentTitle(contentVersionId);
        return createSignersAndNotify(req.Id, null, documentTitle, signerInputs);
    }

    /**
     * Legacy single-signer request creation (backward compat).
     */
    @AuraEnabled
    public static String createSignatureRequest(Id contentDocumentId, String relatedRecordId, String signerName, String signerEmail) {
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        Blob randomBytes = Crypto.generateAesKey(256);
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail));
        String token = EncodingUtil.convertToHex(hash);
        String signatureUrl = getSiteBaseUrl() + '/apex/DocGenSignature?token=' + token;

        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Signer_Name__c = signerName;
        req.Signer_Email__c = signerEmail;
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Secure_Token__c = token;
        req.Status__c = 'Sent';
        // Package-internal object — CRUD controlled by DocGen permission sets
        insert req;

        // Send branded signature request email automatically
        String documentTitle = getDocumentTitle(contentVersionId);
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{
                new DocGenSignatureEmailService.SignerEmail(signerName, signerEmail, null, signatureUrl, null)
            },
            documentTitle
        );

        return signatureUrl;
    }

    /**
     * Returns available signer role picklist values.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getSignerRolePicklistValues() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        Schema.DescribeFieldResult fieldResult = DocGen_Signer__c.Role_Name__c.getDescribe();
        for (Schema.PicklistEntry entry : fieldResult.getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new Map<String, String>{
                    'label' => entry.getLabel(),
                    'value' => entry.getValue()
                });
            }
        }
        return options;
    }

    /**
     * Returns all saved signature templates.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Signature_Template__c> getSignatureTemplates() {
        return [SELECT Id, Name, Description__c FROM DocGen_Signature_Template__c WITH SYSTEM_MODE ORDER BY Name ASC];
    }

    /**
     * Returns roles for a specific template.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Signature_Template_Role__c> getTemplateRoles(Id templateId) {
        return [
            SELECT Id, Role_Name__c, Sort_Order__c
            FROM DocGen_Signature_Template_Role__c
            WHERE Signature_Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];
    }

    /**
     * Saves a set of roles as a reusable template.
     * rolesJson: [{roleName: "Husband"}, {roleName: "Wife"}, ...]
     */
    @AuraEnabled
    public static Id saveSignatureTemplate(String templateName, String rolesJson) {
        DocGen_Signature_Template__c tmpl = new DocGen_Signature_Template__c();
        tmpl.Name = templateName;
        // Package-internal object — CRUD controlled by DocGen permission sets
        insert tmpl;

        List<Object> roleInputs = (List<Object>) JSON.deserializeUntyped(rolesJson);
        List<DocGen_Signature_Template_Role__c> roles = new List<DocGen_Signature_Template_Role__c>();

        for (Integer i = 0; i < roleInputs.size(); i++) {
            Map<String, Object> input = (Map<String, Object>) roleInputs[i];
            DocGen_Signature_Template_Role__c role = new DocGen_Signature_Template_Role__c();
            role.Signature_Template__c = tmpl.Id;
            role.Role_Name__c = (String) input.get('roleName');
            role.Sort_Order__c = i + 1;
            roles.add(role);
        }

        // Package-internal object — CRUD controlled by DocGen permission sets
        insert roles;
        return tmpl.Id;
    }

    /**
     * Returns Contact Name and Email for auto-filling signer fields.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getContactInfo(Id contactId) {
        List<Contact> contacts = [SELECT Name, Email FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1];
        Map<String, String> result = new Map<String, String>();
        if (!contacts.isEmpty()) {
            result.put('name', contacts[0].Name);
            result.put('email', contacts[0].Email != null ? contacts[0].Email : '');
        }
        return result;
    }

    /**
     * Returns existing signature requests for a record, with signer details and URLs.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getPendingSignatureRequests(String relatedRecordId) {
        String siteUrl = getSiteBaseUrl();
        List<Map<String, Object>> results = new List<Map<String, Object>>();

        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Name, Status__c, Source_Document_Id__c, CreatedDate,
                   (SELECT Id, Signer_Name__c, Signer_Email__c, Role_Name__c,
                           Status__c, Secure_Token__c, Sort_Order__c
                    FROM Signers__r ORDER BY Sort_Order__c ASC)
            FROM DocGen_Signature_Request__c
            WHERE Related_Record_Id__c = :relatedRecordId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];

        // Bulkify: collect all Source_Document_Id__c values and query titles in one SOQL
        Set<Id> sourceDocIds = new Set<Id>();
        for (DocGen_Signature_Request__c req : requests) {
            if (req.Source_Document_Id__c != null) {
                sourceDocIds.add(req.Source_Document_Id__c);
            }
        }
        Map<Id, String> docTitleMap = new Map<Id, String>();
        if (!sourceDocIds.isEmpty()) {
            for (ContentVersion cv : [SELECT Id, Title FROM ContentVersion WHERE Id IN :sourceDocIds WITH USER_MODE]) {
                docTitleMap.put(cv.Id, cv.Title);
            }
        }

        for (DocGen_Signature_Request__c req : requests) {
            Map<String, Object> reqMap = new Map<String, Object>();
            reqMap.put('id', req.Id);
            reqMap.put('name', req.Name);
            reqMap.put('status', req.Status__c);
            reqMap.put('createdDate', req.CreatedDate);

            // Get document title from pre-fetched map
            if (req.Source_Document_Id__c != null) {
                reqMap.put('documentTitle', docTitleMap.containsKey(req.Source_Document_Id__c) ? docTitleMap.get(req.Source_Document_Id__c) : 'Unknown');
            }

            List<Map<String, Object>> signerList = new List<Map<String, Object>>();
            for (DocGen_Signer__c signer : req.Signers__r) {
                Map<String, Object> signerMap = new Map<String, Object>();
                signerMap.put('signerName', signer.Signer_Name__c);
                signerMap.put('signerEmail', signer.Signer_Email__c);
                signerMap.put('roleName', signer.Role_Name__c);
                signerMap.put('status', signer.Status__c);
                signerMap.put('signerUrl', siteUrl + '/apex/DocGenSignature?token=' + signer.Secure_Token__c);
                signerList.add(signerMap);
            }
            reqMap.put('signers', signerList);
            results.add(reqMap);
        }

        return results;
    }

    /**
     * Scans a DOCX for {#Signature_XXX} placeholders and returns the role names.
     * Used by the LWC to auto-populate signer rows when a document is selected.
     */
    @AuraEnabled
    public static List<String> getDocumentSignatureRoles(Id contentDocumentId) {
        List<ContentDocument> docs = [SELECT LatestPublishedVersionId FROM ContentDocument WHERE Id = :contentDocumentId WITH SYSTEM_MODE LIMIT 1];
        if (docs.isEmpty()) return new List<String>();

        ContentVersion cv = [SELECT VersionData FROM ContentVersion WHERE Id = :docs[0].LatestPublishedVersionId WITH SYSTEM_MODE LIMIT 1];
        if (cv == null || cv.VersionData == null) return new List<String>();

        // Extract document.xml from the DOCX ZIP
        Compression.ZipReader reader = new Compression.ZipReader(cv.VersionData);
        String documentXml = null;
        for (Compression.ZipEntry entry : reader.getEntries()) {
            if (entry.getName() == 'word/document.xml') {
                documentXml = reader.extract(entry.getName()).toString();
                break;
            }
        }
        if (documentXml == null) return new List<String>();

        // Extract all text from <w:t> elements (handles tags split across runs)
        String plainText = '';
        Pattern wtPat = Pattern.compile('<w:t[^>]*>([^<]*)</w:t>');
        Matcher wtMatch = wtPat.matcher(documentXml);
        while (wtMatch.find()) {
            plainText += wtMatch.group(1);
        }

        // Find {#Signature_RoleName} placeholders
        List<String> roles = new List<String>();
        Pattern sigPat = Pattern.compile('\\{#Signature_([^}]+)\\}');
        Matcher sigMatch = sigPat.matcher(plainText);
        while (sigMatch.find()) {
            String roleName = sigMatch.group(1).replaceAll('_', ' ');
            if (!roles.contains(roleName)) {
                roles.add(roleName);
            }
        }

        // Check for generic {#Signature} (single signer, no named role)
        if (roles.isEmpty() && plainText.contains('{#Signature}')) {
            roles.add('Signer');
        }

        return roles;
    }

    /**
     * Shared logic: creates DocGen_Signer__c records and sends notification emails.
     * Used by both createMultiSignerRequest (DOCX) and createTemplateSignerRequest (template).
     */
    private static List<SignerResult> createSignersAndNotify(Id requestId, Id templateId, String documentTitle, List<Map<String, Object>> signerInputs) {
        String siteUrl = getSiteBaseUrl();
        List<DocGen_Signer__c> signerRecords = new List<DocGen_Signer__c>();
        List<SignerResult> results = new List<SignerResult>();

        for (Integer i = 0; i < signerInputs.size(); i++) {
            Map<String, Object> input = signerInputs[i];
            String signerName = (String) input.get('signerName');
            String signerEmail = (String) input.get('signerEmail');
            String roleName = (String) input.get('roleName');
            String contactId = (String) input.get('contactId');

            Blob randomBytes = Crypto.generateAesKey(256);
            Blob hash = Crypto.generateDigest('SHA-256',
                Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail + i)
            );
            String token = EncodingUtil.convertToHex(hash);

            DocGen_Signer__c signer = new DocGen_Signer__c();
            signer.Signature_Request__c = requestId;
            signer.Role_Name__c = roleName;
            signer.Signer_Name__c = signerName;
            signer.Signer_Email__c = signerEmail;
            signer.Secure_Token__c = token;
            signer.Status__c = 'Pending';
            signer.Sort_Order__c = i + 1;
            if (String.isNotBlank(contactId)) {
                signer.Contact__c = contactId;
            }
            signerRecords.add(signer);

            SignerResult sr = new SignerResult();
            sr.signerName = signerName;
            sr.roleName = roleName;
            sr.signerEmail = signerEmail;
            sr.signerUrl = siteUrl + '/apex/DocGenSignature?token=' + token;
            results.add(sr);
        }

        // Package-internal object — CRUD controlled by DocGen permission sets
        insert signerRecords;

        // Send branded signature request emails
        List<DocGenSignatureEmailService.SignerEmail> emailList = new List<DocGenSignatureEmailService.SignerEmail>();
        for (SignerResult sr : results) {
            Id cId = null;
            for (Map<String, Object> input : signerInputs) {
                if (sr.signerEmail == (String) input.get('signerEmail') && String.isNotBlank((String) input.get('contactId'))) {
                    cId = (Id) input.get('contactId');
                    break;
                }
            }
            emailList.add(new DocGenSignatureEmailService.SignerEmail(
                sr.signerName, sr.signerEmail, sr.roleName, sr.signerUrl, cId
            ));
        }
        DocGenSignatureEmailService.sendSignatureRequestEmails(emailList, documentTitle);

        return results;
    }

    private static String getDocumentTitle(Id contentVersionId) {
        List<ContentVersion> cvs = [SELECT Title FROM ContentVersion WHERE Id = :contentVersionId WITH USER_MODE LIMIT 1];
        return !cvs.isEmpty() ? cvs[0].Title : 'Document';
    }

    private static String getSiteBaseUrl() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String siteUrl = settings.Experience_Site_Url__c;

        if (String.isBlank(siteUrl)) {
            List<Site> sites = [SELECT Id FROM Site WHERE Status = 'Active' WITH SYSTEM_MODE LIMIT 1];
            if (!sites.isEmpty()) {
                SiteDetail sd = [SELECT SecureUrl FROM SiteDetail WHERE DurableId = :sites[0].Id WITH SYSTEM_MODE LIMIT 1];
                siteUrl = sd.SecureUrl;
            }
        }

        if (String.isBlank(siteUrl)) {
            siteUrl = 'https://<CONFIGURE_SITE_URL_IN_SETUP>';
        }

        if (siteUrl.endsWith('/')) {
            siteUrl = siteUrl.substring(0, siteUrl.length() - 1);
        }

        return siteUrl;
    }
}
