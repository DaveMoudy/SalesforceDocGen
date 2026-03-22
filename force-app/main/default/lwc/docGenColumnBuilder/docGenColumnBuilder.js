import { LightningElement, wire, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectOptions from '@salesforce/apex/DocGenController.getObjectOptions';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getParentRelationships from '@salesforce/apex/DocGenController.getParentRelationships';
import getAvailableReports from '@salesforce/apex/DocGenController.getAvailableReports';
import importReportConfig from '@salesforce/apex/DocGenController.importReportConfig';

let _nodeId = 0;
function nextNodeId() { return 'n' + (_nodeId++); }

export default class DocGenColumnBuilder extends LightningElement {

    // === PUBLIC API ===
    @api selectedObject = '';
    @api
    get queryConfig() { return this._queryConfig; }
    set queryConfig(value) {
        this._queryConfig = value;
        if (value) this._parseConfig(value);
    }
    _queryConfig = '';

    // === CORE STATE: Tree Nodes ===
    @track treeNodes = [];
    @track activeNodeId = null;

    // === UI STATE ===
    @track objectOptions = [];
    @track isLoaded = false;
    @track showObjectPicker = false;
    @track objectSearchTerm = '';
    @track selectedObjectLabel = '';

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
            if (this.selectedObject && this.treeNodes.length === 0) {
                const opt = data.find(o => o.value === this.selectedObject);
                this.selectedObjectLabel = opt ? opt.label : this.selectedObject;
                this._initRootNode(this.selectedObject, this.selectedObjectLabel);
            }
        }
    }

    // === COMPUTED ===
    get hasNodes() { return this.treeNodes.length > 0; }
    get rootNode() { return this.treeNodes.find(n => !n.parentNodeId); }
    get activeNode() { return this.treeNodes.find(n => n.id === this.activeNodeId); }
    get showObjectSelector() { return !this.selectedObject && !this.hasNodes; }

    get filteredObjectOptions() {
        const term = (this.objectSearchTerm || '').toLowerCase();
        if (term.length < 2) return []; // Don't show until at least 2 chars typed
        return this.objectOptions.filter(o => o.label.toLowerCase().includes(term)).slice(0, 20);
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
            badgeLabel: node.isRoot ? 'Root' : node.isJunction ? 'Linked' : 'Related',
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
        return JSON.stringify(config);
    }

    // === OBJECT SELECTION ===
    handleObjectSearch(event) {
        this.objectSearchTerm = event.target.value;
        this.showObjectPicker = this.objectSearchTerm.length >= 2;
    }
    handleObjectFocus() {
        // Only show if we already have search results
        if (this.objectSearchTerm.length >= 2) this.showObjectPicker = true;
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

        getObjectFields({ objectName: targetObj })
            .then(data => {
                this.parentPickerFieldOptions = data;
                this.parentPickerRelSelected = true;
            });
    }

    handleParentPickerBack() {
        this.parentPickerRelSelected = false;
    }

    handleParentPickerFieldChange(event) {
        this.parentPickerSelectedFields = event.detail.value;
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

    handleChangeRoot() {
        // Reset everything — go back to object selector
        this.treeNodes = [];
        this.activeNodeId = null;
        this.selectedObject = '';
        this.selectedObjectLabel = '';
        this.objectSearchTerm = '';
        this._notifyChange();
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
        return {
            id: nextNodeId(),
            objectApiName,
            label: label || objectApiName,
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
    }

    handleTreeNodeClick(event) {
        this.activeNodeId = event.currentTarget.dataset.nodeId;
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

        // Determine lookup field — it's the field on the child object that points to the parent
        // For child relationships, the field name follows a pattern based on the parent object
        const childObjName = opt.childObjectApiName;
        const newNode = this._createNode(childObjName, opt.label, false, this.addNodeParentId,
            this._guessLookupField(parentNode.objectApiName, relName), relName);

        this.treeNodes = [...this.treeNodes, newNode];
        this.activeNodeId = newNode.id;
        this.showAddNodeModal = false;
        this._loadNodeFields(newNode);
        this._notifyChange();
    }

    _guessLookupField(parentObjectName, relationshipName) {
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
    handleFieldChange(event) {
        const node = this.activeNode;
        if (node) {
            node.selectedFields = event.detail.value;
            this.treeNodes = [...this.treeNodes];
            this._notifyChange();
        }
    }

    handleFieldSearch(event) {
        const node = this.activeNode;
        if (node) {
            const search = event.target.value.toLowerCase();
            node.filteredFields = node.availableFields.filter(f =>
                f.label.toLowerCase().includes(search)
            ).slice(0, 200);
            this.treeNodes = [...this.treeNodes];
        }
    }

    handleSelectAll() {
        const node = this.activeNode;
        if (node) {
            const allVals = node.filteredFields.map(f => f.value);
            const current = new Set(node.selectedFields);
            const allSelected = allVals.every(v => current.has(v));
            node.selectedFields = allSelected ? [] : allVals;
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

        // Add child nodes from import
        if (result.childFields) {
            for (const relName of Object.keys(result.childFields)) {
                if (relName.startsWith('__junction_')) continue;
                const fields = result.childFields[relName];
                getChildRelationships({ objectName: result.baseObject }).then(rels => {
                    const rel = rels.find(r => r.value === relName);
                    if (rel) {
                        const childNode = this._createNode(rel.childObjectApiName, rel.label, false,
                            rootNode.id, this._guessLookupField(result.baseObject, relName), relName);
                        getObjectFields({ objectName: rel.childObjectApiName }).then(fieldData => {
                            childNode.availableFields = fieldData;
                            childNode.filteredFields = fieldData.slice(0, 200);
                            const validChild = new Set(fieldData.map(f => f.value));
                            childNode.selectedFields = fields.filter(f => validChild.has(f));
                            this.treeNodes = [...this.treeNodes, childNode];
                            this._notifyChange();
                        });
                    }
                });
            }
        }

        this.dispatchEvent(new ShowToastEvent({
            title: 'Report Imported',
            message: 'Fields from "' + result.reportName + '" applied.',
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
                if (version >= 3 && config.nodes) {
                    this._parseV3Config(config);
                }
            } catch (e) { /* ignore parse errors for non-JSON */ }
        }
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
        this.dispatchEvent(new CustomEvent('configchange', {
            detail: {
                objectName: this.selectedObject,
                queryConfig: this.generatedConfig
            }
        }));
    }
}
