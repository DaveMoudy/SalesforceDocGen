@isTest
private class DocGenBulkFlowActionTest {
    
    @testSetup
    static void setup() {
        // Assign DocGen_Admin permission set for custom object/field access in 2GP context
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Admin' LIMIT 1];
        insert new PermissionSetAssignment(
            AssigneeId = UserInfo.getUserId(),
            PermissionSetId = ps.Id
        );

        DocGen_Template__c temp = new DocGen_Template__c(
            Name = 'Test Bulk Template',
            Base_Object_API__c = 'Account',
            Type__c = 'Word'
        );
        insert temp;

        insert new Account(Name = 'Test Account 1', Website = 'https://test1.com');
        insert new Account(Name = 'Test Account 2', Website = 'https://test2.com');
    }

    @isTest
    static void testGenerateBulkDocuments() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        
        DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
        req.templateId = temp.Id;
        req.queryCondition = 'Name LIKE \'Test Account%\'';
        
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
