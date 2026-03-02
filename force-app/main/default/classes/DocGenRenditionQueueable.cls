public with sharing class DocGenRenditionQueueable implements Queueable, Database.AllowsCallouts {
    
    private Map<Id, Id> cvIdToRecordId;
    private Integer retryCount;
    
    public DocGenRenditionQueueable(Map<Id, Id> cvIdToRecordId) {
        this(cvIdToRecordId, 0);
    }
    
    public DocGenRenditionQueueable(Map<Id, Id> cvIdToRecordId, Integer retryCount) {
        this.cvIdToRecordId = cvIdToRecordId;
        this.retryCount = retryCount;
    }
    
    public void execute(QueueableContext context) {
        Map<Id, Id> failedCvs = new Map<Id, Id>();
        List<ContentVersion> pdfsToInsert = new List<ContentVersion>();
        Map<Integer, Id> indexToRecordId = new Map<Integer, Id>();
        List<Id> successSourceIds = new List<Id>();
        
        Integer index = 0;
        for (Id cvId : cvIdToRecordId.keySet()) {
            try {
                ContentVersion pdfCv = DocGenRenditionService.capturePdfRendition(cvId);
                if (pdfCv != null) {
                    pdfsToInsert.add(pdfCv);
                    indexToRecordId.put(index, cvIdToRecordId.get(cvId));
                    successSourceIds.add(cvId);
                    index++;
                    System.debug('DocGen: Rendition collected for CV: ' + cvId);
                }
            } catch (DocGenRenditionService.RenditionException e) {
                if (e.getMessage().contains('Rendition not ready')) {
                    failedCvs.put(cvId, cvIdToRecordId.get(cvId));
                } else {
                    DocGenRenditionService.logRenditionError(cvId, e.getMessage());
                    System.debug('DocGen: Rendition failure for ' + cvId + ': ' + e.getMessage());
                }
            } catch (Exception e) {
                DocGenRenditionService.logRenditionError(cvId, e.getMessage());
                System.debug('DocGen: Rendition unexpected error for ' + cvId + ': ' + e.getMessage());
            }
        }

        if (!pdfsToInsert.isEmpty()) {
            try {
                SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, pdfsToInsert);
                insert cvDecision.getRecords();
                pdfsToInsert = (List<ContentVersion>) cvDecision.getRecords();
                System.debug('DocGen: Inserted ' + pdfsToInsert.size() + ' PDFs.');
                
                // --- DIRECT LINKAGE ---
                List<ContentDocumentLink> cdlsToInsert = new List<ContentDocumentLink>();
                
                Set<Id> pdfCvIds = new Set<Id>();
                for(ContentVersion cv : pdfsToInsert) pdfCvIds.add(cv.Id);
                
                Map<Id, Id> cvIdToDocId = new Map<Id, Id>();
                for(ContentVersion cv : [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :pdfCvIds WITH SYSTEM_MODE]) {
                    cvIdToDocId.put(cv.Id, cv.ContentDocumentId);
                }

                for(Integer i=0; i < pdfsToInsert.size(); i++) {
                    Id recordId = indexToRecordId.get(i);
                    Id docId = cvIdToDocId.get(pdfsToInsert[i].Id);
                    
                    if (recordId != null && docId != null) {
                        cdlsToInsert.add(new ContentDocumentLink(
                            ContentDocumentId = docId,
                            LinkedEntityId = recordId,
                            ShareType = 'V',
                            Visibility = 'AllUsers'
                        ));
                    }
                }
                
                if (!cdlsToInsert.isEmpty()) {
                    SObjectAccessDecision cdlDecision = Security.stripInaccessible(AccessType.CREATABLE, cdlsToInsert);
                    Database.insert(cdlDecision.getRecords(), false);
                    System.debug('DocGen: Linked ' + cdlsToInsert.size() + ' PDFs to records.');
                }

                updateAuditHashes(successSourceIds, pdfsToInsert);

                // CLEANUP: Delete the source DOCX
                cleanupSourceFiles(successSourceIds);
                
            } catch (Exception e) {
                System.debug('DocGen: Finalization error: ' + e.getMessage());
                for(Id sid : successSourceIds) failedCvs.put(sid, cvIdToRecordId.get(sid));
            }
        }

        // Handle retries
        if (!failedCvs.isEmpty() && retryCount < 10) {
            if (!Test.isRunningTest()) {
                System.enqueueJob(new DocGenRenditionQueueable(failedCvs, retryCount + 1));
            }
        }
    }

    private void updateAuditHashes(List<Id> sourceCvIds, List<ContentVersion> pdfCvs) {
        Map<String, String> pdfHashByPendingCvId = new Map<String, String>();
        for (Integer i = 0; i < sourceCvIds.size(); i++) {
            String newPdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfCvs[i].VersionData));
            pdfHashByPendingCvId.put('PENDING_RENDITION:' + sourceCvIds[i], newPdfHash);
        }
        
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Id, Document_Hash_SHA256__c 
            FROM DocGen_Signature_Audit__c 
            WHERE Document_Hash_SHA256__c IN :pdfHashByPendingCvId.keySet() 
            WITH SYSTEM_MODE
        ];
        for (DocGen_Signature_Audit__c a : audits) {
            a.Document_Hash_SHA256__c = pdfHashByPendingCvId.get(a.Document_Hash_SHA256__c);
        }
        if (!audits.isEmpty()) update audits;
    }

    private void cleanupSourceFiles(List<Id> sourceCvIds) {
        try {
            List<ContentVersion> sources = [SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :sourceCvIds WITH SYSTEM_MODE];
            List<ContentDocument> docsToDelete = new List<ContentDocument>();
            for (ContentVersion cv : sources) docsToDelete.add(new ContentDocument(Id = cv.ContentDocumentId));
            if (!docsToDelete.isEmpty()) Database.delete(docsToDelete, false);
        } catch (Exception e) {
            System.debug('DocGen: Cleanup error: ' + e.getMessage());
        }
    }
}