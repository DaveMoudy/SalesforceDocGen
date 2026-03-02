public with sharing class DocGenBulkFlowAction {

    public class Request {
        @InvocableVariable(label='Template ID' required=true)
        public Id templateId;

        @InvocableVariable(label='Query Condition' description='Optional SOQL WHERE clause (e.g. Type = \'Customer\')')
        public String queryCondition;
    }

    public class Response {
        @InvocableVariable(label='Job ID')
        public Id jobId;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(label='Generate Bulk Documents' description='Starts a batch job to generate documents for multiple records based on a template and condition.')
    public static List<Response> generateBulkDocuments(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            try {
                // Leverage existing Bulk Controller logic
                Id jobId = DocGenBulkController.submitJob(req.templateId, req.queryCondition);
                res.jobId = jobId;
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                System.debug(LoggingLevel.ERROR, 'DocGen Bulk Flow Error: ' + e.getMessage());
            }
            responses.add(res);
        }
        
        return responses;
    }
}