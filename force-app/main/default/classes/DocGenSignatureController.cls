public without sharing class DocGenSignatureController {

    // Signature links expire after this many days from creation
    private static final Integer TOKEN_EXPIRATION_DAYS = 30;

    public class SignatureInitResponse {
        @AuraEnabled public Boolean isValid;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String signerName;
        @AuraEnabled public String documentTitle;
        @AuraEnabled public String documentUrl;
        @AuraEnabled public String templateBase64;
        @AuraEnabled public String recordId;
        @AuraEnabled public String mergeDataJson;
        @AuraEnabled public String roleName;
        @AuraEnabled public Integer totalSigners;
        @AuraEnabled public Integer signedCount;
    }

    public class SaveSignatureResult {
        @AuraEnabled public Boolean isComplete;
        @AuraEnabled public Integer remaining;
    }

    /**
     * Validates a signer token. Queries DocGen_Signer__c first (multi-signer),
     * falls back to DocGen_Signature_Request__c (legacy single-signer).
     */
    @AuraEnabled
    @RemoteAction
    public static SignatureInitResponse validateToken(String token) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (String.isBlank(token)) {
            res.errorMessage = 'Invalid or missing security token.';
            return res;
        }

        // Token format validation: must be a 64-character hex string (SHA-256 output)
        if (token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            res.errorMessage = 'Invalid security token format.';
            return res;
        }

        // Try multi-signer path first
        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signer_Name__c, Role_Name__c, Sort_Order__c, CreatedDate,
                   Signature_Request__r.Id, Signature_Request__r.Status__c,
                   Signature_Request__r.Source_Document_Id__c, Signature_Request__r.Related_Record_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (!signers.isEmpty()) {
            // Token expiration: 30 days from creation
            if (signers[0].CreatedDate.addDays(TOKEN_EXPIRATION_DAYS) < System.now()) {
                res.errorMessage = 'This signature link has expired. Please request a new one.';
                return res;
            }
            return validateSignerToken(signers[0]);
        }

        // Legacy fallback: single-signer on DocGen_Signature_Request__c
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Source_Document_Id__c, Related_Record_Id__c, CreatedDate
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty()) {
            res.errorMessage = 'Signature request not found. The link may be invalid or expired.';
            return res;
        }

        // Token expiration: 30 days from creation
        if (requests[0].CreatedDate.addDays(TOKEN_EXPIRATION_DAYS) < System.now()) {
            res.errorMessage = 'This signature link has expired. Please request a new one.';
            return res;
        }

        return validateLegacyRequest(requests[0]);
    }

    private static SignatureInitResponse validateSignerToken(DocGen_Signer__c signer) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (signer.Status__c == 'Signed') {
            res.errorMessage = 'You have already signed this document.';
            return res;
        }

        DocGen_Signature_Request__c parentReq = signer.Signature_Request__r;
        if (parentReq.Status__c == 'Signed' || parentReq.Status__c == 'Cancelled') {
            res.errorMessage = 'This signature request is no longer active.';
            return res;
        }

        // Update signer status to Viewed (SYSTEM_MODE for guest user CRUD bypass)
        if (signer.Status__c == 'Pending') {
            signer.Status__c = 'Viewed';
            Database.update(signer, false, AccessLevel.SYSTEM_MODE);
        }

        res.isValid = true;
        res.signerName = signer.Signer_Name__c;
        res.roleName = signer.Role_Name__c;

        // Count total and signed signers
        List<DocGen_Signer__c> allSigners = [
            SELECT Status__c FROM DocGen_Signer__c
            WHERE Signature_Request__c = :parentReq.Id
            WITH SYSTEM_MODE
        ];
        res.totalSigners = allSigners.size();
        Integer signed = 0;
        for (DocGen_Signer__c s : allSigners) {
            if (s.Status__c == 'Signed') signed++;
        }
        res.signedCount = signed;

        // Get document metadata
        Id sourceDocId = parentReq.Source_Document_Id__c;
        List<ContentVersion> cvs = [SELECT Id, Title FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
        if (!cvs.isEmpty()) {
            res.documentTitle = cvs[0].Title;
            res.documentUrl = getOrCreatePublicLink(cvs[0]);
        } else {
            res.documentTitle = 'Confidential Document';
        }

        return res;
    }

    private static SignatureInitResponse validateLegacyRequest(DocGen_Signature_Request__c req) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (req.Status__c == 'Signed') {
            res.errorMessage = 'This document has already been signed.';
            return res;
        }
        if (req.Status__c == 'Cancelled') {
            res.errorMessage = 'This signature request has been cancelled.';
            return res;
        }

        if (req.Status__c == 'Sent') {
            req.Status__c = 'Viewed';
            Database.update(req, false, AccessLevel.SYSTEM_MODE);
        }

        res.isValid = true;
        res.signerName = req.Signer_Name__c;
        res.totalSigners = 1;
        res.signedCount = 0;

        List<ContentVersion> cvs = [SELECT Id, Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
        if (!cvs.isEmpty()) {
            res.documentTitle = cvs[0].Title;
            res.documentUrl = getOrCreatePublicLink(cvs[0]);
        } else {
            res.documentTitle = 'Confidential Document';
        }

        return res;
    }

    private static String getOrCreatePublicLink(ContentVersion cv) {
        List<ContentDistribution> dists = [
            SELECT DistributionPublicUrl
            FROM ContentDistribution
            WHERE ContentVersionId = :cv.Id
            WITH SYSTEM_MODE LIMIT 1
        ];
        if (!dists.isEmpty()) {
            return dists[0].DistributionPublicUrl;
        }
        ContentDistribution cd = new ContentDistribution();
        cd.Name = 'Signature Preview - ' + cv.Title;
        cd.ContentVersionId = cv.Id;
        cd.PreferencesAllowViewInBrowser = true;
        cd.PreferencesLinkLatestVersion = true;
        cd.PreferencesExpires = false;
        Database.insert(new List<ContentDistribution>{ cd }, false, AccessLevel.SYSTEM_MODE);
        cd = new ContentDistribution(Id = cd.Id);
        cd = [SELECT DistributionPublicUrl FROM ContentDistribution WHERE Id = :cd.Id WITH SYSTEM_MODE LIMIT 1];
        return cd.DistributionPublicUrl;
    }

    /**
     * Fetches pre-rendered HTML for document display in the signature page.
     * Converts the source DOCX to HTML server-side using DocGenHtmlRenderer.
     */
    @AuraEnabled
    @RemoteAction
    public static SignatureInitResponse fetchDocumentData(String token) {
        SignatureInitResponse res = validateToken(token);
        if (!res.isValid) return res;

        // Try multi-signer path
        List<DocGen_Signer__c> signers = [
            SELECT Signature_Request__r.Source_Document_Id__c, Signature_Request__r.Related_Record_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        Id sourceDocId;
        if (!signers.isEmpty()) {
            sourceDocId = signers[0].Signature_Request__r.Source_Document_Id__c;
            res.recordId = signers[0].Signature_Request__r.Related_Record_Id__c;
        } else {
            // Legacy fallback
            List<DocGen_Signature_Request__c> requests = [
                SELECT Source_Document_Id__c, Related_Record_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Secure_Token__c = :token
                WITH SYSTEM_MODE LIMIT 1
            ];
            if (!requests.isEmpty()) {
                sourceDocId = requests[0].Source_Document_Id__c;
                res.recordId = requests[0].Related_Record_Id__c;
            }
        }

        if (sourceDocId != null) {
            List<ContentVersion> cvs = [SELECT VersionData FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
            if (!cvs.isEmpty()) {
                // Convert DOCX to HTML for display
                res.templateBase64 = getDocumentHtml(cvs[0].VersionData);
            }
        }
        return res;
    }

    /**
     * Converts a DOCX blob to pre-rendered HTML by extracting and converting document.xml.
     * Returns the HTML string (stored in templateBase64 field for transport).
     */
    private static String getDocumentHtml(Blob docxBlob) {
        try {
            Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
            String documentXml = null;
            Map<String, String> images = new Map<String, String>();

            for (Compression.ZipEntry entry : reader.getEntries()) {
                String name = entry.getName();
                if (name == 'word/document.xml') {
                    documentXml = reader.extract(name).toString();
                } else if (name.startsWith('word/media/')) {
                    // Extract images and create relationship ID mapping
                    String fileName = name.substringAfter('word/media/');
                    Blob imgBlob = reader.extract(name);
                    images.put(fileName, EncodingUtil.base64Encode(imgBlob));
                }
            }

            if (documentXml != null) {
                return DocGenHtmlRenderer.convertToHtml(documentXml, images);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Error converting DOCX to HTML for signature display: ' + e.getMessage());
        }
        return '<html><body><p>Document preview unavailable.</p></body></html>';
    }

    /**
     * Saves a signer's signature PNG without generating the final PDF.
     * Returns whether all signers have now completed.
     */
    @AuraEnabled
    @RemoteAction
    public static SaveSignatureResult saveSignature(String token, String base64Image) {
        SaveSignatureResult result = new SaveSignatureResult();

        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signature_Request__c, CreatedDate
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (signer.CreatedDate.addDays(TOKEN_EXPIRATION_DAYS) < System.now()) {
            throw new AuraHandledException('This signature link has expired.');
        }
        if (signer.Status__c == 'Signed') {
            throw new AuraHandledException('You have already signed this document.');
        }

        // Store signature data and mark as signed (SYSTEM_MODE for guest user CRUD bypass)
        signer.Signature_Data__c = base64Image;
        signer.Status__c = 'Signed';
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Check if all signers are now complete
        List<DocGen_Signer__c> allSigners = [
            SELECT Status__c FROM DocGen_Signer__c
            WHERE Signature_Request__c = :signer.Signature_Request__c
            WITH SYSTEM_MODE
        ];

        Integer remaining = 0;
        for (DocGen_Signer__c s : allSigners) {
            if (s.Status__c != 'Signed') remaining++;
        }

        result.remaining = remaining;
        result.isComplete = (remaining == 0);

        // Update parent request status (SYSTEM_MODE for guest user CRUD bypass)
        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = 'In Progress';
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

        return result;
    }

    /**
     * Stamps ALL signatures into the DOCX, generates PDF server-side via Blob.toPdf(),
     * saves it, and returns the result. No client-side PDF rendering needed.
     * For multi-signer: called only when all signers have completed.
     * For legacy single-signer: stamps the single signature directly.
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, String> stampAndReturnSource(String token, String base64Image) {
        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        // Determine if this is a multi-signer or legacy request
        List<DocGen_Signer__c> signerList = [
            SELECT Id, Signature_Request__c,
                   Signature_Request__r.Source_Document_Id__c,
                   Signature_Request__r.Related_Record_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (!signerList.isEmpty()) {
            return stampMultiSignerAndSavePdf(signerList[0]);
        }

        // Legacy single-signer fallback
        return stampLegacySignerAndSavePdf(token, base64Image);
    }

    private static Map<String, String> stampMultiSignerAndSavePdf(DocGen_Signer__c triggerSigner) {
        Id requestId = triggerSigner.Signature_Request__c;
        Id sourceDocId = triggerSigner.Signature_Request__r.Source_Document_Id__c;
        String relatedRecordId = triggerSigner.Signature_Request__r.Related_Record_Id__c;

        try {
            List<DocGen_Signer__c> allSigners = [
                SELECT Role_Name__c, Signature_Data__c, Signer_Name__c, Signer_Email__c, Contact__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Sort_Order__c ASC
            ];

            List<DocGenSignatureService.SignerData> signerDataList = new List<DocGenSignatureService.SignerData>();
            for (DocGen_Signer__c s : allSigners) {
                signerDataList.add(new DocGenSignatureService.SignerData(s.Role_Name__c, s.Signature_Data__c));
            }

            Blob stampedBlob = DocGenSignatureService.stampAllSignaturesToBlob(sourceDocId, signerDataList);
            ContentVersion sourceDoc = [SELECT Title FROM ContentVersion WHERE Id = :sourceDocId WITH SYSTEM_MODE LIMIT 1];
            String fileName = sourceDoc.Title + ' - Signed';

            // Server-side PDF generation
            Blob pdfBlob = convertStampedDocxToPdf(stampedBlob);
            String base64Pdf = EncodingUtil.base64Encode(pdfBlob);

            // Save PDF to record
            DocGenController.saveGeneratedDocument(relatedRecordId, fileName, base64Pdf, 'pdf');

            // Create per-signer audit trail for compliance (eIDAS/ESIGN)
            String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
            List<DocGen_Signature_Audit__c> audits = new List<DocGen_Signature_Audit__c>();
            for (DocGen_Signer__c s : allSigners) {
                DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
                audit.Signature_Request__c = requestId;
                audit.Signer__c = s.Id;
                audit.Signer_Name__c = s.Signer_Name__c;
                audit.Signer_Email__c = s.Signer_Email__c;
                audit.Contact__c = s.Contact__c;
                audit.Signed_Date__c = System.now();
                audit.Document_Hash_SHA256__c = pdfHash;
                audit.IP_Address__c = 'Server-Side';
                audit.User_Agent__c = 'Blob.toPdf() - Server-Side PDF Generation';
                audits.add(audit);
            }
            Database.insert(audits, false, AccessLevel.SYSTEM_MODE);

            // Mark parent request as fully signed
            DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = requestId);
            parentReq.Status__c = 'Signed';
            Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

            // Clear signature data from signer records
            List<DocGen_Signer__c> toClean = new List<DocGen_Signer__c>();
            for (DocGen_Signer__c s : allSigners) {
                s.Signature_Data__c = null;
                toClean.add(s);
            }
            Database.update(toClean, false, AccessLevel.SYSTEM_MODE);

            return new Map<String, String>{
                'status' => 'complete',
                'title' => fileName
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Multi-signer stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing signatures.');
        }
    }

    private static Map<String, String> stampLegacySignerAndSavePdf(String token, String base64Image) {
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Signer_Email__c, Source_Document_Id__c, Related_Record_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            throw new AuraHandledException('Invalid request or document already signed.');
        }

        DocGen_Signature_Request__c req = requests[0];

        try {
            Blob stampedBlob = DocGenSignatureService.stampSignatureToBlob(req.Source_Document_Id__c, base64Image, req.Id);
            ContentVersion sourceDoc = [SELECT Title FROM ContentVersion WHERE Id = :req.Source_Document_Id__c WITH SYSTEM_MODE LIMIT 1];
            String fileName = sourceDoc.Title + ' - Signed';

            // Server-side PDF generation
            Blob pdfBlob = convertStampedDocxToPdf(stampedBlob);
            String base64Pdf = EncodingUtil.base64Encode(pdfBlob);

            // Save PDF to record
            DocGenController.saveGeneratedDocument(req.Related_Record_Id__c, fileName, base64Pdf, 'pdf');

            // Update request status (SYSTEM_MODE for guest user CRUD bypass)
            req.Status__c = 'Signed';
            Database.update(req, false, AccessLevel.SYSTEM_MODE);

            // Create audit trail
            String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
            DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
            audit.Signature_Request__c = req.Id;
            audit.Signer_Name__c = req.Signer_Name__c;
            audit.Signer_Email__c = req.Signer_Email__c;
            audit.Signed_Date__c = System.now();
            audit.Document_Hash_SHA256__c = pdfHash;
            audit.IP_Address__c = 'Server-Side';
            audit.User_Agent__c = 'Blob.toPdf() - Server-Side PDF Generation';
            Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

            return new Map<String, String>{
                'status' => 'complete',
                'title' => fileName
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Legacy stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing the signature.');
        }
    }

    /**
     * Converts a stamped DOCX blob to PDF using DocGenHtmlRenderer + Blob.toPdf().
     */
    private static Blob convertStampedDocxToPdf(Blob docxBlob) {
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        String documentXml = null;
        Map<String, String> images = new Map<String, String>();

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml') {
                documentXml = reader.extract(name).toString();
            } else if (name.startsWith('word/media/')) {
                String fileName = name.substringAfter('word/media/');
                images.put(fileName, EncodingUtil.base64Encode(reader.extract(name)));
            }
        }

        String html = DocGenHtmlRenderer.convertToHtml(documentXml, images);
        return Blob.toPdf(html);
    }

    /**
     * Kept for backward compatibility but now a no-op since PDF is generated server-side.
     * The VF page calls this after stamping — we just return success since the PDF
     * was already generated and saved in stampAndReturnSource.
     */
    @AuraEnabled
    @RemoteAction
    public static void finishSignatureUpload(String token, String base64Pdf, String fileName) {
        // PDF is now generated and saved server-side in stampAndReturnSource.
        // This method is retained as a no-op for backward compatibility with the VF page flow.
    }
}
