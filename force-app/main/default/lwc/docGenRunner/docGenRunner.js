import { LightningElement, api, wire, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObject';
import generateDocumentData from '@salesforce/apex/DocGenController.generateDocumentData';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import PIZZIP_JS from '@salesforce/resourceUrl/pizzip';
import DOCXTEMPLATER_JS from '@salesforce/resourceUrl/docxtemplater';
import FILESAVER_JS from '@salesforce/resourceUrl/filesaver';
import HANDLEBARS_JS from '@salesforce/resourceUrl/handlebars';

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
    _templateData = []; // Store raw template metadata

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

        const loadPizZip = loadScript(this, PIZZIP_JS)
            .catch(e => { console.error('Failed to load PizZip', e); throw e; });

        const loadDocxtemplater = loadScript(this, DOCXTEMPLATER_JS)
            .catch(e => { console.error('Failed to load Docxtemplater', e); throw e; });

        const loadFileSaver = loadScript(this, FILESAVER_JS);
        const loadHandlebars = loadScript(this, HANDLEBARS_JS)
            .catch(e => { console.error('Failed to load Handlebars', e); throw e; });

        this._librariesPromise = Promise.all([
            loadPizZip,
            loadDocxtemplater,
            loadFileSaver,
            loadHandlebars
        ])
            .then(() => {
                console.log('Document Generation libraries loaded successfully');
            })
            .catch(error => {
                console.error('Library load error:', error);
            });
    }

    handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
        this.error = null;

        // Update the UI labels immediately based on selected template
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
            console.log('DocGen: Starting generation process...');

            // 0. Ensure Libraries are loaded
            if (this._librariesPromise) {
                await this._librariesPromise;
            } else {
                throw new Error('Libraries failed to initialize.');
            }

            // 1. Get Data and Template Content
            console.log('DocGen: Fetching template and record data...');
            const result = await generateDocumentData({
                templateId: this.selectedTemplateId,
                recordId: this.recordId
            });

            if (!result || !result.templateFile) {
                throw new Error('Template file content is empty or could not be retrieved.');
            }

            const templateData = result.templateFile;
            const templateType = result.templateType;
            this.templateOutputFormat = result.outputFormat || 'Document';
            let recordData = this.flattenData(JSON.parse(JSON.stringify(result.data)));
            console.log('DocGen: Record data:')
            console.log(recordData);
            const baseName = recordData.Name || recordData.QuoteNumber || recordData.CaseNumber || recordData.Subject || 'Document';

            if (templateType === 'HTML') {
                // HTML + Handlebars path
                if (!window.Handlebars) {
                    throw new Error('Handlebars library not loaded.');
                }
                // --- THE LWS FIX: Teach Handlebars to recognize LWC Arrays ---
                // *** THE LWS FIX: Override standard helpers to bypass array checks ***
                window.Handlebars.registerHelper('each', function (context, options) {
                    let ret = '';
                    let inverse = options.inverse || function () { return ''; };

                    // Duck-typing for arrays across Lightning Web Security boundaries
                    if (context && typeof context === 'object' && typeof context.length === 'number') {
                        if (context.length === 0) {
                            return inverse(this);
                        }
                        for (let i = 0; i < context.length; i++) {
                            ret += options.fn(context[i]);
                        }
                    } else {
                        return inverse(this);
                    }
                    return ret;
                });

                window.Handlebars.registerHelper('ifList', function (...args) {
                    const options = args[args.length - 1]; // Handlebars options always last
                    let list = args[0];
                    const operator = args.length > 2 ? args[1] : ">0";

                    // Duck-typing for arrays traversing Lightning Web Security boundary
                    // Note: direct length checks fail on LWS Proxies, we must test iteration length or assume array if it's an object with >0 keys
                    const isListDef = list && typeof list === 'object' && (Array.isArray(list) || typeof list.length === 'number');

                    if (!isListDef) {
                        return (typeof options.inverse === 'function') ? options.inverse(this) : '';
                    }

                    // For LWS Proxies we try to force it to a real array if it acts like one
                    if (!Array.isArray(list)) {
                        try {
                            list = Array.from(list);
                        } catch (e) {
                            // Fallback if Array.from fails on the proxy
                            const temp = [];
                            for (let i = 0; i < list.length; i++) temp.push(list[i]);
                            list = temp;
                        }
                    }

                    let isMatch = false;

                    // "count" indicates we want to filter the list and THEN check length > 0
                    if (operator === 'count' && args.length >= 6) {
                        const field = args[2];
                        const compOp = args[3];
                        const compVal = args[4];

                        const filtered = list.filter(item => {
                            let itemVal = item[field];
                            if (itemVal === undefined || itemVal === null) return false;

                            // Numeric comparison if possible
                            if (!isNaN(itemVal) && !isNaN(compVal)) {
                                if (compOp === '=' || compOp === '==' || compOp === '===') {
                                    return Number(itemVal) === Number(compVal);
                                }
                                if (compOp === '!=' || compOp === '!==') {
                                    return Number(itemVal) !== Number(compVal);
                                }
                                if (compOp === '>') return Number(itemVal) > Number(compVal);
                                if (compOp === '>=') return Number(itemVal) >= Number(compVal);
                                if (compOp === '<') return Number(itemVal) < Number(compVal);
                                if (compOp === '<=') return Number(itemVal) <= Number(compVal);
                            }

                            // String default
                            let sItem = String(itemVal).trim().toLowerCase();
                            let sComp = String(compVal).trim().toLowerCase();
                            switch (compOp) {
                                case '=':
                                case '==':
                                case '===':
                                    return sItem === sComp;
                                case '!=':
                                case '!==':
                                    return sItem !== sComp;
                                default:
                                    return false;
                            }
                        });
                        isMatch = (filtered.length > 0);
                    } else {
                        // Simple length check
                        if (operator === '>0' || !operator) {
                            isMatch = (list.length > 0);
                        } else if (operator === '=0') {
                            isMatch = (list.length === 0);
                        }
                    }

                    if (isMatch) {
                        return (typeof options.fn === 'function') ? options.fn(this) : '';
                    } else {
                        return (typeof options.inverse === 'function') ? options.inverse(this) : '';
                    }
                });
                console.log('DocGen: HTML template detected. Rendering with Handlebars...');
                const htmlString = this.base64ToUtf8String(templateData);
                const template = window.Handlebars.compile(htmlString);
                const renderedHtml = template(recordData, {
                    allowProtoPropertiesByDefault: true,
                    allowProtoMethodsByDefault: true
                });
                if (this.templateOutputFormat === 'PDF') {
                    console.log('DocGen: PDF output requested. Sending HTML to PDF Engine...');
                    this.showToast('Info', 'Generating PDF...', 'info');
                    const iframe = this.template.querySelector('iframe');
                    if (!iframe) throw new Error('PDF Engine iframe not found.');
                    iframe.contentWindow.postMessage({
                        type: 'generate',
                        html: renderedHtml,
                        fileName: baseName,
                        mode: this.outputMode
                    }, '*');
                } else {
                    // Use application/octet-stream so FileSaver/LWS accepts the blob (filename .html still opens as HTML)
                    const blob = new Blob([renderedHtml], { type: 'application/octet-stream' });
                    if (this.outputMode === 'save') {
                        await this.saveToSalesforce(baseName, blob, 'html');
                    } else {
                        window.saveAs(blob, baseName + '.html');
                        this.showToast('Success', 'HTML document downloaded.', 'success');
                        this.isLoading = false;
                    }
                }
                return;
            }

            // Word/PowerPoint path: require PizZip and docxtemplater
            if (!window.PizZip || !window.docxtemplater) {
                throw new Error('Required libraries (PizZip/docxtemplater) not found in window scope.');
            }
            // 2. Local DOCX/PPTX Generation (PizZip + docxtemplater)
            console.log('DocGen: Processing record data and initializing docxtemplater...');
            const binaryString = atob(templateData);
            const len = binaryString.length;
            const bytes = new Uint8Array(len);
            for (let i = 0; i < len; i++) {
                bytes[i] = binaryString.charCodeAt(i);
            }

            const zip = new window.PizZip(bytes.buffer);
            const doc = new window.docxtemplater(zip, {
                paragraphLoop: true,
                linebreaks: true,
                delimiters: { start: '{', end: '}' },
                nullGetter: () => { return ''; },
                parser: (tag) => {
                    return {
                        get: (scope) => {
                            if (tag === '.') return scope;
                            const keys = tag.split('.');
                            let value = scope;
                            for (let i = 0; i < keys.length; i++) {
                                if (value === undefined || value === null) return '';
                                value = value[keys[i]];
                            }
                            return value;
                        }
                    };
                }
            });

            console.log('DocGen: Rendering template...');
            doc.render(recordData);

            const isPPT = templateType === 'PowerPoint';
            const isPDF = this.templateOutputFormat === 'PDF' && !isPPT;

            if (isPPT) {
                console.log('DocGen: PowerPoint detected. Generating PPTX...');
                const outBlob = doc.getZip().generate({ type: 'blob' });
                if (this.outputMode === 'save') {
                    await this.saveToSalesforce(baseName, outBlob, 'pptx');
                } else {
                    window.saveAs(outBlob, baseName + '.pptx');
                    this.showToast('Success', 'PowerPoint downloaded.', 'success');
                    this.isLoading = false;
                }
            } else if (!isPDF) {
                console.log('DocGen: Native format detected. Generating DOCX...');
                const outBlob = doc.getZip().generate({ type: 'blob' });
                if (this.outputMode === 'save') {
                    await this.saveToSalesforce(baseName, outBlob, 'docx');
                } else {
                    window.saveAs(outBlob, baseName + '.docx');
                    this.showToast('Success', 'Word document downloaded.', 'success');
                    this.isLoading = false;
                }
            } else {
                // Word DOCX -> Send to PDF Engine (For PDF Output)
                console.log('DocGen: PDF output requested. Sending to PDF Engine...');
                this.showToast('Info', 'Generating PDF...', 'info');
                const docxBuffer = doc.getZip().generate({ type: 'arraybuffer' });
                const iframe = this.template.querySelector('iframe');

                if (!iframe) throw new Error('PDF Engine iframe not found.');

                iframe.contentWindow.postMessage({
                    type: 'generate',
                    blob: docxBuffer,
                    fileName: baseName,
                    mode: this.outputMode
                }, '*');
            }

        } catch (e) {
            console.error('DocGen Error Detailed:', e);
            let msg = 'Unknown error during generation';

            if (e.message) {
                msg = e.message;
            } else if (typeof e === 'string') {
                msg = e;
            } else {
                try {
                    msg = JSON.stringify(e);
                } catch (jsonErr) {
                    msg = 'Critical failure (could not stringify error)';
                }
            }

            if (e.properties && e.properties.errors instanceof Array) {
                msg += ': ' + e.properties.errors.map(err => err.properties.explanation).join(', ');
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
        if (event.data.type === 'docgen_success') {
            console.log('DocGen: PDF Engine success received.');
            if (this.outputMode === 'save' && event.data.blob) {
                await this.saveToSalesforce(event.data.fileName, event.data.blob, 'pdf');
            } else {
                this.showToast('Success', 'Document Generated successfully.', 'success');
                this.isLoading = false;
            }
        } else if (event.data.type === 'docgen_error') {
            console.error('DocGen: PDF Engine reported error:', event.data.message);
            this.error = 'PDF Engine Error: ' + event.data.message;
            this.isLoading = false;
        }
    }

    async saveToSalesforce(fileName, blob, extension) {
        try {
            console.log(`DocGen: Saving ${extension} to record...`);
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
            console.error('DocGen: Save error:', e);
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
            reader.onerror = (e) => {
                console.error('FileReader error:', e);
                reject(new Error('Error reading file data.'));
            };

            if (blob instanceof ArrayBuffer) {
                reader.readAsDataURL(new Blob([blob]));
            } else if (blob instanceof Blob) {
                reader.readAsDataURL(blob);
            } else {
                // Try treating it as a buffer if it's an TypedArray
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

    base64ToUtf8String(base64) {
        const binaryString = atob(base64);
        const len = binaryString.length;
        const bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
            bytes[i] = binaryString.charCodeAt(i);
        }
        return new TextDecoder('utf-8').decode(bytes);
    }

    flattenData(obj) {
        if (!obj || typeof obj !== 'object') return obj;

        // Deep clone arrays to natively bypass LWS Object.keys() / length proxy blocks
        if (Array.isArray(obj)) {
            return obj.map(item => this.flattenData(item));
        }

        if (obj.hasOwnProperty('totalSize') && obj.hasOwnProperty('records')) {
            return this.flattenData(obj.records);
        }

        const newObj = {};
        for (const key in obj) {
            if (Object.prototype.hasOwnProperty.call(obj, key)) {
                if (key === 'attributes') continue;
                newObj[key] = this.flattenData(obj[key]);
            }
        }
        return newObj;
    }
}