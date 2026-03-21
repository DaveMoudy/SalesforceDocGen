/**
 * Platform Event trigger for signature PDF generation.
 * Runs as Automated Process user (system context), bypassing guest user
 * limitations on ContentVersion access. Published by the guest user VF page
 * after all signatures are collected.
 */
trigger DocGenSignaturePdfTrigger on DocGen_Signature_PDF__e (after insert) {
    Set<Id> requestIds = new Set<Id>();
    for (DocGen_Signature_PDF__e evt : Trigger.New) {
        requestIds.add(evt.Request_Id__c);
    }

    // Query requests to determine which pipeline to use
    Map<Id, DocGen_Signature_Request__c> requestMap = new Map<Id, DocGen_Signature_Request__c>([
        SELECT Id, Template__c FROM DocGen_Signature_Request__c
        WHERE Id IN :requestIds WITH SYSTEM_MODE
    ]);

    for (DocGen_Signature_PDF__e evt : Trigger.New) {
        try {
            Id requestId = evt.Request_Id__c;
            DocGen_Signature_Request__c req = requestMap.get(requestId);

            if (req != null && req.Template__c != null) {
                // Template-based: single-stage, no DOCX intermediate
                System.enqueueJob(new DocGenSignatureService.TemplateSignaturePdfQueueable(requestId));
            } else {
                // Legacy: two-stage DOCX-based pipeline
                System.enqueueJob(new DocGenSignatureService.SignaturePdfQueueable(requestId));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Signature PDF event trigger error: ' + e.getMessage());
        }
    }
}
