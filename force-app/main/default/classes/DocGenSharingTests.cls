@IsTest
private class DocGenSharingTests {
	private static String UNIQUE_IDENTIFIER = 'DocGenSharingTests';
	private static final String TEST_GROUP_NAME = String.format('DocGenShareGroup_{0}', new List<String>{UserInfo.getUserId()});
    @TestSetup
    static void setup() {
        DocGen_Template__c templateRecord = new DocGen_Template__c(
            Name = 'Sharing Template',
            Base_Object_API__c = 'User'
        );
        insert templateRecord;

		// avoid mixed dml
		System.runAs(new User(Id = UserInfo.getUserId())) {
			Group shareGroup = new Group(
				Name = TEST_GROUP_NAME,
				DeveloperName = String.format('DocGenShareGroup_{0}', new List<String>{String.valueOf(DateTime.now().getTime())}),
				Type = 'Regular'
			);
			insert shareGroup;

			GroupMember groupMembership = new GroupMember(
				GroupId = shareGroup.Id,
				UserOrGroupId = UserInfo.getUserId()
			);
			insert groupMembership;
		}
    }

    @IsTest
    static void testSharingOperations() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            DocGen_Template__c templateRecord = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Group shareGroup = [SELECT Id FROM Group WHERE Name = :TEST_GROUP_NAME LIMIT 1];

            Test.startTest();

            // Share
            DocGenController.shareTemplate(templateRecord.Id, shareGroup.Id, 'Read');

            // Verify Share exists via actual SOQL to guarantee valid ID type
            DocGen_Template__Share shareRef = [SELECT Id FROM DocGen_Template__Share WHERE ParentId = :templateRecord.Id AND UserOrGroupId = :shareGroup.Id LIMIT 1];
            System.assertNotEquals(null, shareRef, 'Share record should exist in DB');

            // Remove Share
            DocGenController.removeShare(shareRef.Id);

            List<Map<String, String>> shares = DocGenController.getTemplateShares(templateRecord.Id);
            Boolean found = false;
            for (Map<String, String> shareRecord : shares) {
                if (shareRecord.get('UserOrGroupId') == shareGroup.Id) {
					found = true; break;
				}
            }
            System.assert(!found, 'Share should be removed');

            Test.stopTest();
        }
    }

    @IsTest
    static void testSearch() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            List<Map<String, String>> results = DocGenController.searchUsersAndGroups(UserInfo.getLastName());
            Test.stopTest();
            System.assert(results.size() > 0, 'Should find user');
        }
    }
}