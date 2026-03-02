import { LightningElement, api, wire, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObject';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import FILESAVER_JS from '@salesforce/resourceUrl/filesaver';

export default class DocGenRunner extends LightningElement {
    @api recordId;
    @api objectApiName;

    @track templateOptions = [];
    @track selectedTemplateId;
    @track outputMode = 'download';
    @track templateOutputFormat = 'Document';

    isLoading = false;
    error;
    librariesLoaded = false;
    _librariesPromise;
    _templateData = [];

    get engineUrl() {
        return '/apex/DocGenPDFEngine';
    }

    get outputOptions() {
        const formatLabel = this.templateOutputFormat || 'Document';
        return [
            { label: `Download ${formatLabel}`, value: 'download' },
            { label: `Save to Record (${formatLabel})`, value: 'save' }
        ];
    }

    @wire(getTemplatesForObject, { objectApiName: '$objectApiName' })
    wiredTemplates({ error, data }) {
        if (data) {
            this._templateData = data;
            this.templateOptions = data.map(t => ({ label: t.Name, value: t.Id }));
            this.error = undefined;
        } else if (error) {
            this.error = 'Error fetching templates: ' + (error.body ? error.body.message : error.message);
            this.templateOptions = [];
        }
    }

    renderedCallback() {
        if (this.librariesLoaded) return;
        this.librariesLoaded = true;
        this._librariesPromise = loadScript(this, FILESAVER_JS);
    }

    handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
        this.error = null;
        const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
        if (selected) {
            this.templateOutputFormat = selected.Output_Format__c || 'Document';
        }
    }

    handleOutputModeChange(event) {
        this.outputMode = event.detail.value;
    }

    get isGenerateDisabled() {
        return !this.selectedTemplateId || this.isLoading;
    }

    async generateDocument() {
        this.isLoading = true;
        this.error = null;

        try {
            if (this._librariesPromise) {
                await this._librariesPromise;
            }

            // Server-side document processing
            const result = await processAndReturnDocument({
                templateId: this.selectedTemplateId,
                recordId: this.recordId
            });

            if (!result || !result.base64) {
                throw new Error('Document generation returned empty result.');
            }

            const base64Data = result.base64;
            const docTitle = result.title || 'Document';
            const templateType = result.templateType;
            this.templateOutputFormat = result.outputFormat || 'Document';

            const isPPT = templateType === 'PowerPoint';
            const isPDF = this.templateOutputFormat === 'PDF' && !isPPT;
            const ext = isPPT ? 'pptx' : 'docx';

            if (isPDF) {
                // Send processed DOCX to PDF Engine iframe
                // VF pages run on a different domain (*.visualforce.com) — origin validated on receive side
                this.showToast('Info', 'Generating PDF...', 'info');
                const binaryString = atob(base64Data);
                const bytes = new Uint8Array(binaryString.length);
                for (let i = 0; i < binaryString.length; i++) {
                    bytes[i] = binaryString.charCodeAt(i);
                }
                const iframe = this.template.querySelector('iframe');
                if (!iframe) throw new Error('PDF Engine iframe not found.');

                iframe.contentWindow.postMessage({
                    type: 'generate',
                    blob: bytes.buffer,
                    fileName: docTitle,
                    mode: this.outputMode
                }, '*');

                // Safety timeout — stop spinner if PDF engine never responds
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                this._pdfTimeout = setTimeout(() => {
                    if (this.isLoading) {
                        this.error = 'PDF generation timed out. Try downloading as Word instead.';
                        this.isLoading = false;
                    }
                }, 60000);
            } else if (this.outputMode === 'save') {
                this.showToast('Info', 'Saving to Record...', 'info');
                await saveGeneratedDocument({
                    recordId: this.recordId,
                    fileName: docTitle,
                    base64Data: base64Data,
                    extension: ext
                });
                this.showToast('Success', `${ext.toUpperCase()} saved to record.`, 'success');
                this.isLoading = false;
            } else {
                // Download — use octet-stream to avoid LWS MIME type restrictions
                const binaryString = atob(base64Data);
                const bytes = new Uint8Array(binaryString.length);
                for (let i = 0; i < binaryString.length; i++) {
                    bytes[i] = binaryString.charCodeAt(i);
                }
                const blob = new Blob([bytes], { type: 'application/octet-stream' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = docTitle + '.' + ext;
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                URL.revokeObjectURL(url);
                this.showToast('Success', `${isPPT ? 'PowerPoint' : 'Word document'} downloaded.`, 'success');
                this.isLoading = false;
            }

        } catch (e) {
            let msg = 'Unknown error during generation';
            if (e.body && e.body.message) {
                msg = e.body.message;
            } else if (e.message) {
                msg = e.message;
            } else if (typeof e === 'string') {
                msg = e;
            }
            this.error = 'Generation Error: ' + msg;
            this.isLoading = false;
        }
    }

    connectedCallback() {
        window.addEventListener('message', this.handleMessage);
    }

    disconnectedCallback() {
        window.removeEventListener('message', this.handleMessage);
    }

    handleMessage = async (event) => {
        if (!event.data || !event.data.type) return;
        // Validate that the message comes from a Salesforce domain
        if (!event.origin || !/\.(lightning\.force|salesforce|visualforce|force)\.com$/.test(event.origin)) return;
        if (event.data.type === 'docgen_success') {
            if (this._pdfTimeout) { clearTimeout(this._pdfTimeout); this._pdfTimeout = null; }
            if (this.outputMode === 'save' && event.data.blob) {
                await this.saveToSalesforce(event.data.fileName, event.data.blob, 'pdf');
            } else {
                this.showToast('Success', 'Document Generated successfully.', 'success');
                this.isLoading = false;
            }
        } else if (event.data.type === 'docgen_error') {
            if (this._pdfTimeout) { clearTimeout(this._pdfTimeout); this._pdfTimeout = null; }
            this.error = 'PDF Engine Error: ' + event.data.message;
            this.isLoading = false;
        }
    }

    async saveToSalesforce(fileName, blob, extension) {
        try {
            this.showToast('Info', 'Saving to Record...', 'info');
            const base64 = await this.blobToBase64(blob);
            if (!base64) throw new Error('Failed to convert file to binary data.');

            await saveGeneratedDocument({
                recordId: this.recordId,
                fileName: fileName,
                base64Data: base64,
                extension: extension
            });
            this.showToast('Success', `${extension.toUpperCase()} saved to record.`, 'success');
        } catch (e) {
            this.error = 'Save Error: ' + (e.body ? e.body.message : (e.message || e));
            this.showToast('Error', 'Save failed. Check error message.', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            if (!blob) {
                reject(new Error('Input blob is null or undefined.'));
                return;
            }
            const reader = new FileReader();
            reader.onloadend = () => {
                const base64String = reader.result.split(',')[1];
                resolve(base64String);
            };
            reader.onerror = () => {
                reject(new Error('Error reading file data.'));
            };

            if (blob instanceof ArrayBuffer) {
                reader.readAsDataURL(new Blob([blob]));
            } else if (blob instanceof Blob) {
                reader.readAsDataURL(blob);
            } else {
                try {
                    reader.readAsDataURL(new Blob([blob]));
                } catch (err) {
                    reject(new Error('Input is not a valid Blob or ArrayBuffer.'));
                }
            }
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
