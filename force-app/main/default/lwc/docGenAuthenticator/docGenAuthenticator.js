import { LightningElement, track } from 'lwc';
import verifyDocument from '@salesforce/apex/DocGenAuthenticatorController.verifyDocument';

export default class DocGenAuthenticator extends LightningElement {
    @track isProcessing = false;
    @track result;

    get resultContainerClass() {
        if (!this.result) return '';
        return this.result.isValid 
            ? 'slds-box slds-theme_success slds-var-m-top_medium'
            : 'slds-box slds-theme_error slds-var-m-top_medium';
    }

    get resultIcon() {
        return this.result && this.result.isValid ? 'utility:success' : 'utility:error';
    }

    handleDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'copy';
    }

    handleDrop(event) {
        event.preventDefault();
        if (event.dataTransfer.files && event.dataTransfer.files.length > 0) {
            this.processFile(event.dataTransfer.files[0]);
        }
    }

    handleFileSelect(event) {
        if (event.target.files && event.target.files.length > 0) {
            this.processFile(event.target.files[0]);
        }
    }

    async processFile(file) {
        this.result = undefined;
        this.isProcessing = true;

        try {
            // 1. Read file as ArrayBuffer
            const arrayBuffer = await file.arrayBuffer();

            // 2. Compute SHA-256 hash using native browser crypto API
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            
            // 3. Convert buffer to hex string
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            // 4. Send hash to Salesforce for verification
            this.result = await verifyDocument({ fileHash: hashHex });

        } catch (error) {
            this.result = {
                isValid: false,
                message: 'Error processing file: ' + (error.body ? error.body.message : error.message)
            };
        } finally {
            this.isProcessing = false;
        }
    }
}