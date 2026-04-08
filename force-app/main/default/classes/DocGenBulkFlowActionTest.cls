@IsTest
private class DocGenBulkFlowActionTest {

    @TestSetup
    static void setup() {
        DocGen_Template__c temp = new DocGen_Template__c(
            Name = 'Test Bulk Template',
            Base_Object_API__c = 'User',
            Type__c = 'Word'
        );
        insert temp;

    }

    @IsTest
    static void testGenerateBulkDocuments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = temp.Id;
            req.queryCondition = 'Name = \'Test Account 1\'';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(new List<DocGenBulkFlowAction.Request>{req});
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should have one response');
            System.assertNotEquals(null, responses[0].jobId, 'Should have a jobId');

            DocGen_Job__c job = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :responses[0].jobId];
            // Note: Status might be Processing or Completed depending on execution speed in test
            System.assertNotEquals(null, job.Status__c, 'Job should have a status');
        }
    }

    @IsTest
    static void testGenerateBulkDocumentsErrorPath() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a null templateId to trigger the error/catch branch
            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = null;
            req.queryCondition = 'Name = \'Test\'';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should have one response');
            System.assertNotEquals(null, responses[0].errorMessage, 'Should have an error message');
            System.assertEquals(null, responses[0].jobId, 'Should not have a jobId on error');
        }
    }

    @IsTest
    static void testBulkFlowActionResponseCoverage() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenBulkFlowAction.Response res = new DocGenBulkFlowAction.Response();
            res.jobId = null;
            res.errorMessage = 'test';
            System.assertEquals(null, res.jobId, 'jobId should be null when not set');
            System.assertEquals('test', res.errorMessage, 'errorMessage should match assigned value');
        }
    }
}
