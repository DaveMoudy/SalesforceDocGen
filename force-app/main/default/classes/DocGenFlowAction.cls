public with sharing class DocGenFlowAction {

    public class Request {
        @InvocableVariable(label='Template ID' required=true)
        public Id templateId;

        @InvocableVariable(label='Base Record ID' required=true)
        public Id recordId;
    }

    public class Response {
        @InvocableVariable(label='Content Document ID')
        public Id contentDocumentId;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Generate Document (Native)' description='Generates a DOCX/PPTX document using the DocGen package. Note: Does not support complex loops or conditional logic in this version.')
    public static List<Response> generateDocument(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            try {
                // Call Service
                Id docId = DocGenService.generateDocument(req.templateId, req.recordId);
                res.contentDocumentId = docId;
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                System.debug(LoggingLevel.ERROR, 'DocGen Flow Error: ' + e.getMessage());
            }
            responses.add(res);
        }

        return responses;
    }
}