/**
 * Controller for the DocGen landing page.
 * Manages demo org session for "Try Demo" functionality.
 * Deploy to partner org only.
 */
public without sharing class DocGenLandingController {

    // Store demo session in a custom setting or org-wide default
    // For now, use a static approach — refresh via CLI
    private static final String INSTALL_LINK_PROD = 'https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006PClhAAG';
    private static final String INSTALL_LINK_SANDBOX = 'https://test.salesforce.com/packaging/installPackage.apexp?p0=04tal000006PClhAAG';

    public String installLinkProd { get { return INSTALL_LINK_PROD; } }
    public String installLinkSandbox { get { return INSTALL_LINK_SANDBOX; } }
    public String demoUrl { get; set; }
    public String lastRefreshed { get; set; }

    public DocGenLandingController() {
        DocGen_Demo_Config__c config = DocGen_Demo_Config__c.getOrgDefaults();
        if (config != null && String.isNotBlank(config.Access_Token__c) && String.isNotBlank(config.Instance_Url__c)) {
            demoUrl = config.Instance_Url__c.trim() + '/secur/frontdoor.jsp?sid=' + config.Access_Token__c.trim() + '&retURL=%2Flightning%2Fn%2Fportwoodglobal__DocGen_Command_Hub';
            lastRefreshed = config.Last_Refreshed__c != null
                ? config.Last_Refreshed__c.format('MMM dd, yyyy h:mm a')
                : '';
        }
    }

    public Boolean getHasDemoUrl() {
        return String.isNotBlank(demoUrl);
    }
}
