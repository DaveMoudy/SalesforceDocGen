import { LightningElement, wire, track } from 'lwc';
import getPackages from '@salesforce/apex/PackageInstallTracker.getPackages';
import getSubscribers from '@salesforce/apex/PackageInstallTracker.getSubscribers';
import getStats from '@salesforce/apex/PackageInstallTracker.getStats';

const COLUMNS = [
    { label: 'Org Name', fieldName: 'orgName', sortable: true },
    { label: 'Org Type', fieldName: 'orgType', initialWidth: 120, sortable: true,
        cellAttributes: {
            class: { fieldName: 'orgTypeClass' }
        }
    },
    { label: 'Status', fieldName: 'installedStatus', initialWidth: 120, sortable: true,
        cellAttributes: {
            class: { fieldName: 'statusClass' }
        }
    },
    { label: 'Version ID', fieldName: 'versionId', initialWidth: 200 },
    { label: 'Installed', fieldName: 'installedDateFormatted', initialWidth: 180, sortable: true },
    { label: 'Org ID', fieldName: 'orgKey', initialWidth: 200 }
];

export default class PackageInstallTracker extends LightningElement {
    columns = COLUMNS;
    @track subscribers = [];
    @track packages = [];
    @track stats = {};
    selectedPackageId = '';
    isLoading = true;
    sortBy = 'installedDate';
    sortDirection = 'desc';

    @wire(getPackages)
    wiredPackages({ data, error }) {
        if (data) {
            this.packages = data.map(p => ({
                label: p.name + (p.namespacePrefix ? ' (' + p.namespacePrefix + ')' : ''),
                value: p.id
            }));
            if (this.packages.length > 0 && !this.selectedPackageId) {
                this.selectedPackageId = this.packages[0].value;
            }
        }
        if (error) {
            console.error('Error loading packages:', error);
        }
    }

    @wire(getSubscribers, { metadataPackageId: '$selectedPackageId' })
    wiredSubscribers({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.subscribers = data.map(s => ({
                ...s,
                installedDateFormatted: s.installedDate ? new Date(s.installedDate).toLocaleDateString('en-US', {
                    year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
                }) : '',
                orgTypeClass: s.orgType === 'Production' ? 'slds-text-color_success' : 'slds-text-color_weak',
                statusClass: s.installedStatus === 'Installed' ? 'slds-text-color_success' : 'slds-text-color_error'
            }));
        }
        if (error) {
            console.error('Error loading subscribers:', error);
            this.subscribers = [];
        }
    }

    @wire(getStats, { metadataPackageId: '$selectedPackageId' })
    wiredStats({ data, error }) {
        if (data) {
            this.stats = data;
        }
        if (error) {
            this.stats = {};
        }
    }

    get packageOptions() {
        return [{ label: 'All Packages', value: '' }, ...this.packages];
    }

    get totalInstalls() { return this.stats.total || 0; }
    get productionInstalls() { return this.stats.production || 0; }
    get sandboxInstalls() { return this.stats.sandbox || 0; }
    get activeInstalls() { return this.stats.installed || 0; }
    get uninstalled() { return this.stats.uninstalled || 0; }
    get hasSubscribers() { return this.subscribers.length > 0; }

    handlePackageChange(event) {
        this.isLoading = true;
        this.selectedPackageId = event.detail.value;
    }

    handleSort(event) {
        this.sortBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
        this.sortData();
    }

    sortData() {
        const data = [...this.subscribers];
        const key = this.sortBy;
        const dir = this.sortDirection === 'asc' ? 1 : -1;
        data.sort((a, b) => {
            const va = a[key] || '';
            const vb = b[key] || '';
            return va > vb ? dir : va < vb ? -dir : 0;
        });
        this.subscribers = data;
    }

    handleRefresh() {
        this.isLoading = true;
        // Force re-wire by toggling the package ID
        const current = this.selectedPackageId;
        this.selectedPackageId = null;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.selectedPackageId = current; }, 100);
    }
}
