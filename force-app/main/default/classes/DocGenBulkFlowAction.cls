/**
 * Invocable action for starting bulk document generation from a Flow.
 * Exposes the full bulk generation pipeline: filtering, batch size,
 * combined PDF, and individual file options.
 */
global with sharing class DocGenBulkFlowAction {

    global class Request {
        @InvocableVariable(label='Template ID' required=true description='The DocGen Template record ID')
        global Id templateId;

        @InvocableVariable(label='WHERE Condition' description='Optional SOQL WHERE clause to filter records (e.g. Industry = \'Technology\')')
        global String queryCondition;

        @InvocableVariable(label='Job Label' description='A friendly label for this job (shown in Job History)')
        global String jobLabel;

        @InvocableVariable(label='Combined PDF Only' description='Recommended. Produce one merged PDF with all records. Uses minimal heap. Default: true')
        global Boolean combinedPdfOnly;

        @InvocableVariable(label='Also Keep Individual Files' description='Generate a separate PDF per record in addition to the combined PDF. Uses more heap.')
        global Boolean keepIndividualFiles;

        @InvocableVariable(label='Batch Size' description='Records per batch transaction. Use 1 for complex templates, 10-50 for simple ones. Default: 1')
        global Integer batchSize;
    }

    global class Response {
        @InvocableVariable(label='Job ID')
        global Id jobId;

        @InvocableVariable(label='Error Message')
        global String errorMessage;

        @InvocableVariable(label='Success')
        global Boolean success;
    }

    @InvocableMethod(label='Generate Bulk Documents' description='Starts a batch job to generate documents for multiple records. Supports combined PDF, individual files, batch sizing, and WHERE filters.')
    global static List<Response> generateBulkDocuments(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            try {
                // Default: combined PDF only (most efficient)
                Boolean mergeOnly = (req.combinedPdfOnly != false && req.keepIndividualFiles != true);
                Boolean mergePdf = mergeOnly || (req.keepIndividualFiles == true);
                Integer batchSize = (req.batchSize != null && req.batchSize > 0) ? req.batchSize : 1;

                Id jobId = DocGenBulkController.submitJob(
                    req.templateId,
                    req.queryCondition,
                    req.jobLabel,
                    mergePdf,
                    batchSize,
                    mergeOnly
                );
                res.jobId = jobId;
                res.success = true;
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                res.success = false;
            }
            responses.add(res);
        }

        return responses;
    }
}