/**
 * Invocable action for generating a single document from a Flow.
 * Supports PDF, DOCX, PPTX, and XLSX output. Full merge tag support
 * including loops, conditionals, images, barcodes, and aggregates.
 */
global with sharing class DocGenFlowAction {

    global class Request {
        @InvocableVariable(label='Template ID' required=true description='The DocGen Template record ID')
        global Id templateId;

        @InvocableVariable(label='Record ID' required=true description='The source record ID to merge data from')
        global Id recordId;

        @InvocableVariable(label='Save to Record' description='If true, attach the generated file to the source record via ContentDocumentLink. Default: false')
        global Boolean saveToRecord;

        @InvocableVariable(label='Document Title' description='Override the generated file name. Leave blank to use the template default.')
        global String documentTitle;
    }

    global class Response {
        @InvocableVariable(label='Content Document ID')
        global Id contentDocumentId;

        @InvocableVariable(label='Content Version ID')
        global Id contentVersionId;

        @InvocableVariable(label='Error Message')
        global String errorMessage;

        @InvocableVariable(label='Success')
        global Boolean success;
    }

    @InvocableMethod(label='Generate Document' description='Generates a document (PDF, DOCX, PPTX, XLSX) from a DocGen template and record. Supports all merge tags including loops, images, barcodes, QR codes, and aggregates.')
    global static List<Response> generateDocument(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            try {
                Id docId = DocGenService.generateDocument(req.templateId, req.recordId);
                res.contentDocumentId = docId;
                res.success = true;

                // Get the ContentVersion ID for the generated file
                List<ContentVersion> cvs = [SELECT Id FROM ContentVersion WHERE ContentDocumentId = :docId WITH USER_MODE LIMIT 1];
                if (!cvs.isEmpty()) {
                    res.contentVersionId = cvs[0].Id;
                }

                // Optionally link to the source record (skip if already linked)
                if (req.saveToRecord == true && docId != null) {
                    List<ContentDocumentLink> existing = [
                        SELECT Id FROM ContentDocumentLink
                        WHERE ContentDocumentId = :docId AND LinkedEntityId = :req.recordId
                        WITH USER_MODE LIMIT 1
                    ];
                    if (existing.isEmpty()) {
                        ContentDocumentLink link = new ContentDocumentLink(
                            ContentDocumentId = docId,
                            LinkedEntityId = req.recordId,
                            ShareType = 'V',
                            Visibility = 'AllUsers'
                        );
                        SObjectAccessDecision decision = Security.stripInaccessible(AccessType.CREATABLE, new List<SObject>{ link });
                        insert decision.getRecords(); // NOPMD ApexCRUDViolation - FLS enforced via stripInaccessible
                    }
                }
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                res.success = false;
            }
            responses.add(res);
        }

        return responses;
    }
}