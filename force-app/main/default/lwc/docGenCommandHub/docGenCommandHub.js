import { LightningElement, track, wire } from 'lwc';
import getAllTemplates from '@salesforce/apex/DocGenController.getAllTemplates';
import getOrgId from '@salesforce/apex/DocGenController.getOrgId';

export default class DocGenCommandHub extends LightningElement {
    @track templateCount = 0;
    communityOrgId = '';
    @track showBanner = false;
    @track bannerDismissed = false;
    @track activeSection = 'templates';
    @track isLoaded = false;

    _wiredTemplates;

    @wire(getOrgId)
    wiredOrgId({ data }) {
        if (data) { this.communityOrgId = data; }
    }

    get communityUrl() {
        return 'https://portwoodglobalsolutions.com/DocGenCommunity?view=signup&orgId=' + this.communityOrgId;
    }

    @wire(getAllTemplates)
    wiredTemplates(result) {
        this._wiredTemplates = result;
        if (result.data) {
            this.templateCount = result.data.length;
            if (!this.bannerDismissed && this.templateCount < 10) {
                this.showBanner = true;
            }
            this.isLoaded = true;
        } else if (result.error) {
            this.isLoaded = true;
        }
    }

    get bannerHeading() {
        return this.templateCount === 0 ? 'Welcome to DocGen' : 'DocGen';
    }

    get bannerSubtext() {
        return this.templateCount === 0
            ? "Let's create your first template. It takes about 3 minutes."
            : 'Generate PDFs, Word docs, Excel spreadsheets, and PowerPoint from any record.';
    }

    get isTemplates() { return this.activeSection === 'templates'; }
    get isBulk() { return this.activeSection === 'bulk'; }
    get isHelp() { return this.activeSection === 'help'; }
    get templatesTabClass() { return this.activeSection === 'templates' ? 'tab-active' : ''; }
    get bulkTabClass() { return this.activeSection === 'bulk' ? 'tab-active' : ''; }
    get helpTabClass() { return this.activeSection === 'help' ? 'tab-active' : ''; }

    handleShowTemplates() { this.activeSection = 'templates'; }
    handleShowBulk() { this.activeSection = 'bulk'; }
    handleShowHelp() { this.activeSection = 'help'; }

    handleDismissBanner() { this.showBanner = false; this.bannerDismissed = true; }

    handleCopyTag(event) {
        let tag = event.currentTarget.dataset.tag;
        if (tag === 'loop-contacts') tag = '{#Contacts}...{/Contacts}';
        if (navigator.clipboard) { navigator.clipboard.writeText(tag); }
    }
}
