import { LightningElement, track, wire } from 'lwc';
import getAllTemplates from '@salesforce/apex/DocGenController.getAllTemplates';

export default class DocGenCommandHub extends LightningElement {
    @track templateCount = 0;
    @track showBanner = false;
    @track bannerDismissed = false;
    @track activeSection = 'templates';
    @track isLoaded = false;

    _wiredTemplates;

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

    get templateCountLabel() {
        if (this.templateCount === 0) return 'No templates yet';
        if (this.templateCount === 1) return '1 template ready';
        return this.templateCount + ' templates ready';
    }

    get bannerHeading() {
        return this.templateCount === 0 ? 'Welcome to DocGen' : 'DocGen';
    }

    get bannerSubtext() {
        return this.templateCount === 0
            ? "Let's create your first template. It takes about 3 minutes."
            : 'Upload a Word template with merge tags, generate PDFs or DOCX from any record.';
    }

    get isTemplates() { return this.activeSection === 'templates'; }
    get isBulk() { return this.activeSection === 'bulk'; }
    get isHelp() { return this.activeSection === 'help'; }
    get templatesTabClass() { return this.activeSection === 'templates' ? 'tab-active' : 'tab-inactive'; }
    get bulkTabClass() { return this.activeSection === 'bulk' ? 'tab-active' : 'tab-inactive'; }
    get helpTabClass() { return this.activeSection === 'help' ? 'tab-active' : 'tab-inactive'; }

    handleShowTemplates() { this.activeSection = 'templates'; }
    handleShowBulk() { this.activeSection = 'bulk'; }
    handleShowHelp() { this.activeSection = 'help'; }

    handleDismissBanner() { this.showBanner = false; this.bannerDismissed = true; }
    handleShowBanner() { this.showBanner = true; this.bannerDismissed = false; }

    handleCopyTag(event) {
        const TAG_MAP = {
            'loop-contacts': '{#Contacts}...{/Contacts}',
            'conditional-isactive': '{#IsActive}...{/IsActive}'
        };
        let tag = event.currentTarget.dataset.tag;
        tag = TAG_MAP[tag] || tag;
        if (navigator.clipboard) { navigator.clipboard.writeText(tag); }
    }
}
