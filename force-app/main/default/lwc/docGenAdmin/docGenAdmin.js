import { LightningElement, track, wire } from 'lwc';
import { createRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { downloadBase64 as downloadBase64Util } from 'c/docGenUtils';

// Apex
import getAllTemplates from '@salesforce/apex/DocGenController.getAllTemplates';
import deleteTemplate from '@salesforce/apex/DocGenController.deleteTemplate';
import saveTemplate from '@salesforce/apex/DocGenController.saveTemplate';
import getTemplateVersions from '@salesforce/apex/DocGenController.getTemplateVersions';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import activateVersion from '@salesforce/apex/DocGenController.activateVersion';
import createSampleTemplates from '@salesforce/apex/DocGenController.createSampleTemplates';

// Schema
import DOCGEN_TEMPLATE_OBJECT from '@salesforce/schema/DocGen_Template__c';
import NAME_FIELD from '@salesforce/schema/DocGen_Template__c.Name';
import CATEGORY_FIELD from '@salesforce/schema/DocGen_Template__c.Category__c';
import TYPE_FIELD from '@salesforce/schema/DocGen_Template__c.Type__c';
import BASE_OBJECT_FIELD from '@salesforce/schema/DocGen_Template__c.Base_Object_API__c';
import QUERY_CONFIG_FIELD from '@salesforce/schema/DocGen_Template__c.Query_Config__c';
import DESC_FIELD from '@salesforce/schema/DocGen_Template__c.Description__c';
import OUTPUT_FORMAT_FIELD from '@salesforce/schema/DocGen_Template__c.Output_Format__c';
import TEST_RECORD_FIELD from '@salesforce/schema/DocGen_Template__c.Test_Record_Id__c';
import DOC_TITLE_FIELD from '@salesforce/schema/DocGen_Template__c.Document_Title_Format__c';
import IS_DEFAULT_FIELD from '@salesforce/schema/DocGen_Template__c.Is_Default__c';
// Version fields (DocGen_Template_Version__c)
import VER_IS_ACTIVE_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Is_Active__c';
import VER_CV_ID_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Content_Version_Id__c';

// Field API name map — resolves namespace automatically
const F = {
    Name: 'Name',
    Category: CATEGORY_FIELD.fieldApiName,
    Type: TYPE_FIELD.fieldApiName,
    OutputFormat: OUTPUT_FORMAT_FIELD.fieldApiName,
    BaseObject: BASE_OBJECT_FIELD.fieldApiName,
    QueryConfig: QUERY_CONFIG_FIELD.fieldApiName,
    Desc: DESC_FIELD.fieldApiName,
    TestRecordId: TEST_RECORD_FIELD.fieldApiName,
    DocTitleFormat: DOC_TITLE_FIELD.fieldApiName,
    IsDefault: IS_DEFAULT_FIELD.fieldApiName,
    // Version fields
    VerIsActive: VER_IS_ACTIVE_FIELD.fieldApiName,
    VerCvId: VER_CV_ID_FIELD.fieldApiName
};

const COLUMNS = [
    { label: 'Category', fieldName: F.Category, initialWidth: 150 },
    { label: 'Name', fieldName: 'Name' },
    { label: 'Type', fieldName: F.Type, initialWidth: 100 },
    { label: 'Output Format', fieldName: F.OutputFormat, initialWidth: 120 },
    { label: 'Base Object', fieldName: F.BaseObject },
    { label: 'Default', fieldName: 'defaultLabel', initialWidth: 80, cellAttributes: { class: { fieldName: 'defaultClass' } } },
    { label: 'Description', fieldName: F.Desc },
    { type: 'action', typeAttributes: { rowActions: [
        { label: 'View', name: 'view' },
        { label: 'Edit', name: 'edit' },
        { label: 'Share', name: 'share' },
        { label: 'Delete', name: 'delete' }
    ] } }
];

const VERSION_COLUMNS = [
    { label: 'Ver', fieldName: 'VersionNumber', initialWidth: 70 },
    { label: 'Active', fieldName: 'isActiveLabel', initialWidth: 70, cellAttributes: {
        class: { fieldName: 'activeClass' }
    }},
    { label: 'Created Date', fieldName: 'CreatedDate', type: 'date', typeAttributes: {
        year: 'numeric', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit'
    }},
    { label: 'Created By', fieldName: 'CreatedByName' },
    { type: 'button', initialWidth: 100, typeAttributes: {
        label: 'Preview', name: 'preview', variant: 'neutral', iconName: 'utility:preview'
    }},
    { type: 'button', typeAttributes: {
        label: 'Activate', name: 'restore', title: 'Restore and Activate this version', variant: 'brand',
        disabled: { fieldName: 'Is_Active__c' }
    }}
];

    export default class DocGenAdmin extends NavigationMixin(LightningElement) {
    @track templates = [];
    columns = COLUMNS;
    versionColumns = VERSION_COLUMNS;
    wiredTemplatesResult;

    @track versions = [];

    // Form/Wizard State
    @track activeMainTab = 'new_template';
    @track currentWizardStep = '1';

    // Create State
    newTemplateName = '';
    newTemplateCategory = '';
    @track newTemplateType = 'Word';
    @track newTemplateOutputFormat = 'PDF';
    newTemplateObject = 'Account';
    newTemplateDesc = '';
    newTemplateQuery = '';
    isCreating = true;
    createdTemplateId;

    // Edit State
    @track isEditModalOpen = false;
    @track activeEditTab = 'details';
    editTemplateId;
    editTemplateName;
    editTemplateCategory;
    @track editTemplateType;
    editTemplateObject;
    @track editTemplateOutputFormat;
    editTemplateDesc;
    editTemplateQuery;
    editTemplateTestRecordId;
    editTemplateTitleFormat;
    editTemplateIsDefault = false;

    @track currentFileId;
    @track uploadedFileName = '';

    // Preview/Restore State
    @track isPreviewModalOpen = false;
    @track previewVersion = {};
    isLoadingVersions = false;

    // Manual Query Toggle (Edit modal)
    @track isManualQuery = false;
    // Manual Query Toggle (Create wizard)
    @track isNewManualQuery = false;

    // Filter State
    searchKey = '';

    @track isInstallingSamples = false;
    _samplesChecked = false;

    @wire(getAllTemplates)
    wiredTemplates(result) {
        this.wiredTemplatesResult = result;
        if (result.data) {
            this.templates = result.data.map(t => ({
                ...t,
                defaultLabel: t[F.IsDefault] ? '★' : '',
                defaultClass: t[F.IsDefault] ? 'slds-text-color_success slds-text-title_bold' : ''
            }));
            // Auto-install sample templates on first load if org has none
            if (this.templates.length === 0 && !this._samplesChecked && !this.isInstallingSamples) {
                this._samplesChecked = true;
                this.installSampleTemplates();
            }
        } else if (result.error) {
           this.showToast('Error', 'Error loading templates', 'error');
        }
    }

    get filteredTemplates() {
        if (!this.searchKey) return this.templates;
        const lowerKey = this.searchKey.toLowerCase();
        return this.templates.filter(t =>
            (t.Name && t.Name.toLowerCase().includes(lowerKey)) ||
            (t[F.Category] && t[F.Category].toLowerCase().includes(lowerKey)) ||
            (t[F.BaseObject] && t[F.BaseObject].toLowerCase().includes(lowerKey)) ||
            (t[F.Type] && t[F.Type].toLowerCase().includes(lowerKey)) ||
            (t[F.OutputFormat] && t[F.OutputFormat].toLowerCase().includes(lowerKey)) ||
            (t[F.Desc] && t[F.Desc].toLowerCase().includes(lowerKey)) ||
            (t.Id && t.Id.toLowerCase().includes(lowerKey))
        );
    }

    handleRefresh() {
        return refreshApex(this.wiredTemplatesResult);
    }

    handleSearch(event) {
        this.searchKey = event.detail.value;
    }

    async installSampleTemplates() {
        this.isInstallingSamples = true;
        try {
            const count = await createSampleTemplates();
            this.showToast('Welcome to DocGen!', count + ' sample templates installed. Open any template to see how merge tags work.', 'success');
            await refreshApex(this.wiredTemplatesResult);
            this.activeMainTab = 'list';
        } catch (error) {
            const msg = error.body ? error.body.message : error.message;
            this.showToast('Error', 'Failed to create sample templates: ' + msg, 'error');
        } finally {
            this.isInstallingSamples = false;
        }
    }

    // --- Wizard Logic ---

    get isStep1() { return this.currentWizardStep === '1'; }
    get isStep2() { return this.currentWizardStep === '2'; }
    get isStep3() { return this.currentWizardStep === '3'; }
    get isBackDisabled() { return this.currentWizardStep === '1'; }

    handleNextStep() {
        if (this.currentWizardStep === '1') {
            if (!this.newTemplateName || !this.newTemplateType) {
                this.showToast('Error', 'Please fill required fields.', 'error');
                return;
            }
            this.currentWizardStep = '2';
        } else if (this.currentWizardStep === '2') {
             if (!this.newTemplateObject || !this.newTemplateQuery) {
                this.showToast('Error', 'Please configure the query.', 'error');
                return;
             }
             this.currentWizardStep = '3';
        }
    }

    handlePrevStep() {
        if (this.currentWizardStep === '3') this.currentWizardStep = '2';
        else if (this.currentWizardStep === '2') this.currentWizardStep = '1';
    }

    handleWizardTabActive() {
        this.activeMainTab = 'new_template';
        this.resetForm();
    }

    handleTabActive(event) {
        this.activeMainTab = event.target.value;
    }

    // --- Create Handlers ---
    handleNameChange(event) { this.newTemplateName = event.detail.value; }
    handleCategoryChange(event) { this.newTemplateCategory = event.detail.value; }
    handleTypeChange(event) {
        this.newTemplateType = event.detail.value;
        // Excel only supports Native output — auto-switch from PDF
        if (event.detail.value === 'Excel' && this.newTemplateOutputFormat === 'PDF') {
            this.newTemplateOutputFormat = 'Native';
        }
    }
    handleOutputFormatChange(event) { this.newTemplateOutputFormat = event.detail.value; }
    handleDescChange(event) { this.newTemplateDesc = event.detail.value; }

    handleConfigChange(event) {
        this.newTemplateObject = event.detail.objectName;
        this.newTemplateQuery = event.detail.queryConfig;
    }

    get readableQueryConfig() {
        return this._formatQueryConfig(this.newTemplateQuery);
    }

    get readableEditQueryConfig() {
        return this._formatQueryConfig(this.editTemplateQuery);
    }

    get isV3Query() {
        const q = this.newTemplateQuery;
        return q && q.trim().startsWith('{') && q.includes('"v":3');
    }

    get isEditV3Query() {
        const q = this.editTemplateQuery;
        return q && q.trim().startsWith('{') && q.includes('"v":3');
    }

    _formatQueryConfig(configStr) {
        if (!configStr) { return ''; }
        try {
            const cfg = JSON.parse(configStr);
            if (cfg.v !== 3 || !cfg.nodes) { return configStr; }

            // Build V1-style SOQL field list from V3 tree
            const root = cfg.nodes.find(n => !n.parentNode);
            if (!root) { return configStr; }

            const parts = [];

            // Root fields
            if (root.fields && root.fields.length) {
                parts.push(...root.fields);
            }
            // Root parent fields (e.g., Owner.Name)
            if (root.parentFields && root.parentFields.length) {
                parts.push(...root.parentFields);
            }

            // Child subqueries
            const buildSubquery = (parentId) => {
                const children = cfg.nodes.filter(n => n.parentNode === parentId);
                for (const child of children) {
                    const subFields = [];
                    if (child.fields && child.fields.length) {
                        subFields.push(...child.fields);
                    }
                    if (child.parentFields && child.parentFields.length) {
                        subFields.push(...child.parentFields);
                    }
                    let subquery = '(SELECT ' + subFields.join(', ') + ' FROM ' + child.relationshipName;
                    if (child.where) { subquery += ' WHERE ' + child.where; }
                    if (child.orderBy) { subquery += ' ORDER BY ' + child.orderBy; }
                    if (child.limit) { subquery += ' LIMIT ' + child.limit; }
                    subquery += ')';
                    parts.push(subquery);

                    // Recurse for grandchildren (nested in comment for clarity)
                    const grandchildren = cfg.nodes.filter(n => n.parentNode === child.id);
                    if (grandchildren.length > 0) {
                        for (const gc of grandchildren) {
                            const gcFields = [...(gc.fields || []), ...(gc.parentFields || [])];
                            let gcQuery = '  \u2192 ' + gc.relationshipName + ': ' + gcFields.join(', ');
                            if (gc.where) { gcQuery += ' WHERE ' + gc.where; }
                            parts.push(gcQuery);
                        }
                    }
                }
            };
            buildSubquery(root.id);

            return parts.join(', ');
        } catch {
            return configStr;
        }
    }

    handleNewManualQueryToggle(event) {
        this.isNewManualQuery = event.target.checked;
    }

    handleNewQueryStringChange(event) {
        this.newTemplateQuery = event.target.value;
    }

    handleNewManualObjectChange(event) {
        this.newTemplateObject = event.detail.value;
    }

    // --- Edit Handlers ---
    handleEditNameChange(event) { this.editTemplateName = event.detail.value; }
    handleEditCategoryChange(event) { this.editTemplateCategory = event.detail.value; }
    handleEditTypeChange(event) {
        this.editTemplateType = event.detail.value;
        if (event.detail.value === 'Excel' && this.editTemplateOutputFormat === 'PDF') {
            this.editTemplateOutputFormat = 'Native';
        }
    }
    handleEditOutputFormatChange(event) { this.editTemplateOutputFormat = event.detail.value; }
    handleEditDescChange(event) { this.editTemplateDesc = event.detail.value; }
    handleEditDefaultChange(event) { this.editTemplateIsDefault = event.target.checked; }

    handleManualQueryToggle(event) {
        this.isManualQuery = event.target.checked;
        // Convert V3 JSON to V1 flat string when switching to manual mode
        if (this.isManualQuery && this.isEditV3Query) {
            const v1 = this._formatQueryConfig(this.editTemplateQuery);
            if (v1 && v1 !== this.editTemplateQuery) {
                this.editTemplateQuery = v1;
            }
        }
    }

    handleQueryStringChange(event) {
        this.editTemplateQuery = event.target.value;
    }

    handleEditConfigChange(event) {
        this.editTemplateObject = event.detail.objectName;
        this.editTemplateQuery = event.detail.queryConfig;
    }

    handleEditTestRecordChange(event) {
        this.editTemplateTestRecordId = event.detail.recordId;
    }

    // Generate a flat tag list from the query config for the tags view
    get editTemplateTags() {
        const qc = this.editTemplateQuery;
        if (!qc) return null;

        try {
            // Try JSON v3
            if (qc.trim().startsWith('{')) {
                const config = JSON.parse(qc);
                if (config.v >= 3 && config.nodes) {
                    const sections = [];
                    for (const node of config.nodes) {
                        const tags = [];
                        if (node.fields) {
                            for (const f of node.fields) {
                                tags.push({ code: '{' + f + '}' });
                            }
                        }
                        if (node.parentFields) {
                            for (const pf of node.parentFields) {
                                tags.push({ code: '{' + pf + '}' });
                            }
                        }
                        const isLoop = !!node.parentNode;
                        sections.push({
                            name: node.object + (isLoop ? ' (loop)' : ''),
                            isLoop,
                            loopStart: isLoop ? '{#' + node.relationshipName + '}' : '',
                            loopEnd: isLoop ? '{/' + node.relationshipName + '}' : '',
                            tags
                        });
                    }
                    return sections.length > 0 ? sections : null;
                }
            }

            // Legacy: parse field names from the query string
            const fields = qc.split(',').map(f => f.trim()).filter(f => !f.startsWith('('));
            const subqueries = qc.match(/\(\s*SELECT\s+([\s\S]+?)\s+FROM\s+(\S+)/gi) || [];
            const sections = [];

            if (fields.length > 0) {
                sections.push({
                    name: this.editTemplateObject || 'Base Fields',
                    isLoop: false,
                    tags: fields.map(f => ({ code: '{' + f + '}' }))
                });
            }

            for (const sq of subqueries) {
                const match = sq.match(/SELECT\s+([\s\S]+?)\s+FROM\s+(\S+)/i);
                if (match) {
                    const childFields = match[1].split(',').map(f => f.trim());
                    const relName = match[2].replace(')', '');
                    sections.push({
                        name: relName,
                        isLoop: true,
                        loopStart: '{#' + relName + '}',
                        loopEnd: '{/' + relName + '}',
                        tags: childFields.map(f => ({ code: '{' + f + '}' }))
                    });
                }
            }

            return sections.length > 0 ? sections : null;
        } catch {
            return null;
        }
    }

    async handleCopyEditTag(event) {
        const tag = event.currentTarget.dataset.tag;
        if (!tag) { return; }
        try {
            await this._copyToClipboard(tag);
            this.dispatchEvent(new ShowToastEvent({ title: 'Copied', message: tag, variant: 'success' }));
        } catch {
            this.dispatchEvent(new ShowToastEvent({ title: 'Copy Failed', message: 'Unable to copy to clipboard.', variant: 'error' }));
        }
    }

    _copyToClipboard(text) {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        }
        const textArea = document.createElement('textarea');
        textArea.value = text;
        textArea.style.position = 'fixed';
        textArea.style.left = '-9999px';
        document.body.appendChild(textArea);
        textArea.focus();
        textArea.select();
        try {
            document.execCommand('copy');
        } finally {
            document.body.removeChild(textArea);
        }
        return Promise.resolve();
    }

    handleTitleFormatChange(event) {
        this.editTemplateTitleFormat = event.detail.value;
    }

    get isBuilderDisabled() {
        return this.isManualQuery;
    }

    // --- Options ---
    get typeOptions() {
        return [
            { label: 'Word', value: 'Word' },
            { label: 'PowerPoint', value: 'PowerPoint' },
            { label: 'Excel', value: 'Excel' }
        ];
    }

    get outputFormatOptions() {
        const type = this.isCreating ? this.newTemplateType : this.editTemplateType;
        if (type === 'Excel') {
            return [
                { label: 'Native (.xlsx)', value: 'Native' }
            ];
        }
        return [
            { label: type === 'PowerPoint' ? 'Native (.pptx)' : 'Native (.docx)', value: 'Native' },
            { label: 'PDF', value: 'PDF' }
        ];
    }

    get acceptedFormats() {
        const type = this.isCreating ? this.newTemplateType : this.editTemplateType;
        if (type === 'PowerPoint') return ['.pptx'];
        if (type === 'Excel') return ['.xlsx'];
        return ['.docx'];
    }

    // --- Create Logic ---
    async createTemplate() {
        const fields = {};
        fields[NAME_FIELD.fieldApiName] = this.newTemplateName;
        fields[CATEGORY_FIELD.fieldApiName] = this.newTemplateCategory;
        fields[TYPE_FIELD.fieldApiName] = this.newTemplateType;
        fields[OUTPUT_FORMAT_FIELD.fieldApiName] = this.newTemplateOutputFormat;
        fields[BASE_OBJECT_FIELD.fieldApiName] = this.newTemplateObject;
        fields[QUERY_CONFIG_FIELD.fieldApiName] = this.newTemplateQuery;
        fields[DESC_FIELD.fieldApiName] = this.newTemplateDesc;

        try {
            const record = await createRecord({ apiName: DOCGEN_TEMPLATE_OBJECT.objectApiName, fields });
            this.createdTemplateId = record.id;
            this.isCreating = false;
            this.showToast('Success', 'Template Record created. Please upload your document.', 'success');

            const newRow = {
                Id: record.id,
                Name: this.newTemplateName,
                [F.Category]: this.newTemplateCategory,
                [F.Type]: this.newTemplateType,
                [F.OutputFormat]: this.newTemplateOutputFormat,
                [F.BaseObject]: this.newTemplateObject,
                [F.Desc]: this.newTemplateDesc,
                [F.QueryConfig]: this.newTemplateQuery,
                [F.TestRecordId]: null,
                [F.DocTitleFormat]: null,
                ContentDocumentLinks: []
            };

            this.resetForm();
            await refreshApex(this.wiredTemplatesResult);

            this.activeMainTab = 'list';
            this.activeEditTab = 'document';
            this.openEditModal(newRow, 'document');

        } catch (error) {
            this.showToast('Error creating record', error.body ? error.body.message : error.message, 'error');
        }
    }

    // --- Sharing Logic ---
    @track isSharingModalOpen = false;
    sharingTemplateId;

    handleCloseSharing() {
        this.isSharingModalOpen = false;
    }

    // --- Row Action ---
    async handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;

        if (actionName === 'delete') {
            try {
                await deleteTemplate({ templateId: row.Id });
                this.showToast('Success', 'Template deleted', 'success');
                return refreshApex(this.wiredTemplatesResult);
            } catch (error) {
                this.showToast('Error deleting template', error.body ? error.body.message : error.message, 'error');
            }
        } else if (actionName === 'edit') {
            this.openEditModal(row, 'details');
        } else if (actionName === 'view') {
            this.openEditModal(row, 'tags');
        } else if (actionName === 'share') {
            this.sharingTemplateId = row.Id;
            this.isSharingModalOpen = true;
        }
    }

    // --- Edit Modal ---
    openEditModal(row, activeTab) {
        try {
            this.editTemplateId = row.Id;
            this.editTemplateName = row.Name;
            this.editTemplateCategory = row[F.Category];
            this.editTemplateType = row[F.Type];
            this.editTemplateObject = row[F.BaseObject];
            this.editTemplateOutputFormat = row[F.OutputFormat] || 'Native';
            this.editTemplateDesc = row[F.Desc];
            this.editTemplateQuery = row[F.QueryConfig];
            this.editTemplateTestRecordId = row[F.TestRecordId];
            this.editTemplateTitleFormat = row[F.DocTitleFormat];
            this.editTemplateIsDefault = row[F.IsDefault] || false;

            let cdLinks = [];
            if (row.ContentDocumentLinks) {
                if (Array.isArray(row.ContentDocumentLinks)) {
                    cdLinks = row.ContentDocumentLinks;
                } else if (row.ContentDocumentLinks.records) {
                    cdLinks = row.ContentDocumentLinks.records;
                }
            }

            if (cdLinks && cdLinks.length > 0) {
                this.currentFileId = cdLinks[0].ContentDocumentId;
            } else {
                this.currentFileId = null;
            }

            if (!this.currentFileId) {
                this.activeEditTab = 'document';
            } else {
                this.activeEditTab = activeTab || 'details';
            }

            this.loadVersions(row.Id);
            this.isCreating = false;
            this.isEditModalOpen = true;
        } catch (e) {
            this.showToast('Error', 'Failed to open modal: ' + e.message, 'error');
        }
    }

    closeEditModal() {
        this.isEditModalOpen = false;
    }

    // --- Versions Logic ---
    get hasVersions() {
        return this.versions && this.versions.length > 0;
    }

    get currentVersionLabel() {
        if (this.hasVersions) {
            return this.versions[0].VersionNumber;
        }
        return '';
    }

    loadVersions(templateId) {
        getTemplateVersions({ templateId })
            .then(data => {
                if (!data) {
                    this.versions = [];
                    return;
                }
                const total = data.length;
                this.versions = data.map((v, index) => {
                    const isActive = v[F.VerIsActive];
                    return {
                        ...v,
                        VersionNumber: 'v' + (total - index),
                        CreatedByName: v.CreatedBy ? v.CreatedBy.Name : '',
                        isActiveLabel: isActive ? '✓' : '',
                        activeClass: isActive ? 'slds-text-color_success slds-text-title_bold' : '',
                        activateVariant: isActive ? 'neutral' : 'brand'
                    };
                });
            })
            .catch(() => {
                this.versions = [];
            });
    }

    async handleRestoreVersion(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        if (action === 'restore') {
            try {
                this.isLoadingVersions = true;
                await activateVersion({ versionId: row.Id });

                this.showToast('Success', 'Version activated.', 'success');

                this.editTemplateQuery = row[F.QueryConfig];
                this.editTemplateCategory = row[F.Category];
                this.editTemplateDesc = row[F.Desc];
                this.editTemplateType = row[F.Type];

                this.loadVersions(this.editTemplateId);
                refreshApex(this.wiredTemplatesResult);
            } catch (error) {
                this.showToast('Error activating version', error.body ? error.body.message : error.message, 'error');
            } finally {
                this.isLoadingVersions = false;
            }
        } else if (action === 'preview') {
            this.handlePreviewVersion(row);
        }
    }

    handlePreviewVersion(row) {
        this.previewVersion = row;
        this.isGeneratingPreview = false;
        this.isPreviewModalOpen = true;
    }

    closePreviewModal() {
        this.isPreviewModalOpen = false;
        this.isGeneratingPreview = false;
    }

    handleRestoreFromPreview() {
        const event = {
            detail: {
                action: { name: 'restore' },
                row: this.previewVersion
            }
        };
        this.handleRestoreVersion(event);
        this.closePreviewModal();
    }

    // --- Version Preview Helpers ---

    @track isGeneratingPreview = false;

    get isPreviewVersionActive() {
        return this.previewVersion?.[F.VerIsActive] || false;
    }

    get previewVersionQueryFormatted() {
        const raw = this.previewVersion?.[F.QueryConfig];
        if (!raw) return '';
        // Format: split on commas that are NOT inside parentheses (subqueries)
        let depth = 0;
        let formatted = '';
        for (let i = 0; i < raw.length; i++) {
            const ch = raw[i];
            if (ch === '(') {
                depth++;
                formatted += '\n  (';
            } else if (ch === ')') {
                depth--;
                formatted += ')';
            } else if (ch === ',' && depth === 0) {
                formatted += ',\n';
            } else {
                formatted += ch;
            }
        }
        return formatted.trim();
    }

    get previewGenerateDisabled() {
        return !this.previewVersion?.[F.VerCvId] || !this.editTemplateTestRecordId || this.isGeneratingPreview;
    }

    handlePreviewDownload() {
        const cvId = this.previewVersion?.[F.VerCvId];
        if (cvId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: {
                    url: `/sfc/servlet.shepherd/version/download/${cvId}`
                }
            }, false);
        }
    }

    async handlePreviewGenerate() {
        if (!this.previewVersion?.[F.VerCvId] || !this.editTemplateTestRecordId) {
            this.showToast('Warning', 'Template file and test record are required.', 'warning');
            return;
        }

        this.isGeneratingPreview = true;

        try {
            // Activate this version first so generation uses its file and config
            if (!this.previewVersion[F.VerIsActive]) {
                await activateVersion({ versionId: this.previewVersion.Id });
                // Sync version config to local edit state
                this.editTemplateQuery = this.previewVersion[F.QueryConfig];
                this.editTemplateCategory = this.previewVersion[F.Category];
                this.editTemplateDesc = this.previewVersion[F.Desc];
                this.editTemplateType = this.previewVersion[F.Type];
                this.loadVersions(this.editTemplateId);
                refreshApex(this.wiredTemplatesResult);
            }

            const isPPT = ['PowerPoint', 'PPT', 'PPTX'].includes(this.previewVersion[F.Type]);

            if (isPPT || this.editTemplateOutputFormat === 'Native') {
                const result = await processAndReturnDocument({
                    templateId: this.editTemplateId,
                    recordId: this.editTemplateTestRecordId
                });
                if (!result || !result.base64) {
                    throw new Error('Document generation returned empty result.');
                }
                const docTitle = 'Preview_' + this.previewVersion.VersionNumber + '_' + (result.title || 'Document');
                const ext = isPPT ? '.pptx' : '.docx';
                this.downloadBase64(result.base64, docTitle + ext, 'application/octet-stream');
                this.showToast('Success', 'Sample document generated for ' + this.previewVersion.VersionNumber, 'success');
            } else {
                this.showToast('Info', 'Generating PDF sample for ' + this.previewVersion.VersionNumber + '...', 'info');
                const pdfResult = await generatePdf({
                    templateId: this.editTemplateId,
                    recordId: this.editTemplateTestRecordId,
                    saveToRecord: false
                });
                if (!pdfResult || !pdfResult.base64) {
                    throw new Error('PDF generation returned empty result.');
                }
                const pdfTitle = 'Preview_' + this.previewVersion.VersionNumber + '_' + (pdfResult.title || 'Document');
                this.downloadBase64(pdfResult.base64, pdfTitle + '.pdf', 'application/pdf');
                this.showToast('Success', 'PDF sample generated for ' + this.previewVersion.VersionNumber, 'success');
            }
        } catch (error) {
            let msg = 'Unknown error';
            if (error.body && error.body.message) msg = error.body.message;
            else if (error.message) msg = error.message;
            this.showToast('Generation Failed', msg, 'error');
        } finally {
            this.isGeneratingPreview = false;
        }
    }

    // --- Save Logic ---
    async handleSaveOnly() {
         if (!this.editTemplateName || !this.editTemplateType) {
            this.showToast('Error', 'Name and Type are required.', 'error');
            return;
        }

        const fields = {
            Id: this.editTemplateId,
            Name: this.editTemplateName,
            'Category__c': this.editTemplateCategory,
            'Type__c': this.editTemplateType,
            'Output_Format__c': this.editTemplateOutputFormat,
            'Base_Object_API__c': this.editTemplateObject,
            'Description__c': this.editTemplateDesc,
            'Query_Config__c': this.editTemplateQuery,
            'Test_Record_Id__c': this.editTemplateTestRecordId,
            'Document_Title_Format__c': this.editTemplateTitleFormat,
            'Is_Default__c': this.editTemplateIsDefault
        };

        try {
            await saveTemplate({ fields: fields, createVersion: false });
            this.showToast('Success', 'Template Details saved.', 'success');
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Error saving template', error.body ? error.body.message : error.message, 'error');
        }
    }

    async handleSaveAndClose() {
        if (!this.editTemplateName || !this.editTemplateType) {
            this.showToast('Error', 'Name and Type are required.', 'error');
            return;
        }

        const fields = {
            Id: this.editTemplateId,
            Name: this.editTemplateName,
            'Category__c': this.editTemplateCategory,
            'Type__c': this.editTemplateType,
            'Output_Format__c': this.editTemplateOutputFormat,
            'Base_Object_API__c': this.editTemplateObject,
            'Description__c': this.editTemplateDesc,
            'Query_Config__c': this.editTemplateQuery,
            'Test_Record_Id__c': this.editTemplateTestRecordId,
            'Document_Title_Format__c': this.editTemplateTitleFormat,
            'Is_Default__c': this.editTemplateIsDefault
        };

        try {
            await saveTemplate({ fields: fields, createVersion: true });
            this.showToast('Success', 'Template and Version saved.', 'success');
            this.closeEditModal();
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Error saving template', error.body ? error.body.message : error.message, 'error');
        }
    }

    // --- Document Generation & Test Logic ---
    get editTemplateTestRecordIdEmpty() {
        return !this.editTemplateTestRecordId;
    }

    get isRealObject() {
        return this.editTemplateObject && this.editTemplateObject !== 'ApexProvider';
    }

    async handleTestGenerate() {
        if (!this.editTemplateTestRecordId) {
            this.showToast('Warning', 'Please select a Test Record ID first.', 'warning');
            return;
        }

        // Auto-heal sample query config
        if (this.editTemplateName === 'Sample Quote Template' && this.editTemplateQuery && !this.editTemplateQuery.toLowerCase().includes('quotelineitems')) {
            this.editTemplateQuery += ', (SELECT Product2.Name, Description, Quantity, UnitPrice, TotalPrice FROM QuoteLineItems)';
        }

        // Save first
        await this.handleSaveOnly();

        this.isLoadingVersions = true;

        try {
            const isPPT = ['PowerPoint', 'PPT', 'PPTX'].includes(this.editTemplateType);

            if (isPPT || this.editTemplateOutputFormat === 'Native') {
                // Native DOCX/PPTX download
                const result = await processAndReturnDocument({
                    templateId: this.editTemplateId,
                    recordId: this.editTemplateTestRecordId
                });

                if (!result || !result.base64) {
                    throw new Error('Document generation returned empty result.');
                }

                const docTitle = 'Sample_' + (result.title || 'Document');
                const ext = isPPT ? '.pptx' : '.docx';
                this.downloadBase64(result.base64, docTitle + ext, 'application/octet-stream');
                this.showToast('Success', 'Sample Document Downloaded', 'success');
            } else {
                // PDF generation — same path as bulk
                this.showToast('Info', 'Generating PDF Sample...', 'info');
                const pdfResult = await generatePdf({
                    templateId: this.editTemplateId,
                    recordId: this.editTemplateTestRecordId,
                    saveToRecord: false
                });

                if (!pdfResult || !pdfResult.base64) {
                    throw new Error('PDF generation returned empty result.');
                }
                const pdfTitle = 'Sample_' + (pdfResult.title || 'Document');
                this.downloadBase64(pdfResult.base64, pdfTitle + '.pdf', 'application/pdf');
                this.showToast('Success', 'PDF Sample Generated', 'success');
            }
        } catch (error) {
            let msg = 'Unknown error';
            if (error.body && error.body.message) {
                msg = error.body.message;
            } else if (error.message) {
                msg = error.message;
            }
            this.showToast('Generation Failed', 'Generation Failed. ' + msg, 'error');
        } finally {
            this.isLoadingVersions = false;
        }
    }

    /**
     * Downloads a base64-encoded file via an anchor element.
     */
    downloadBase64(base64Data, fileName, mimeType) {
        downloadBase64Util(base64Data, fileName, mimeType);
    }

    // --- File Upload ---
    handleEditUploadFinished(event) {
        const uploadedFiles = event.detail.files;
        if (uploadedFiles && uploadedFiles.length > 0) {
            const file = uploadedFiles[0];
            this.showToast('Success', 'File Uploaded: ' + file.name, 'success');
            this.currentFileId = file.documentId;
            this.uploadedFileName = file.name;
        }
    }

    downloadTemplate() {
        if (this.currentFileId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: {
                    url: `/sfc/servlet.shepherd/document/download/${this.currentFileId}`
                }
            }, false);
        }
    }

    resetForm() {
        this.uploadedFileName = '';
        this.currentWizardStep = '1';
        this.newTemplateName = '';
        this.newTemplateCategory = '';
        this.newTemplateDesc = '';
        this.newTemplateQuery = '';
        this.newTemplateOutputFormat = 'PDF';
        this.newTemplateObject = 'Account';
        this.createdTemplateId = null;
        this.isCreating = true;
        this.isNewManualQuery = false;
        return refreshApex(this.wiredTemplatesResult);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}
