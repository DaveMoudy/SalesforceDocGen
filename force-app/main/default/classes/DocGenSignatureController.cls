public without sharing class DocGenSignatureController {

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

        // Try multi-signer path first
        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signer_Name__c, Role_Name__c, Sort_Order__c,
                   Signature_Request__r.Id, Signature_Request__r.Status__c,
                   Signature_Request__r.Source_Document_Id__c, Signature_Request__r.Related_Record_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (!signers.isEmpty()) {
            return validateSignerToken(signers[0]);
        }

        // Legacy fallback: single-signer on DocGen_Signature_Request__c
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Source_Document_Id__c, Related_Record_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty()) {
            res.errorMessage = 'Signature request not found. The link may be invalid.';
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

        // Update signer status to Viewed
        if (signer.Status__c == 'Pending') {
            signer.Status__c = 'Viewed';
            update signer;
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
            update req;
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
        SObjectAccessDecision cdDecision = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentDistribution>{ cd });
        insert cdDecision.getRecords();
        cd = new ContentDistribution(Id = cdDecision.getRecords()[0].Id);
        cd = [SELECT DistributionPublicUrl FROM ContentDistribution WHERE Id = :cd.Id WITH SYSTEM_MODE LIMIT 1];
        return cd.DistributionPublicUrl;
    }

    /**
     * Fetches the actual document content for client-side rendering.
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
                res.templateBase64 = EncodingUtil.base64Encode(cvs[0].VersionData);
            }
        }
        return res;
    }

    /**
     * Saves a signer's signature PNG without generating the final PDF.
     * Returns whether all signers have now completed.
     */
    @AuraEnabled
    @RemoteAction
    public static SaveSignatureResult saveSignature(String token, String base64Image) {
        SaveSignatureResult result = new SaveSignatureResult();

        List<DocGen_Signer__c> signers = [
            SELECT Id, Status__c, Signature_Request__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (signer.Status__c == 'Signed') {
            throw new AuraHandledException('You have already signed this document.');
        }

        // Store signature data and mark as signed
        signer.Signature_Data__c = base64Image;
        signer.Status__c = 'Signed';
        update signer;

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

        // Update parent request status
        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = 'In Progress';
        update parentReq;

        return result;
    }

    /**
     * Stamps ALL signatures into the DOCX and returns the base64 for client-side PDF rendering.
     * For multi-signer: called only when all signers have completed.
     * For legacy single-signer: stamps the single signature directly.
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, String> stampAndReturnSource(String token, String base64Image) {
        // Determine if this is a multi-signer or legacy request
        List<DocGen_Signer__c> signerList = [
            SELECT Id, Signature_Request__c, Signature_Request__r.Source_Document_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (!signerList.isEmpty()) {
            return stampMultiSigner(signerList[0]);
        }

        // Legacy single-signer fallback
        return stampLegacySigner(token, base64Image);
    }

    private static Map<String, String> stampMultiSigner(DocGen_Signer__c triggerSigner) {
        Id requestId = triggerSigner.Signature_Request__c;
        Id sourceDocId = triggerSigner.Signature_Request__r.Source_Document_Id__c;

        try {
            List<DocGen_Signer__c> allSigners = [
                SELECT Role_Name__c, Signature_Data__c, Signer_Name__c
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

            return new Map<String, String>{
                'base64' => EncodingUtil.base64Encode(stampedBlob),
                'title' => sourceDoc.Title + ' - Signed'
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing signatures.');
        }
    }

    private static Map<String, String> stampLegacySigner(String token, String base64Image) {
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Source_Document_Id__c, Related_Record_Id__c
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

            req.Status__c = 'Signed';
            update req;

            DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
            audit.Signature_Request__c = req.Id;
            audit.Signed_Date__c = System.now();
            audit.Document_Hash_SHA256__c = 'PENDING_CLIENT_PDF';
            audit.IP_Address__c = 'Captured via Client-Side Hybrid Flow';
            audit.User_Agent__c = 'Browser-Based Renderer';
            insert audit;

            return new Map<String, String>{
                'base64' => EncodingUtil.base64Encode(stampedBlob),
                'title' => sourceDoc.Title + ' - Signed'
            };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Legacy stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing the signature.');
        }
    }

    /**
     * Finalizes the signature by uploading the browser-generated PDF and updating the audit trail.
     */
    @AuraEnabled
    @RemoteAction
    public static void finishSignatureUpload(String token, String base64Pdf, String fileName) {
        // Try multi-signer path
        List<DocGen_Signer__c> signerList = [
            SELECT Id, Signature_Request__c,
                   Signature_Request__r.Id, Signature_Request__r.Related_Record_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (!signerList.isEmpty()) {
            finishMultiSignerUpload(signerList[0], base64Pdf, fileName);
            return;
        }

        // Legacy fallback
        finishLegacyUpload(token, base64Pdf, fileName);
    }

    private static void finishMultiSignerUpload(DocGen_Signer__c triggerSigner, String base64Pdf, String fileName) {
        Id requestId = triggerSigner.Signature_Request__c;
        String relatedRecordId = triggerSigner.Signature_Request__r.Related_Record_Id__c;

        try {
            DocGenController.saveGeneratedDocument(relatedRecordId, fileName, base64Pdf, 'pdf');

            String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', EncodingUtil.base64Decode(base64Pdf)));

            List<DocGen_Signer__c> allSigners = [
                SELECT Id, Signer_Name__c, Role_Name__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
            ];

            List<DocGen_Signature_Audit__c> audits = new List<DocGen_Signature_Audit__c>();
            for (DocGen_Signer__c s : allSigners) {
                DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
                audit.Signature_Request__c = requestId;
                audit.Signed_Date__c = System.now();
                audit.Document_Hash_SHA256__c = pdfHash;
                audit.IP_Address__c = s.Signer_Name__c + ' (' + (s.Role_Name__c != null ? s.Role_Name__c : 'Signer') + ')';
                audit.User_Agent__c = 'Multi-Signer Browser Renderer';
                audits.add(audit);
            }
            insert audits;

            // Mark parent request as fully signed
            DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = requestId);
            parentReq.Status__c = 'Signed';
            update parentReq;

            // Clear signature data from signer records
            List<DocGen_Signer__c> toClean = new List<DocGen_Signer__c>();
            for (DocGen_Signer__c s : allSigners) {
                s.Signature_Data__c = null;
                toClean.add(s);
            }
            update toClean;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Multi-signer finalization failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while finalizing the signed document.');
        }
    }

    private static void finishLegacyUpload(String token, String base64Pdf, String fileName) {
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Related_Record_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE LIMIT 1
        ];

        if (requests.isEmpty()) throw new AuraHandledException('Request not found.');
        DocGen_Signature_Request__c req = requests[0];

        try {
            DocGenController.saveGeneratedDocument(req.Related_Record_Id__c, fileName, base64Pdf, 'pdf');

            List<DocGen_Signature_Audit__c> audits = [
                SELECT Id FROM DocGen_Signature_Audit__c
                WHERE Signature_Request__c = :req.Id
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (!audits.isEmpty()) {
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', EncodingUtil.base64Decode(base64Pdf)));
                audits[0].Document_Hash_SHA256__c = pdfHash;
                update audits;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Legacy finalization failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while finalizing the signed document.');
        }
    }
}
