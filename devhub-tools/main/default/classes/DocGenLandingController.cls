/**
 * Controller for the DocGen landing page.
 * Handles install links and help request form submissions.
 * Deploy to partner org only — runs on VF Site with guest user profile.
 */
public without sharing class DocGenLandingController {

    private static final String DEMO_USER_ID = '005di00000GkOuFAAV';
    private static final String DEMO_RET_URL = '/lightning/app/portwoodglobal__DocGen/page/portwoodglobal__DocGen_Command_Hub';

    private String packageVersionId;

    private String getPackageVersionId() {
        if (packageVersionId == null) {
            List<DocGen_Landing_Config__mdt> configs = [
                SELECT Package_Version_Id__c FROM DocGen_Landing_Config__mdt
                WHERE DeveloperName = 'Current' LIMIT 1
            ];
            packageVersionId = configs.isEmpty() ? '' : configs[0].Package_Version_Id__c;
        }
        return packageVersionId;
    }

    public String installLinkProd {
        get { return 'https://login.salesforce.com/packaging/installPackage.apexp?p0=' + getPackageVersionId(); }
    }
    public String installLinkSandbox {
        get { return 'https://test.salesforce.com/packaging/installPackage.apexp?p0=' + getPackageVersionId(); }
    }

    public String demoUrl {
        get {
            try {
                List<DocGen_Demo_Config__c> configs = [
                    SELECT Access_Token__c, Instance_Url__c
                    FROM DocGen_Demo_Config__c
                    WHERE SetupOwnerId = :UserInfo.getOrganizationId()
                    WITH SYSTEM_MODE LIMIT 1
                ];
                if (!configs.isEmpty() && String.isNotBlank(configs[0].Access_Token__c) && String.isNotBlank(configs[0].Instance_Url__c)) {
                    return configs[0].Instance_Url__c + '/secur/frontdoor.jsp?sid=' + configs[0].Access_Token__c
                        + '&retURL=' + EncodingUtil.urlEncode(DEMO_RET_URL, 'UTF-8');
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'demoUrl getter failed: ' + e.getMessage());
            }
            return null;
        }
    }

    public DocGenLandingController() {}

    @RemoteAction
    public static String submitHelpRequest(String name, String email, String company, String message) {
        if (String.isBlank(name) || String.isBlank(email)) {
            throw new AuraHandledException('Name and email are required.');
        }

        // Check for existing Lead with same email to avoid duplicates
        List<Lead> existing = [SELECT Id, Description FROM Lead WHERE Email = :email WITH SYSTEM_MODE LIMIT 1];
        if (!existing.isEmpty()) {
            Lead existingLead = existing[0];
            existingLead.Description = 'Follow-up request (' + Datetime.now().format() + '):\n' + message
                + (String.isNotBlank(existingLead.Description) ? '\n\n---\n' + existingLead.Description : '');
            update existingLead; // NOPMD ApexCRUDViolation — landing page: updating existing Lead with follow-up message
            return 'updated';
        }

        String firstName = '';
        String lastName = name;
        if (name.contains(' ')) {
            Integer spaceIdx = name.indexOf(' ');
            firstName = name.substring(0, spaceIdx);
            lastName = name.substring(spaceIdx + 1);
        }

        Lead newLead = new Lead(
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            Company = String.isNotBlank(company) ? company : '[Not Provided]',
            Description = message,
            LeadSource = 'DocGen Website',
            Status = 'New'
        );
        insert newLead; // NOPMD ApexCRUDViolation — landing page: creating Lead from help request form
        return 'created';
    }
}
