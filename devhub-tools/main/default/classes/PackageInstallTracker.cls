/**
 * Controller for the Package Install Tracker LWC.
 * Queries MetadataPackage and PackageSubscriber to show install data.
 * Deploy to DevHub org only — not part of the distributed package.
 */
public with sharing class PackageInstallTracker {

    @AuraEnabled(cacheable=true)
    public static List<PackageInfo> getPackages() {
        List<PackageInfo> packages = new List<PackageInfo>();
        for (MetadataPackage pkg : [SELECT Id, Name, NamespacePrefix FROM MetadataPackage ORDER BY Name]) {
            PackageInfo pi = new PackageInfo();
            pi.id = pkg.Id;
            pi.name = pkg.Name;
            pi.namespacePrefix = pkg.NamespacePrefix;
            packages.add(pi);
        }
        return packages;
    }

    @AuraEnabled(cacheable=true)
    public static List<SubscriberInfo> getSubscribers(String metadataPackageId) {
        List<SubscriberInfo> subs = new List<SubscriberInfo>();
        String query = 'SELECT Id, MetadataPackageId, MetadataPackageVersionId, OrgKey, OrgName, OrgType, InstalledStatus, SystemModstamp FROM PackageSubscriber';
        if (String.isNotBlank(metadataPackageId)) {
            query += ' WHERE MetadataPackageId = :metadataPackageId';
        }
        query += ' ORDER BY SystemModstamp DESC';

        for (PackageSubscriber sub : Database.query(query)) {
            SubscriberInfo si = new SubscriberInfo();
            si.id = sub.Id;
            si.orgKey = sub.OrgKey;
            si.orgName = sub.OrgName;
            si.orgType = sub.OrgType;
            si.installedStatus = sub.InstalledStatus == 'i' ? 'Installed' : sub.InstalledStatus == 'u' ? 'Uninstalled' : sub.InstalledStatus;
            si.versionId = sub.MetadataPackageVersionId;
            si.installedDate = sub.SystemModstamp;
            subs.add(si);
        }
        return subs;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getStats(String metadataPackageId) {
        Map<String, Object> stats = new Map<String, Object>();
        String query = 'SELECT Id, OrgType, InstalledStatus FROM PackageSubscriber';
        if (String.isNotBlank(metadataPackageId)) {
            query += ' WHERE MetadataPackageId = :metadataPackageId';
        }

        Integer total = 0;
        Integer production = 0;
        Integer sandbox = 0;
        Integer installed = 0;
        Integer uninstalled = 0;

        for (PackageSubscriber sub : Database.query(query)) {
            total++;
            if (sub.OrgType == 'Production') { production++; }
            else { sandbox++; }
            if (sub.InstalledStatus == 'i') { installed++; }
            else { uninstalled++; }
        }

        stats.put('total', total);
        stats.put('production', production);
        stats.put('sandbox', sandbox);
        stats.put('installed', installed);
        stats.put('uninstalled', uninstalled);
        return stats;
    }

    public class PackageInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String namespacePrefix;
    }

    public class SubscriberInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String orgKey;
        @AuraEnabled public String orgName;
        @AuraEnabled public String orgType;
        @AuraEnabled public String installedStatus;
        @AuraEnabled public String versionId;
        @AuraEnabled public Datetime installedDate;
    }
}
