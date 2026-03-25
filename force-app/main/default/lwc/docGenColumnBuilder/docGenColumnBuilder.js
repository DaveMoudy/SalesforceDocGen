import { LightningElement, wire, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectOptions from '@salesforce/apex/DocGenController.getObjectOptions';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getParentRelationships from '@salesforce/apex/DocGenController.getParentRelationships';
import getAvailableReports from '@salesforce/apex/DocGenController.getAvailableReports';
import importReportConfig from '@salesforce/apex/DocGenController.importReportConfig';
import searchDataProviders from '@salesforce/apex/DocGenController.searchDataProviders';
import validateDataProvider from '@salesforce/apex/DocGenController.validateDataProvider';

let _nodeId = 0;
function nextNodeId() { return 'n' + (_nodeId++); }

export default class DocGenColumnBuilder extends LightningElement {

    // === PUBLIC API ===
    @api selectedObject = '';
    @api
    get queryConfig() { return this._queryConfig; }
    set queryConfig(value) {
        this._queryConfig = value;
        // Skip re-parse if this is the same config we just emitted (prevents reset loop)
        if (value && value !== this._lastEmittedConfig) {
            this._parseConfig(value);
        }
    }
    _queryConfig = '';
    _lastEmittedConfig = '';

    // === CORE STATE: Tree Nodes ===
    @track treeNodes = [];
    @track activeNodeId = null;
    @track savedReportFilters = ''; // WHERE clause from report import

    // === UI STATE ===
    @track objectOptions = [];
    @track isLoaded = false;
    @track showObjectPicker = false;
    @track objectSearchTerm = '';
    @track selectedObjectLabel = '';

    // === APEX DATA PROVIDER (V4) ===
    @track isApexProviderMode = false;
    @track providerSearchTerm = '';
    @track providerOptions = [];
    @track selectedProvider = '';
    @track providerFields = [];
    @track isValidatingProvider = false;
    @track showProviderPicker = false;

    // Add node
    @track showAddNodeModal = false;
    @track addNodeChildOptions = [];
    @track addNodeSearch = '';
    @track addNodeParentId = null;

    // Report import
    @track showReportModal = false;
    @track reportSearchResults = [];
    @track reportSearchTerm = '';
    @track selectedReportId = null;
    @track selectedReportName = '';
    @track isImportingReport = false;
    @track showImportPreview = false;
    @track importPreviewData = null;

    // === WIRES ===
    @wire(getObjectOptions)
    wiredObjects({ data }) {
        if (data) {
            this.objectOptions = data;
            this.isLoaded = true;
            // Always start with the object search — user picks the root
        }
    }

    // === COMPUTED ===
    get hasNodes() { return this.treeNodes.length > 0; }
    get rootNode() { return this.treeNodes.find(n => !n.parentNodeId); }
    get activeNode() { return this.treeNodes.find(n => n.id === this.activeNodeId); }
    get showObjectSelector() { return !this.hasNodes && !this.isProviderConnected; }

    get filteredObjectOptions() {
        const term = (this.objectSearchTerm || '').toLowerCase();
        if (term.length < 1) return [];
        return this.objectOptions.filter(o => o.label.toLowerCase().includes(term)).slice(0, 15);
    }

    get filteredAddOptions() {
        const term = (this.addNodeSearch || '').toLowerCase();
        return this.addNodeChildOptions.filter(o => o.label.toLowerCase().includes(term));
    }

    // Tab items for the tabset
    get nodeTabs() {
        return this.treeNodes.map(n => ({
            ...n,
            tabLabel: n.isRoot ? n.label : n.label,
            tabClass: n.id === this.activeNodeId ? 'active-tab' : 'inactive-tab',
            isActive: n.id === this.activeNodeId
        }));
    }

    // Visual relationship tree (rendered on every tab)
    get relationshipTree() {
        const root = this.rootNode;
        if (!root) return [];
        return this._buildTreeView(root.id, 0);
    }

    _buildTreeView(nodeId, depth) {
        const node = this.treeNodes.find(n => n.id === nodeId);
        if (!node) return [];

        const items = [{
            id: node.id,
            label: node.label,
            isRoot: node.isRoot,
            isActive: node.id === this.activeNodeId,
            depth: depth,
            indent: 'padding-left: ' + (depth * 24) + 'px',
            badgeClass: node.isRoot ? 'badge-base badge-main' :
                        node.isJunction ? 'badge-base badge-linked' : 'badge-base badge-related',
            badgeLabel: node.isRoot ? 'Main' : node.isJunction ? 'Linked' : 'Child',
            connector: depth > 0 ? '└─' : '',
            treeItemClass: node.id === this.activeNodeId ? 'slds-theme_shade' : ''
        }];

        // Find children of this node
        const children = this.treeNodes.filter(n => n.parentNodeId === nodeId);
        for (const child of children) {
            items.push(...this._buildTreeView(child.id, depth + 1));
        }
        return items;
    }

    // Merge tags for the active node
    get activeNodeTags() {
        const node = this.activeNode;
        if (!node) return null;

        const tags = [];
        // Base fields
        for (const f of node.selectedFields) {
            tags.push({ label: f, code: '{' + f + '}', type: 'field' });
        }
        // Parent fields
        if (node.parentGroups) {
            for (const pg of node.parentGroups) {
                for (const f of pg.fields) {
                    tags.push({ label: pg.relationshipName + '.' + f, code: '{' + pg.relationshipName + '.' + f + '}', type: 'parent' });
                }
            }
        }
        // Child loops
        const children = this.treeNodes.filter(n => n.parentNodeId === node.id);
        for (const child of children) {
            tags.push({
                label: child.relationshipName,
                code: '{#' + child.relationshipName + '}...{/' + child.relationshipName + '}',
                type: 'loop'
            });
        }
        return tags;
    }

    // SOQL preview for manual mode
    get soqlPreview() {
        const lines = [];
        for (const node of this.treeNodes) {
            const fields = [...node.selectedFields];
            if (node.parentGroups) {
                for (const pg of node.parentGroups) {
                    for (const f of pg.fields) fields.push(pg.relationshipName + '.' + f);
                }
            }
            if (fields.length === 0) fields.push('Id');

            let line = '-- ' + node.label + (node.isRoot ? ' (root record)' : ' (related to ' + (this.treeNodes.find(n => n.id === node.parentNodeId) || {}).label + ')') + '\n';
            line += 'SELECT ' + fields.join(', ') + '\n';
            line += 'FROM ' + node.objectApiName;
            if (node.isRoot) {
                line += ' WHERE Id = :recordId';
            } else {
                line += ' WHERE ' + node.lookupField + ' IN :parentIds';
            }
            if (node.whereClause) line += ' AND ' + node.whereClause;
            if (node.orderByClause) line += '\nORDER BY ' + node.orderByClause;
            if (node.limitClause) line += '\nLIMIT ' + node.limitClause;
            lines.push(line);
        }
        return lines.join('\n\n');
    }

    // === JSON V3 CONFIG OUTPUT ===
    get generatedConfig() {
        if (!this.rootNode || this.rootNode.selectedFields.length === 0) return '';
        const config = { v: 3, root: this.selectedObject, nodes: [] };
        for (const node of this.treeNodes) {
            const n = {
                id: node.id,
                object: node.objectApiName,
                fields: [...node.selectedFields],
                parentFields: [],
                parentNode: node.parentNodeId || null,
                lookupField: node.lookupField || null,
                relationshipName: node.relationshipName || null
            };
            if (node.parentGroups) {
                for (const pg of node.parentGroups) {
                    for (const f of pg.fields) n.parentFields.push(pg.relationshipName + '.' + f);
                }
            }
            if (node.whereClause) n.where = node.whereClause;
            if (node.orderByClause) n.orderBy = node.orderByClause;
            if (node.limitClause) n.limit = node.limitClause;
            if (node.junctionConfig) n.junction = node.junctionConfig;
            config.nodes.push(n);
        }
        if (this.savedReportFilters) {
            config.bulkWhereClause = this.savedReportFilters;
        }
        return JSON.stringify(config);
    }

    // === OBJECT SELECTION ===
    handleObjectSearch(event) {
        this.objectSearchTerm = event.detail.value || event.target.value || '';
        this.showObjectPicker = this.objectSearchTerm.length >= 1;
    }
    handleObjectFocus() {
        if (this.objectSearchTerm.length >= 1) this.showObjectPicker = true;
    }
    handleObjectSelect(event) {
        const value = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;
        this.selectedObject = value;
        this.selectedObjectLabel = label;
        this.showObjectPicker = false;
        this._initRootNode(value, label);
    }

    // === PARENT FIELD PICKER (inline, per-tab) ===
    @track showParentFieldPicker = false;
    @track parentPickerRelOptions = [];
    @track parentPickerRelSearch = '';
    @track parentPickerRelSelected = false;
    @track parentPickerRelName = '';
    @track parentPickerTargetObject = '';
    @track parentPickerFieldOptions = [];
    @track parentPickerSelectedFields = [];

    handleShowParentFieldPicker() {
        const node = this.activeNode;
        if (!node) return;
        this.parentPickerRelSelected = false;
        this.parentPickerRelSearch = '';
        this.parentPickerSelectedFields = [];

        getParentRelationships({ objectName: node.objectApiName })
            .then(data => {
                this.parentPickerRelOptions = data;
                this.showParentFieldPicker = true;
            })
            .catch(error => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Error',
                    message: error.body ? error.body.message : 'Could not load relationships.',
                    variant: 'error'
                }));
            });
    }

    handleCloseParentFieldPicker() { this.showParentFieldPicker = false; }

    handleParentPickerSearch(event) { this.parentPickerRelSearch = event.target.value; }

    get filteredParentPickerOptions() {
        const term = (this.parentPickerRelSearch || '').toLowerCase();
        return this.parentPickerRelOptions.filter(o => o.label.toLowerCase().includes(term));
    }

    handleParentPickerRelSelect(event) {
        const relName = event.currentTarget.dataset.value;
        const targetObj = event.currentTarget.dataset.target;
        this.parentPickerRelName = relName;
        this.parentPickerTargetObject = targetObj;
        this.parentPickerSelectedFields = [];
        this.parentPickerFieldSearch = '';

        getObjectFields({ objectName: targetObj })
            .then(data => {
                this.parentPickerFieldOptions = data;
                this.parentPickerRelSelected = true;
            });
    }

    handleParentPickerBack() {
        this.parentPickerRelSelected = false;
    }

    @track parentPickerFieldSearch = '';

    handleParentPickerFieldSearch(event) {
        this.parentPickerFieldSearch = event.target.value;
    }

    get filteredParentPickerFieldOptions() {
        const term = (this.parentPickerFieldSearch || '').toLowerCase();
        if (!term) return this.parentPickerFieldOptions.slice(0, 50);
        return this.parentPickerFieldOptions.filter(f =>
            f.label.toLowerCase().includes(term)
        ).slice(0, 50);
    }

    handleParentPickerFieldChange(event) {
        // Preserve selections hidden by the current search filter
        const visibleValues = new Set(this.filteredParentPickerFieldOptions.map(f => f.value));
        const hiddenSelections = this.parentPickerSelectedFields.filter(f => !visibleValues.has(f));
        this.parentPickerSelectedFields = [...hiddenSelections, ...event.detail.value];
    }

    handleParentPickerAddCommon() {
        // Auto-select the most commonly useful fields: Name, Email, Phone, Title
        const commonNames = ['name', 'email', 'phone', 'title', 'firstname', 'lastname',
            'mailingstreet', 'mailingcity', 'mailingstate', 'mailingpostalcode',
            'billingstreet', 'billingcity', 'billingstate', 'billingpostalcode',
            'industry', 'type', 'website', 'description'];
        const common = this.parentPickerFieldOptions
            .filter(f => commonNames.includes(f.value.toLowerCase()))
            .map(f => f.value);
        const merged = new Set([...this.parentPickerSelectedFields, ...common]);
        this.parentPickerSelectedFields = Array.from(merged);
    }

    handleParentPickerApply() {
        const node = this.activeNode;
        if (!node || this.parentPickerSelectedFields.length === 0) return;

        // Add as parent group on this node
        if (!node.parentGroups) node.parentGroups = [];

        // Check if this relationship group already exists
        let group = node.parentGroups.find(g => g.relationshipName === this.parentPickerRelName);
        if (!group) {
            group = { relationshipName: this.parentPickerRelName, fields: [] };
            node.parentGroups.push(group);
        }

        // Add new fields (no duplicates)
        for (const f of this.parentPickerSelectedFields) {
            if (!group.fields.includes(f)) group.fields.push(f);
        }

        this.showParentFieldPicker = false;
        this.treeNodes = [...this.treeNodes];
        this._notifyChange();

        this.dispatchEvent(new ShowToastEvent({
            title: 'Parent Fields Added',
            message: this.parentPickerSelectedFields.length + ' fields from ' + this.parentPickerRelName + ' added.',
            variant: 'success'
        }));
    }

    handleRemoveParentField(event) {
        const relName = event.currentTarget.dataset.rel;
        const fieldName = event.currentTarget.dataset.field;
        const node = this.activeNode;
        if (!node || !node.parentGroups) return;

        const group = node.parentGroups.find(g => g.relationshipName === relName);
        if (group) {
            group.fields = group.fields.filter(f => f !== fieldName);
            // Remove the group entirely if no fields left
            if (group.fields.length === 0) {
                node.parentGroups = node.parentGroups.filter(g => g.relationshipName !== relName);
            }
            this.treeNodes = [...this.treeNodes];
            this._notifyChange();
        }
    }

    handleEditParentGroup(event) {
        const relName = event.currentTarget.dataset.rel;
        const node = this.activeNode;
        if (!node) return;

        // Find the target object for this relationship
        getParentRelationships({ objectName: node.objectApiName })
            .then(data => {
                const rel = data.find(r => r.value === relName);
                if (rel) {
                    this.parentPickerRelName = relName;
                    this.parentPickerTargetObject = rel.targetObject;
                    this.parentPickerFieldSearch = '';

                    // Pre-select currently chosen fields
                    const group = node.parentGroups.find(g => g.relationshipName === relName);
                    this.parentPickerSelectedFields = group ? [...group.fields] : [];

                    getObjectFields({ objectName: rel.targetObject })
                        .then(fieldData => {
                            this.parentPickerFieldOptions = fieldData;
                            this.parentPickerRelOptions = data;
                            this.parentPickerRelSelected = true;
                            this.showParentFieldPicker = true;
                        });
                }
            });
    }

    async handleCopyTag(event) {
        const tag = event.currentTarget.dataset.copy;
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

    handleChangeRoot() {
        // Reset everything — go back to object selector
        this.treeNodes = [];
        this.activeNodeId = null;
        this.selectedObject = '';
        this.selectedObjectLabel = '';
        this.objectSearchTerm = '';
        this.isApexProviderMode = false;
        this.selectedProvider = '';
        this.providerFields = [];
        this._notifyChange();
    }

    // === APEX DATA PROVIDER (V4) ===
    handleToggleApexProvider(event) {
        this.isApexProviderMode = event.target.checked;
        if (!this.isApexProviderMode) {
            this.selectedProvider = '';
            this.providerFields = [];
            this.providerOptions = [];
        }
    }

    handleProviderSearch(event) {
        this.providerSearchTerm = event.target.value;
        if (this.providerSearchTerm.length >= 2) {
            this.showProviderPicker = true;
            searchDataProviders({ searchTerm: this.providerSearchTerm })
                .then(data => {
                    this.providerOptions = data || [];
                })
                .catch(() => { this.providerOptions = []; });
        } else {
            this.showProviderPicker = false;
            this.providerOptions = [];
        }
    }

    handleProviderSelect(event) {
        const className = event.currentTarget.dataset.value;
        this.selectedProvider = className;
        this.providerSearchTerm = className;
        this.showProviderPicker = false;
        this.isValidatingProvider = true;

        validateDataProvider({ className })
            .then(result => {
                this.isValidatingProvider = false;
                if (result.valid) {
                    this.providerFields = result.fields || [];
                    // Emit V4 config
                    const config = JSON.stringify({ v: 4, provider: className });
                    this._lastEmittedConfig = config;
                    this.dispatchEvent(new CustomEvent('configchange', {
                        detail: { objectName: 'ApexProvider', queryConfig: config }
                    }));
                    this.dispatchEvent(new ShowToastEvent({
                        title: 'Provider Connected',
                        message: className + ' — ' + this.providerFields.length + ' fields available',
                        variant: 'success'
                    }));
                } else {
                    this.providerFields = [];
                    this.dispatchEvent(new ShowToastEvent({
                        title: 'Invalid Provider',
                        message: result.error,
                        variant: 'error'
                    }));
                }
            })
            .catch(err => {
                this.isValidatingProvider = false;
                this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: err.body?.message || err.message, variant: 'error' }));
            });
    }

    get providerTags() {
        return this.providerFields.map(f => ({ code: '{' + f + '}' }));
    }

    get hasProviderFields() {
        return this.providerFields.length > 0;
    }

    get isProviderConnected() {
        return this.selectedProvider && this.providerFields.length > 0;
    }

    // === NODE MANAGEMENT ===
    _initRootNode(objectApiName, label) {
        const node = this._createNode(objectApiName, label, true, null, null, null);
        this.treeNodes = [node];
        this.activeNodeId = node.id;
        this._loadNodeFields(node);
        this._notifyChange();
    }

    _createNode(objectApiName, label, isRoot, parentNodeId, lookupField, relationshipName, junctionConfig) {
        // Clean up label — strip API name in parens, use friendly names
        let friendlyLabel = label || objectApiName;
        // "OpportunityLineItems (Opportunity Product)" → "Opportunity Products"
        if (friendlyLabel.includes('(') && friendlyLabel.includes(')')) {
            friendlyLabel = friendlyLabel.substring(friendlyLabel.indexOf('(') + 1, friendlyLabel.indexOf(')'));
            // Pluralize if it doesn't end in 's'
            if (!friendlyLabel.endsWith('s')) friendlyLabel += 's';
        }
        // "Contact (via OpportunityContactRoles)" → "Contacts"
        if (friendlyLabel.includes(' (via ')) {
            friendlyLabel = friendlyLabel.substring(0, friendlyLabel.indexOf(' (via '));
            if (!friendlyLabel.endsWith('s')) friendlyLabel += 's';
        }
        // Strip "(linked)" suffix
        friendlyLabel = friendlyLabel.replace(' (linked)', '');

        return {
            id: nextNodeId(),
            objectApiName,
            label: friendlyLabel,
            isRoot,
            isNotRoot: !isRoot,
            isJunction: !!junctionConfig,
            parentNodeId: parentNodeId || null,
            lookupField: lookupField || null,
            relationshipName: relationshipName || null,
            junctionConfig: junctionConfig || null,
            selectedFields: [],
            parentGroups: [],
            whereClause: '',
            orderByClause: '',
            limitClause: '',
            availableFields: [],
            filteredFields: []
        };
    }

    _loadNodeFields(node) {
        getObjectFields({ objectName: node.objectApiName })
            .then(data => {
                node.availableFields = data;
                node.filteredFields = data.slice(0, 200);
                this.treeNodes = [...this.treeNodes];
            });
    }

    // === TAB NAVIGATION ===
    handleTabClick(event) {
        this.activeNodeId = event.currentTarget.dataset.nodeId;
        this.showSelectedOnly = false;
        this._currentSearch = '';
    }

    handleTreeNodeClick(event) {
        this.activeNodeId = event.currentTarget.dataset.nodeId;
        this.showSelectedOnly = false;
        this._currentSearch = '';
    }

    // === ADD NODE ===
    handleAddNode() {
        const parentNode = this.activeNode || this.rootNode;
        if (!parentNode) return;
        this.addNodeParentId = parentNode.id;
        this.addNodeSearch = '';
        getChildRelationships({ objectName: parentNode.objectApiName })
            .then(data => {
                this.addNodeChildOptions = data;
                this.showAddNodeModal = true;
            });
    }

    handleAddNodeSearch(event) { this.addNodeSearch = event.target.value; }
    handleCloseAddNode() { this.showAddNodeModal = false; }

    handleAddNodeSelect(event) {
        const relName = event.currentTarget.dataset.value;
        const opt = this.addNodeChildOptions.find(o => o.value === relName);
        if (!opt) return;

        // Find the lookup field via the relationship
        const parentNode = this.treeNodes.find(n => n.id === this.addNodeParentId);
        if (!parentNode) return;

        // Don't add duplicates
        if (this.treeNodes.find(n => n.relationshipName === relName && n.parentNodeId === this.addNodeParentId)) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Already Added', message: opt.label + ' is already connected.', variant: 'warning' }));
            return;
        }

        // Use the actual lookup field from schema describe (not guessed from object name)
        const childObjName = opt.childObjectApiName;
        const lookupField = opt.lookupField || this._guessLookupField(parentNode.objectApiName, relName);
        const newNode = this._createNode(childObjName, opt.label, false, this.addNodeParentId,
            lookupField, relName);

        this.showAddNodeModal = false;
        this.treeNodes = [...this.treeNodes, newNode];
        this.activeNodeId = newNode.id;
        this._loadNodeFields(newNode);
        this._notifyChange();
        // Force a re-render after modal close to ensure tabs and tree update
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.treeNodes = [...this.treeNodes]; }, 0);
    }

    _guessLookupField(parentObjectName) {
        // Common patterns: Account → AccountId, Opportunity → OpportunityId
        // Custom objects: MyObj__c → MyObj__c (lookup field)
        // For standard objects, the lookup field is typically ParentObjectName + 'Id'
        if (parentObjectName.endsWith('__c')) {
            return parentObjectName; // Custom: the lookup IS the object name
        }
        return parentObjectName + 'Id';
    }

    handleRemoveNode(event) {
        const nodeId = event.currentTarget.dataset.nodeId;
        // Remove this node and all its descendants
        const toRemove = new Set();
        const collectDescendants = (id) => {
            toRemove.add(id);
            this.treeNodes.filter(n => n.parentNodeId === id).forEach(n => collectDescendants(n.id));
        };
        collectDescendants(nodeId);
        this.treeNodes = this.treeNodes.filter(n => !toRemove.has(n.id));
        if (toRemove.has(this.activeNodeId)) {
            this.activeNodeId = this.rootNode ? this.rootNode.id : null;
        }
        this._notifyChange();
    }

    // === FIELD SELECTION ===

    @track showSelectedOnly = false;

    handleFieldChange(event) {
        const node = this.activeNode;
        if (node) {
            // Preserve selections that are hidden by the current filter
            const visibleValues = new Set(node.filteredFields.map(f => f.value));
            const hiddenSelections = node.selectedFields.filter(f => !visibleValues.has(f));
            node.selectedFields = [...hiddenSelections, ...event.detail.value];
            this.treeNodes = [...this.treeNodes];
            this._notifyChange();
        }
    }

    handleFieldSearch(event) {
        const node = this.activeNode;
        if (node) {
            const search = event.target.value.toLowerCase();
            node.filteredFields = this._applyFieldFilter(node, search);
            this.treeNodes = [...this.treeNodes];
        }
    }

    handleToggleShowSelected() {
        this.showSelectedOnly = !this.showSelectedOnly;
        const node = this.activeNode;
        if (node) {
            node.filteredFields = this._applyFieldFilter(node, this._currentSearch);
            this.treeNodes = [...this.treeNodes];
        }
    }

    get showSelectedLabel() {
        return this.showSelectedOnly ? 'Show All' : 'Show Selected';
    }

    _currentSearch = '';

    _applyFieldFilter(node, search) {
        this._currentSearch = search || '';
        let fields = node.availableFields;
        if (search) {
            fields = fields.filter(f => f.label.toLowerCase().includes(search));
        }
        if (this.showSelectedOnly) {
            const selected = new Set(node.selectedFields);
            fields = fields.filter(f => selected.has(f.value));
        }
        return fields.slice(0, 200);
    }

    handleSelectAll() {
        const node = this.activeNode;
        if (node) {
            const visibleVals = node.filteredFields.map(f => f.value);
            const visibleSet = new Set(visibleVals);
            const current = new Set(node.selectedFields);
            const allVisibleSelected = visibleVals.every(v => current.has(v));

            if (allVisibleSelected) {
                // Deselect only visible fields, keep hidden selections
                node.selectedFields = node.selectedFields.filter(f => !visibleSet.has(f));
            } else {
                // Add all visible fields, keep hidden selections
                const hiddenSelections = node.selectedFields.filter(f => !visibleSet.has(f));
                node.selectedFields = [...hiddenSelections, ...visibleVals];
            }
            this.treeNodes = [...this.treeNodes];
            this._notifyChange();
        }
    }

    handleWhereChange(event) {
        const node = this.activeNode;
        if (node) { node.whereClause = event.detail.value; this._notifyChange(); }
    }
    handleOrderChange(event) {
        const node = this.activeNode;
        if (node) { node.orderByClause = event.detail.value; this._notifyChange(); }
    }
    handleLimitChange(event) {
        const node = this.activeNode;
        if (node) { node.limitClause = event.detail.value; this._notifyChange(); }
    }

    // === REPORT IMPORT ===
    handleOpenReportImport() {
        this.showReportModal = true;
        this.reportSearchResults = [];
        this.reportSearchTerm = '';
        this.selectedReportId = null;
        this.selectedReportName = '';
        this.showImportPreview = false;
        this._searchReports('');
    }
    handleCloseReportModal() { this.showReportModal = false; this.showImportPreview = false; }
    handleReportSearch(event) {
        const term = event.target.value;
        this.reportSearchTerm = term;
        clearTimeout(this._reportSearchTimeout);
        this._reportSearchTimeout = setTimeout(() => this._searchReports(term), 300);
    }
    _searchReports(term) {
        getAvailableReports({ searchTerm: term })
            .then(data => {
                this.reportSearchResults = data.map(r => ({
                    ...r,
                    isSelected: r.id === this.selectedReportId,
                    optionClass: 'slds-media slds-listbox__option slds-listbox__option_plain slds-media_small' +
                        (r.id === this.selectedReportId ? ' slds-theme_shade' : '')
                }));
            })
            .catch(() => { this.reportSearchResults = []; });
    }
    handleReportSelect(event) {
        this.selectedReportId = event.currentTarget.dataset.id;
        this.selectedReportName = event.currentTarget.dataset.name;
        this.reportSearchResults = this.reportSearchResults.map(r => ({
            ...r,
            isSelected: r.id === this.selectedReportId,
            optionClass: 'slds-media slds-listbox__option slds-listbox__option_plain slds-media_small' +
                (r.id === this.selectedReportId ? ' slds-theme_shade' : '')
        }));
    }
    get isImportDisabled() { return !this.selectedReportId || this.isImportingReport; }

    handleImportReport() {
        if (!this.selectedReportId) return;
        this.isImportingReport = true;
        importReportConfig({ reportId: this.selectedReportId })
            .then(result => {
                this.importPreviewData = result;
                this.showImportPreview = true;
                this.isImportingReport = false;
            })
            .catch(error => {
                this.dispatchEvent(new ShowToastEvent({ title: 'Import Failed', message: error.body ? error.body.message : error.message, variant: 'error' }));
                this.isImportingReport = false;
            });
    }

    handleConfirmImport() {
        const result = this.importPreviewData;
        if (!result) return;
        this.showReportModal = false;
        this.showImportPreview = false;
        this.selectedObject = result.baseObject;
        const objOpt = this.objectOptions.find(o => o.value === result.baseObject);
        this.selectedObjectLabel = objOpt ? objOpt.label : result.baseObject;

        // Build tree nodes from import result
        const rootNode = this._createNode(result.baseObject, this.selectedObjectLabel, true, null, null, null);
        this.treeNodes = [rootNode];
        this.activeNodeId = rootNode.id;

        // Load root fields and auto-check imported ones
        getObjectFields({ objectName: result.baseObject }).then(data => {
            rootNode.availableFields = data;
            rootNode.filteredFields = data.slice(0, 200);
            const valid = new Set(data.map(f => f.value));
            rootNode.selectedFields = (result.fields || []).filter(f => valid.has(f));
            if (result.parentFields && result.parentFields.length > 0) {
                const groups = {};
                for (const pf of result.parentFields) {
                    const parts = pf.split('.');
                    const rel = parts[0];
                    const field = parts.slice(1).join('.');
                    if (!groups[rel]) groups[rel] = { relationshipName: rel, fields: [] };
                    groups[rel].fields.push(field);
                }
                rootNode.parentGroups = Object.values(groups);
            }
            this.treeNodes = [...this.treeNodes];
            this._notifyChange();
        });

        // Add child nodes from import using hierarchy info
        if (result.childFields && result.childHierarchy) {
            const hierarchy = result.childHierarchy;
            const nodesByObject = { [result.baseObject]: rootNode };

            // Sort: process parents before children (direct children first, then grandchildren)
            const sortedRels = Object.keys(result.childFields).sort((a, b) => {
                const aParent = hierarchy[a] ? hierarchy[a].parentObject : result.baseObject;
                const bParent = hierarchy[b] ? hierarchy[b].parentObject : result.baseObject;
                // Base-level children first
                if (aParent === result.baseObject && bParent !== result.baseObject) return -1;
                if (bParent === result.baseObject && aParent !== result.baseObject) return 1;
                return 0;
            });

            // Process each relationship in order
            const processRel = (relIdx) => {
                if (relIdx >= sortedRels.length) {
                    this._notifyChange();
                    return;
                }

                const relName = sortedRels[relIdx];
                const fields = result.childFields[relName];

                if (relName.startsWith('__junction_')) {
                    // Junction: create a child node for the junction object (e.g., OpportunityContactRole)
                    // with target object fields as parent fields (e.g., Contact.FirstName)
                    const targetObjName = relName.replace('__junction_', '').split(':')[0];
                    let jInfo = null;
                    if (result.junctions) {
                        jInfo = result.junctions.find(j => j.targetObject === targetObjName);
                    }
                    const junctionRel = jInfo ? (jInfo.junctionRel || '') : '';
                    const junctionObjName = jInfo ? (jInfo.junctionObject || junctionRel.replace(/s$/, '')) : junctionRel.replace(/s$/, '');
                    const baseLookupField = jInfo ? (jInfo.baseLookupField || result.baseObject + 'Id') : result.baseObject + 'Id';
                    const targetRelName = jInfo ? (jInfo.targetRelName || targetObjName) : targetObjName;

                    // Create node for the junction object as a regular child
                    const junctionNode = this._createNode(junctionObjName,
                        junctionObjName + ' (' + junctionRel + ')',
                        false, rootNode.id, baseLookupField, junctionRel);

                    // Convert target fields to parent fields: FirstName → Contact.FirstName
                    junctionNode.parentGroups = [{
                        relationshipName: targetRelName,
                        fields: [...fields]
                    }];

                    getObjectFields({ objectName: junctionObjName }).then(fieldData => {
                        junctionNode.availableFields = fieldData;
                        junctionNode.filteredFields = fieldData.slice(0, 200);
                        junctionNode.selectedFields = []; // No direct fields, only parent fields
                        this.treeNodes = [...this.treeNodes, junctionNode];
                        processRel(relIdx + 1);
                    }).catch(() => processRel(relIdx + 1));
                    return;
                }

                // Use hierarchy to find the correct parent and lookup field
                const hInfo = hierarchy[relName];
                const objName = hInfo ? hInfo.objectName : relName;
                const parentObjName = hInfo ? hInfo.parentObject : result.baseObject;
                const lookupField = hInfo ? hInfo.lookupField : this._guessLookupField(result.baseObject, relName);

                // Find the parent node (might be the root or another child)
                const parentNode = nodesByObject[parentObjName] || rootNode;

                const childNode = this._createNode(objName, objName, false,
                    parentNode.id, lookupField, relName);
                nodesByObject[objName] = childNode;

                getObjectFields({ objectName: objName }).then(fieldData => {
                    childNode.availableFields = fieldData;
                    childNode.filteredFields = fieldData.slice(0, 200);
                    const valid = new Set(fieldData.map(f => f.value));
                    childNode.selectedFields = fields.filter(f => valid.has(f));
                    this.treeNodes = [...this.treeNodes, childNode];
                    processRel(relIdx + 1);
                }).catch(() => processRel(relIdx + 1));
            };

            processRel(0);
        } else if (result.childFields) {
            // Fallback: no hierarchy info, treat all as direct children
            for (const relName of Object.keys(result.childFields)) {
                if (relName.startsWith('__junction_')) continue;
                const fields = result.childFields[relName];
                const childNode = this._createNode(relName, relName, false,
                    rootNode.id, this._guessLookupField(result.baseObject, relName), relName);
                getObjectFields({ objectName: relName }).then(fieldData => {
                    childNode.availableFields = fieldData;
                    childNode.filteredFields = fieldData.slice(0, 200);
                    const valid = new Set(fieldData.map(f => f.value));
                    childNode.selectedFields = fields.filter(f => valid.has(f));
                    this.treeNodes = [...this.treeNodes, childNode];
                    this._notifyChange();
                }).catch(() => {});
            }
        }

        // Trigger a notifyChange so the config includes fields immediately
        this._notifyChange();

        let toastMsg = result.fieldCount + ' fields from "' + result.reportName + '" applied.';
        this.dispatchEvent(new ShowToastEvent({
            title: 'Report Imported',
            message: toastMsg,
            variant: 'success'
        }));
    }

    // === CONFIG PARSING ===
    _parseConfig(value) {
        if (!value) return;
        const trimmed = value.trim();
        if (trimmed.startsWith('{')) {
            try {
                const config = JSON.parse(trimmed);
                const version = config.v || 2;
                if (version === 4 && config.provider) {
                    this._parseV4Config(config);
                    return;
                } else if (version >= 3 && config.nodes) {
                    this._parseV3Config(config);
                } else if (version === 2 && config.baseObject) {
                    this._parseV2Config(config);
                }
            } catch { /* ignore parse errors for non-JSON */ }
        } else if (trimmed.length > 0) {
            // V1 flat string — parse field list and subqueries
            this._parseV1Config(trimmed);
        }
    }

    _parseV1Config(value) {
        if (!this.selectedObject) return;
        // V1: "Name, Industry, (SELECT FirstName, LastName FROM Contacts)"
        const fields = [];
        const children = [];
        let remaining = value;

        // Extract subqueries first
        const subqRegex = /\(\s*SELECT\s+(.+?)\s+FROM\s+(\w+)\s*\)/gi;
        let match;
        while ((match = subqRegex.exec(value)) !== null) {
            const childFields = match[1].split(',').map(f => f.trim()).filter(f => f);
            children.push({ rel: match[2], fields: childFields });
        }
        remaining = remaining.replace(subqRegex, '').replace(/,\s*,/g, ',').replace(/^\s*,|,\s*$/g, '');

        // Parse base fields
        remaining.split(',').forEach(f => {
            const field = f.trim();
            if (field) fields.push(field);
        });

        // Build tree
        const rootNode = this._createNode(this.selectedObject, this.selectedObject, true, null, null, null);
        rootNode.selectedFields = fields;
        const nodes = [rootNode];
        this._loadNodeFields(rootNode);

        for (const child of children) {
            const childNode = this._createNode(child.rel, child.rel, false, rootNode.id, null, child.rel);
            childNode.selectedFields = child.fields;
            nodes.push(childNode);
            this._loadNodeFields(childNode);
        }

        this.treeNodes = nodes;
        this.activeNodeId = rootNode.id;
    }

    _parseV2Config(config) {
        const objName = config.baseObject;
        if (!objName) return;
        this.selectedObject = objName;

        const rootNode = this._createNode(objName, objName, true, null, null, null);
        rootNode.selectedFields = config.baseFields || [];
        if (config.parentFields && config.parentFields.length > 0) {
            const groups = {};
            for (const pf of config.parentFields) {
                const parts = pf.split('.');
                const rel = parts[0];
                const field = parts.slice(1).join('.');
                if (!groups[rel]) groups[rel] = { relationshipName: rel, fields: [] };
                groups[rel].fields.push(field);
            }
            rootNode.parentGroups = Object.values(groups);
        }
        const nodes = [rootNode];
        this._loadNodeFields(rootNode);

        // Children
        if (config.children) {
            for (const child of config.children) {
                const childNode = this._createNode(child.rel, child.rel, false, rootNode.id, null, child.rel);
                childNode.selectedFields = child.fields || [];
                nodes.push(childNode);
                this._loadNodeFields(childNode);
            }
        }

        // Junctions
        if (config.junctions) {
            for (const junc of config.junctions) {
                const juncNode = this._createNode(junc.junctionRel, junc.junctionRel, false, rootNode.id, null, junc.junctionRel, {
                    targetObject: junc.targetObject,
                    targetIdField: junc.targetIdField,
                    targetFields: junc.targetFields || []
                });
                juncNode.selectedFields = junc.junctionFields || [];
                nodes.push(juncNode);
                this._loadNodeFields(juncNode);
            }
        }

        this.treeNodes = nodes;
        this.activeNodeId = rootNode.id;

        if (config.bulkWhereClause) {
            this.savedReportFilters = config.bulkWhereClause;
        }
    }

    _parseV4Config(config) {
        this.isApexProviderMode = true;
        this.selectedProvider = config.provider;
        this.providerSearchTerm = config.provider;
        // Validate and load fields
        validateDataProvider({ className: config.provider })
            .then(result => {
                if (result.valid) {
                    this.providerFields = result.fields || [];
                }
            })
            .catch(() => {});
    }

    _parseV3Config(config) {
        const nodes = [];
        for (const n of config.nodes) {
            const node = this._createNode(n.object, n.object, !n.parentNode, n.parentNode,
                n.lookupField, n.relationshipName, n.junction);
            node.id = n.id;
            node.selectedFields = n.fields || [];
            node.whereClause = n.where || '';
            node.orderByClause = n.orderBy || '';
            node.limitClause = n.limit || '';
            if (n.parentFields && n.parentFields.length > 0) {
                const groups = {};
                for (const pf of n.parentFields) {
                    const parts = pf.split('.');
                    const rel = parts[0];
                    const field = parts.slice(1).join('.');
                    if (!groups[rel]) groups[rel] = { relationshipName: rel, fields: [] };
                    groups[rel].fields.push(field);
                }
                node.parentGroups = Object.values(groups);
            }
            nodes.push(node);
            this._loadNodeFields(node);
        }
        this.treeNodes = nodes;
        this.activeNodeId = nodes.length > 0 ? nodes[0].id : null;
        this.selectedObject = config.root;
    }

    // === NOTIFY PARENT ===
    _notifyChange() {
        const config = this.generatedConfig;
        this._lastEmittedConfig = config;
        this.dispatchEvent(new CustomEvent('configchange', {
            detail: {
                objectName: this.selectedObject,
                queryConfig: config
            }
        }));
    }
}
