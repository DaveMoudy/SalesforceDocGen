public with sharing class DocGenSetupController {
    @AuraEnabled(cacheable=true)
    public static String getOrgUrl() {
        // Return the core my.salesforce.com URL, not the Lightning domain
        return Url.getOrgDomainUrl().toExternalForm();
    }

    @AuraEnabled(cacheable=true)
    public static DocGen_Settings__c getSettings() {
        return DocGen_Settings__c.getOrgDefaults();
    }

    @AuraEnabled
    public static void saveSettings(String experienceSiteUrl) {
        // Only allow users with Customize Application or DocGen_Admin permission set
        if (!FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()) {
            throw new AuraHandledException('Insufficient privileges to modify DocGen settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Experience_Site_Url__c = experienceSiteUrl;
        // Package-internal object — CRUD controlled by DocGen permission sets
        upsert settings;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Integer> getBuilderLimits() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        Integer maxParent = settings.Max_Parent_Fields__c != null
            ? (Integer) settings.Max_Parent_Fields__c : 10;
        Integer maxChild = settings.Max_Child_Lists__c != null
            ? (Integer) settings.Max_Child_Lists__c : 5;
        return new Map<String, Integer>{
            'maxParentFields' => maxParent,
            'maxChildLists' => maxChild
        };
    }

    @AuraEnabled
    public static void saveEmailBrandingSettings(String companyName, String logoUrl, String brandColor, String emailSubject, String emailMessage, String footerText) {
        if (!FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()) {
            throw new AuraHandledException('Insufficient privileges to modify DocGen settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Company_Name__c = companyName;
        settings.Signature_Email_Logo_Url__c = logoUrl;
        settings.Signature_Email_Brand_Color__c = brandColor;
        settings.Signature_Email_Subject__c = emailSubject;
        settings.Signature_Email_Message__c = emailMessage;
        settings.Signature_Email_Footer_Text__c = footerText;
        // Package-internal object — CRUD controlled by DocGen permission sets
        upsert settings;
    }

}