public with sharing class DocGenRenditionService {
    
    public class RenditionException extends Exception {}

    private static Map<Id, Id> pendingRenditions = new Map<Id, Id>();

    /**
     * Adds a ContentVersion ID and its Related Record ID to the collection for later rendition capture.
     */
    public static void addPendingRendition(Id cvId, Id recordId) {
        pendingRenditions.put(cvId, recordId);
    }

    /**
     * Enqueues a background job for all collected renditions.
     */
    public static void enqueueRenditions() {
        enqueueRenditions(false);
    }

    /**
     * Enqueues a background job for all collected renditions.
     * If direct is true, bypasses the Platform Event bus and enqueues the Queueable directly.
     * This preserves the current user's authentication context.
     */
    public static void enqueueRenditions(Boolean direct) {
        if (pendingRenditions.isEmpty()) return;
        
        if (direct) {
            System.debug('DocGen: Directing renditions to Queueable (User Context: ' + UserInfo.getUserName() + ')');
            if (!Test.isRunningTest()) {
                System.enqueueJob(new DocGenRenditionQueueable(new Map<Id, Id>(pendingRenditions)));
            }
        } else {
            List<DocGen_Rendition_Event__e> events = new List<DocGen_Rendition_Event__e>();
            for (Id cvId : pendingRenditions.keySet()) {
                events.add(new DocGen_Rendition_Event__e(
                    Source_CV_Id__c = (String)cvId,
                    Related_Record_Id__c = (String)pendingRenditions.get(cvId)
                ));
            }
            if (!events.isEmpty()) {
                EventBus.publish(events);
            }
        }
        pendingRenditions.clear();
    }

    /**
     * Attempts to retrieve a PDF rendition for a given ContentVersion ID.
     * Returns a new (unsaved) ContentVersion record containing the PDF data.
     */
    public static ContentVersion capturePdfRendition(Id cvId) {
        ContentVersion cv = [SELECT ContentDocumentId, Title, PathOnClient FROM ContentVersion WHERE Id = :cvId WITH SYSTEM_MODE LIMIT 1];
        String fileId = cv.ContentDocumentId;
        
        // Use v63.0 for better compatibility
        String endpoint = 'callout:DocGen_Loopback/services/data/v63.0/connect/files/' + fileId + '/rendition?type=PDF';
        
        System.debug('DocGen: Requesting PDF rendition from ' + endpoint);
        
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        
        Http h = new Http();
        HttpResponse res = h.send(req);
        
        if (res.getStatusCode() == 200) {
            Blob pdfBlob = res.getBodyAsBlob();
            
            ContentVersion pdfCv = new ContentVersion();
            pdfCv.Title = cv.Title + ' (PDF)';
            pdfCv.PathOnClient = cv.Title + '.pdf';
            pdfCv.VersionData = pdfBlob;
            
            return pdfCv;
        } else if (res.getStatusCode() == 202 || res.getStatusCode() == 404 || res.getStatusCode() == 301 || res.getStatusCode() == 302) {
            throw new RenditionException('Rendition not ready yet (Status: ' + res.getStatusCode() + '). Retrying...');
        } else {
            throw new RenditionException('Failed to capture rendition: ' + res.getStatusCode() + ' ' + res.getStatus() + ' ' + res.getBody());
        }
    }

    /**
     * Logs an error message to the Signature Audit record associated with the source document.
     * This ensures visibility into "silent" background failures.
     */
    public static void logRenditionError(Id sourceCvId, String errorMessage) {
        try {
            List<DocGen_Signature_Audit__c> audits = [
                SELECT Id, Error_Message__c 
                FROM DocGen_Signature_Audit__c 
                WHERE Document_Hash_SHA256__c = :('PENDING_RENDITION:' + sourceCvId)
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            
            if (!audits.isEmpty()) {
                audits[0].Error_Message__c = '[' + System.now() + '] ' + errorMessage;
                update audits;
            } else {
                // Create a new audit record if one doesn't exist (e.g., Bulk Generation)
                DocGen_Signature_Audit__c newAudit = new DocGen_Signature_Audit__c(
                    Document_Hash_SHA256__c = 'PENDING_RENDITION:' + sourceCvId,
                    Error_Message__c = '[' + System.now() + '] ' + errorMessage
                );
                insert newAudit;
                System.debug('DocGen: Created new audit record for CV ' + sourceCvId + ' failure: ' + errorMessage);
            }
        } catch (Exception e) {
            System.debug('DocGen: Critical error logging rendition failure: ' + e.getMessage());
        }
    }
}