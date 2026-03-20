import { LightningElement, wire, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectOptions from '@salesforce/apex/DocGenController.getObjectOptions';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getParentRelationships from '@salesforce/apex/DocGenController.getParentRelationships';
import previewRecordData from '@salesforce/apex/DocGenController.previewRecordData';
import getBuilderLimits from '@salesforce/apex/DocGenSetupController.getBuilderLimits';
import { refreshApex } from '@salesforce/apex';

// Fallback defaults if custom setting has no value
const DEFAULT_MAX_PARENT_FIELDS = 10;
const DEFAULT_MAX_CHILD_LISTS = 5;

export default class DocGenQueryBuilder extends LightningElement {
    @track objectOptions = [];
    @track _fieldOptions = []; // Internal raw list
    // @track fieldOptions = []; // Removed in favor of filtered
    @track filteredFieldOptions = [];
    @track childOptions = [];
    @track parentOptions = []; // New
    
    @api selectedObject;
    @track selectedObjectLabel = '';
    
    @track baseFieldSelection = [];
    @track parentFieldSelection = [];
    
    @track selectedFields = [];
    
    // Child Configs
    @track childConfigs = []; 
    
    // Search & UI State
    @track showObjectDropdown = false;
    @track filteredObjectOptions = [];
    
    @track selectedChildRel;
    @track selectedChildLabel = '';
    @track showChildDropdown = false;
    @track filteredChildOptions = [];

    // Parent Field State
    @track selectedParentRel;
    @track selectedParentLabel = '';
    @track showParentDropdown = false;
    @track filteredParentOptions = [];
    
    @track parentFieldOptions = [];
    @track selectedParentField;
    @track selectedParentFieldLabel = '';
    @track showParentFieldDropdown = false;
    @track filteredParentFieldOptions = [];

    // --- Dynamic Limits (from DocGen_Settings__c) ---
    maxParentFields = DEFAULT_MAX_PARENT_FIELDS;
    maxChildLists = DEFAULT_MAX_CHILD_LISTS;

    @wire(getBuilderLimits)
    wiredLimits({ error, data }) {
        if (data) {
            this.maxParentFields = data.maxParentFields || DEFAULT_MAX_PARENT_FIELDS;
            this.maxChildLists = data.maxChildLists || DEFAULT_MAX_CHILD_LISTS;
        } else if (error) {
            // Fallback to defaults silently
            this.maxParentFields = DEFAULT_MAX_PARENT_FIELDS;
            this.maxChildLists = DEFAULT_MAX_CHILD_LISTS;
        }
    }

    // --- New Mode ---
    @api showTagsOnly = false;

    // --- Layout Getters ---
    get mainColumnClass() { 
        return this.showTagsOnly ? 'slds-hide' : 'slds-col slds-size_2-of-3';
    }
    
    get tagsColumnClass() {
        return this.showTagsOnly ? 'slds-col slds-size_1-of-1' : 'slds-col slds-size_1-of-3';
    }

    // --- Search & Select All ---
    handleSelectAll() {
        if (!this._fieldOptions) return;
        if (this._isAllSelected) {
            this.baseFieldSelection = [];
        } else {
            this.baseFieldSelection = this._fieldOptions.map(opt => opt.value);
        }
        this.updateCombinedSelection();
    }

    get _isAllSelected() {
        return this._fieldOptions && this._fieldOptions.length > 0
            && this.baseFieldSelection.length === this._fieldOptions.length;
    }

    get selectAllLabel() {
        return this._isAllSelected ? 'Deselect All' : 'Select All';
    }

    get isSelectAllDisabled() {
        return !this._fieldOptions || this._fieldOptions.length === 0;
    }

    // --- Copy Logic ---
    async handleCopyTag(event) {
        event.preventDefault();
        const tag = event.currentTarget.dataset.tag;
        if (tag) {
            try {
                await this._copyToClipboard(tag);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Copied',
                        message: `Tag ${tag} copied to clipboard.`,
                        variant: 'success',
                    })
                );
            } catch (_err) {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Copy Failed',
                        message: 'Unable to copy to clipboard.',
                        variant: 'error',
                    })
                );
            }
        }
    }

    _copyToClipboard(text) {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        }
        // Fallback for non-secure contexts (e.g. Lightning iframes)
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

    // --- Wiring ---

    @api
    get queryConfig() {
        return this._queryConfig;
    }
    set queryConfig(value) {
        this._queryConfig = value;
        // Parsing should always attempt to run if we have a value.
        // Internal guards in parseConfig will handle missing dependencies (like childOptions).
        if (value) {
            this.parseConfig(value);
        }
    }
    _queryConfig = '';

    // If options load after config is set
    get objectFieldLabel() {
        return (this.selectedObject || 'Base') + ' Fields';
    }

    @wire(getObjectOptions)
    wiredOptions({ error, data }) {
        if (data) {
            this.objectOptions = data;
            this.filteredObjectOptions = data;
            if (this.selectedObject) {
                const found = this.objectOptions.find(o => o.value === this.selectedObject);
                if (found) this.selectedObjectLabel = found.label;
            }
            // Parse if config is waiting
            if (this._queryConfig) {
                this.parseConfig(this._queryConfig);
            }
        } else if (error) {
        }
    }

    // --- Field Logic ---
    
    @track isLoadingFields = false;
    fieldSearchKey = '';
    @track showSelectedOnly = false; // New

    @wire(getObjectFields, { objectName: '$selectedObject' })
    wiredFields({ error, data }) {
        this.isLoadingFields = true;
        if (data) {
            this._fieldOptions = data;
            this.filterFields();
        } else if (error) {
            this._fieldOptions = [];
            this.filteredFieldOptions = [];
        }
        this.isLoadingFields = false;
    }
    
    handleFieldSearch(event) {
        window.clearTimeout(this.delayTimeout);
        const searchKey = event.target.value;
        this.delayTimeout = window.setTimeout(() => {
            this.fieldSearchKey = searchKey;
            this.filterFields();
        }, 300);
    }
    
    handleToggleSelectedOnly(event) {
        this.showSelectedOnly = event.target.checked;
        this.filterFields();
        // Also refresh all children
        if (this.childConfigs) {
            this.childConfigs.forEach((c, index) => {
                this.filterChildFields(index, ''); // Refresh with current search/toggle
            });
        }
    }
    
    filterFields() {
        let optionsToShow = [];
        
        let sourceOptions = this._fieldOptions;
        
        // 1. Filter by Selected Only
        if (this.showSelectedOnly) {
             sourceOptions = sourceOptions.filter(opt => this.baseFieldSelection.includes(opt.value));
        }

        if (!this.fieldSearchKey) {
            // "Super slow" fix: Limit to 200
            optionsToShow = sourceOptions.slice(0, 200);
        } else {
            const key = this.fieldSearchKey.toLowerCase();
            optionsToShow = sourceOptions.filter(opt => 
                opt.label.toLowerCase().includes(key) || 
                opt.value.toLowerCase().includes(key)
            );
            // Slice the search results too if massive? Maybe 500?
            optionsToShow = optionsToShow.slice(0, 500); 
        }

        // CRITICAL: Ensure currently selected fields are ALWAYS in the options
        // even if they fall outside the slice/search (though search should find them).
        // Main use case: Initial load where slicing hides selected fields.
        // BUT if showSelectedOnly is true, they are already filtered to only selected, so this is fine.
        if (this.selectedFields && this.selectedFields.length > 0) {
            const selectedSet = new Set(this.selectedFields);
            const visibleSet = new Set(optionsToShow.map(o => o.value));
            
            // Find missing selected options
            // Only add them if NOT in showSelectedOnly mode (because if in showSelectedOnly, we already included them above)
            // Actually, baseFieldSelection logic above covers base fields. 
            // Parent fields in selectedFields are NOT in _fieldOptions.
            
            const missingOptions = this._fieldOptions.filter(o => 
                selectedSet.has(o.value) && !visibleSet.has(o.value)
            );
            
            // If showSelectedOnly is ON, we technically have all selected base fields. 
            // If showSelectedOnly is OFF, we need to enforce visibility.
            if (!this.showSelectedOnly && missingOptions.length > 0) {
                optionsToShow = [...optionsToShow, ...missingOptions];
            }
        }
        
        this.filteredFieldOptions = optionsToShow;
    }

    handleFieldChange(event) {
        this.baseFieldSelection = event.detail.value;
        this.updateCombinedSelection();
    }
    
    updateCombinedSelection() {
        this.selectedFields = [...this.baseFieldSelection, ...this.parentFieldSelection];
        this.notifyChange();
    }

    // Pending subqueries from parseConfig that couldn't be built yet (childOptions not loaded)
    _pendingSubqueries = null;
    // Suppress notifyChange during parseConfig to avoid emitting incomplete queries
    _isParsing = false;

    @wire(getChildRelationships, { objectName: '$selectedObject' })
    wiredChildren({ error, data }) {
        if (data) {
            this.childOptions = data;
            this.filteredChildOptions = data;
            // If we have pending subqueries from an earlier parseConfig call, rebuild now
            if (this._pendingSubqueries && this._pendingSubqueries.length > 0) {
                this.rebuildChildConfigs(this._pendingSubqueries);
                this._pendingSubqueries = null;
            } else if (this._queryConfig && this.childConfigs.length === 0) {
                this.parseConfig(this._queryConfig);
            }
        } else if (error) {
            this.childOptions = [];
        }
    }
    
    @wire(getParentRelationships, { objectName: '$selectedObject' })
    wiredParents({ error, data }) {
        if (data) {
            this.parentOptions = data;
            this.filteredParentOptions = data;
        } else if (error) {
             this.parentOptions = [];
        }
    }
    
    // ... (rest of wire methods)

    // --- Parser ---
    
    // --- Parser ---
    
    parseConfig(queryStr) {
        if (!queryStr) return;
        this._isParsing = true;

        // 1. Extract Subqueries (Nested Parentheses Handling is tricky with Regex, assuming standard SOQL)
        // Match: (SELECT ... FROM ...)
        // We use a non-greedy match for the content to allow multiple subqueries
        const subqueryRegex = /\(\s*SELECT\s+([\s\S]+?)\s+FROM\s+([\s\S]+?)\s*\)/gi;
        
        let match;
        const subqueries = [];
        const fullMatches = []; // To remove them from base string later
        
        while ((match = subqueryRegex.exec(queryStr)) !== null) {
            fullMatches.push(match[0]);
            
            const fieldsStr = match[1];
            const tailStr = match[2].trim(); // Relationship + Clauses
            
            // Parse Tail: Relationship [WHERE ...] [ORDER BY ...] [LIMIT ...]
            // Regex identifying tokens. 
            // NOTE: SOQL sequence is FROM -> WHERE -> WITH -> GROUP BY -> ORDER BY -> LIMIT
            // We only care about WHERE, ORDER BY, LIMIT
            
            // Simple approach: Split by keywords? Or regex extraction.
            // Relationship is the first word.
            const relationshipMatch = tailStr.match(/^(\w+)/);
            if (!relationshipMatch) continue;
            
            const relationshipName = relationshipMatch[1];
            let clauses = tailStr.substring(relationshipName.length).trim();
            
            let whereClause = '';
            let orderBy = '';
            let limitAmount = '';
            
            // Extract LIMIT (Last)
            const limitMatch = clauses.match(/\s+LIMIT\s+(\d+)$/i);
            if (limitMatch) {
                limitAmount = limitMatch[1];
                clauses = clauses.substring(0, clauses.length - limitMatch[0].length).trim();
            }
            
            // Extract ORDER BY (Before LIMIT)
            const orderMatch = clauses.match(/\s+ORDER\s+BY\s+(.+)$/i);
            if (orderMatch) {
                orderBy = orderMatch[1];
                clauses = clauses.substring(0, clauses.length - orderMatch[0].length).trim();
            }
            
            // Extract WHERE (Remaining)
            const whereMatch = clauses.match(/\s*WHERE\s+(.+)$/i);
            if (whereMatch) {
                 whereClause = whereMatch[1];
            }
            
            subqueries.push({
                relationshipName: relationshipName,
                fields: fieldsStr.split(',').map(s => s.trim()),
                whereClause: whereClause,
                orderBy: orderBy,
                limitAmount: limitAmount
            });
        }
        
        // 2. Base Fields
        // Remove all subquery blocks to get base fields
        let baseFieldsStr = queryStr;
        fullMatches.forEach(m => {
            baseFieldsStr = baseFieldsStr.replace(m, ''); 
        });
        
        // Cleanup commas left behind "Name, , Industry" if subquery was in middle
        const allFlatFields = baseFieldsStr.split(',')
            .map(s => s.trim())
            .filter(s => s.length > 0 && !s.startsWith('('));
            
        // Distribute to Base vs Parent
        this.baseFieldSelection = [];
        this.parentFieldSelection = [];
        
        allFlatFields.forEach(f => {
            if (f.includes('.')) {
                this.parentFieldSelection.push(f);
            } else {
                this.baseFieldSelection.push(f);
            }
        });
        
        this.updateCombinedSelection();
            
        if (this._fieldOptions.length > 0) {
            this.filterFields();
        }
            
        // 3. Child Configs
        if (subqueries.length > 0) {
            if (this.childOptions.length === 0) {
                // childOptions wire hasn't loaded yet — store for later
                this._pendingSubqueries = subqueries;
            } else {
                this._pendingSubqueries = null;
                this.rebuildChildConfigs(subqueries);
                // _isParsing cleared inside rebuildChildConfigs after async work
            }
        } else {
            this._isParsing = false;
        }

        // Force tags refresh
        this.selectedFields = [...this.selectedFields];
    }
    
    rebuildChildConfigs(subqueries) {
        // Build all child configs atomically using Promise.all to avoid race conditions
        const promises = subqueries.map(sub => {
            const relOption = this.childOptions.find(opt => opt.value === sub.relationshipName);
            if (!relOption) return Promise.resolve(null);

            const childObjName = relOption.childObjectApiName;

            return getObjectFields({ objectName: childObjName })
                .then(data => ({
                    relationshipName: sub.relationshipName,
                    childObjectApiName: childObjName,
                    selectedFields: sub.selectedFields || sub.fields,
                    whereClause: sub.whereClause || '',
                    orderBy: sub.orderBy || '',
                    limitAmount: sub.limitAmount || '',
                    availableFields: data,
                    filteredFields: data.slice(0, 200)
                }))
                .catch(() => null);
        });

        Promise.all(promises).then(results => {
            this.childConfigs = results.filter(r => r !== null);
            // Force reactivity refresh for tags
            this.selectedFields = [...this.selectedFields];
            this._isParsing = false;
            this.notifyChange();
        });
    }
    
    // --- Tags Filtering ---
    @track tagsSearchKey = '';
    @track activeSections = ['Base', 'Parent', 'Children']; // Expand all by default? Or let them collapse.

    handleTagsSearch(event) {
        window.clearTimeout(this.tagsDelayTimeout);
        const searchKey = event.target.value.toLowerCase();
        this.tagsDelayTimeout = window.setTimeout(() => {
            this.tagsSearchKey = searchKey;
        }, 300);
    }
    
    get complexityWarning() {
        const warnings = [];
        
        // 1. Parent Fields Count
        if (this.parentFieldSelection.length >= this.maxParentFields) {
            warnings.push(`Maximum limit of ${this.maxParentFields} parent fields reached. You cannot add more.`);
        } else if (this.parentFieldSelection.length > Math.floor(this.maxParentFields * 0.9)) {
             warnings.push(`Approaching parent field limit (${this.parentFieldSelection.length}/${this.maxParentFields}).`);
        }

        // 2. Child Lists Count
        if (this.childConfigs.length >= this.maxChildLists) {
            warnings.push(`Maximum limit of ${this.maxChildLists} related lists reached. You cannot add more.`);
        }
        
        // 3. Total Fields
        const totalFields = this.selectedFields.length + this.childConfigs.reduce((acc, c) => acc + c.selectedFields.length, 0);
        if (totalFields > 60) {
             warnings.push(`Total field count is high (${totalFields}). Consider removing unused fields.`);
        }
        
        if (warnings.length > 0) {
            return {
                title: 'Limit & Performance Status',
                messages: warnings
            };
        }
        return null;
    }

    // --- Preview Data ---
    @api testRecordId;
    @track previewData = null;
    @track showRawData = false;

    handleToggleRawData() {
        this.showRawData = !this.showRawData;
    }

    @track previewError = null;

    @wire(previewRecordData, { 
        recordId: '$testRecordId', 
        baseObject: '$selectedObject', 
        queryConfig: '$queryConfig' 
    })
    wiredPreview(result) {
        this.previewResult = result; // Store for refresh
        const { error, data } = result;

        if (data) {
            this.previewData = this.flattenPreview(data);
            this.previewError = null;
        } else if (error) {
            this.previewData = null;
            this.previewError = error.body ? error.body.message : error.message;
        }
    }
    
    // Manual Refresh
    @api
    refreshPreview() {
        if (this.previewResult) {
            return refreshApex(this.previewResult);
        }
    }

    get rawPreviewJson() {
        if (this.previewError) return 'Error: ' + this.previewError;
        if (!this.previewData) return 'No data loaded. Select a test record.';
        return JSON.stringify(this.previewData, null, 2);
    }

    flattenPreview(data) {
        // reuse the same flatten logic as runner if possible, or simple version
        // We just need simple access. The runner flatten handles subqueries.
        // Let's implement a safe flatten here.
        if (!data) return {};
        // .. implementation similar to runner ..
        let flat = {};
        for (let key in data) {
            let val = data[key];
             if (val && typeof val === 'object' && val.records) {
                 flat[key] = val.records; // Keep array
             } else if (val && typeof val === 'object' && !Array.isArray(val)) {
                 flat[key] = val; // Nested object (Parent)
             } else {
                 flat[key] = val;
             }
        }
        return flat;
    }

    get generatedTags() {
        if (!this.selectedFields && !this.childConfigs) return null;

        const search = this.tagsSearchKey;
        const data = this.previewData || {};

        // 1. Base Fields
        let baseTags = this.baseFieldSelection.map(field => {
            let sampleVal = data[field];
            if (typeof sampleVal === 'object') sampleVal = JSON.stringify(sampleVal);
            return {
                label: field,
                code: `{${field}}`,
                sample: sampleVal
            };
        });
        
        if (search) {
            baseTags = baseTags.filter(t => t.label.toLowerCase().includes(search) || t.code.toLowerCase().includes(search));
        }
        
        const baseCopyAll = this.baseFieldSelection.map(f => `{${f}}`).join('\n');

        // 2. Parent Fields (Grouped)
        const parentGroups = {};
        this.parentFieldSelection.forEach(f => {
            const parts = f.split('.');
            const objName = parts[0];
            const fieldName = parts.slice(1).join('.'); 
            
            if (!parentGroups[objName]) parentGroups[objName] = [];
            
            // Sample resolution: data[objName][fieldName]
            let sampleVal = '';
            if (data[objName]) {
                 sampleVal = data[objName][fieldName];
            }
            
            parentGroups[objName].push({
                label: fieldName,
                code: `{${f}}`,
                sample: sampleVal
            });
        });
        
        let parentSections = Object.keys(parentGroups).sort().map(obj => {
            let fields = parentGroups[obj];
            const fullSectionCode = fields.map(t => t.code).join('\n');
            
            if (search) {
                fields = fields.filter(t => t.label.toLowerCase().includes(search) || t.code.toLowerCase().includes(search));
            }
            
            return {
                name: obj,
                fields: fields,
                copyAllText: fullSectionCode,
                isVisible: fields.length > 0
            };
        });
        
        if (search) {
            parentSections = parentSections.filter(s => s.isVisible);
        }

        // 3. Children
        let childTags = this.childConfigs.map(child => {
            const loopStart = `{#${child.relationshipName}}`;
            const loopEnd = `{/${child.relationshipName}}`;
            
            // Get first record of sample
            const childRecords = data[child.relationshipName];
            const firstRecord = (childRecords && Array.isArray(childRecords) && childRecords.length > 0) ? childRecords[0] : null;

            let fields = child.selectedFields.map(f => {
                let sampleVal = '';
                if (firstRecord) {
                    if (f.includes('.')) {
                        // Handle child parent fields? e.g. Product2.Name
                        const parts = f.split('.');
                        if (firstRecord[parts[0]]) sampleVal = firstRecord[parts[0]][parts[1]];
                    } else {
                        sampleVal = firstRecord[f];
                    }
                }
                
                return {
                    label: f,
                    code: `{${f}}`,
                    sample: sampleVal
                };
            });
            
            const allCodes = [loopStart, ...fields.map(f => f.code), loopEnd];
            
            if (search) {
                fields = fields.filter(f => f.label.toLowerCase().includes(search) || f.code.toLowerCase().includes(search));
            }
            
            const isSectionMatch = child.relationshipName.toLowerCase().includes(search);
            const hasVisibleFields = fields.length > 0;
            
            return {
                name: child.relationshipName,
                loopStart: loopStart,
                loopEnd: loopEnd,
                fields: fields,
                copyAllText: allCodes.join('\n'),
                isVisible: !search || isSectionMatch || hasVisibleFields
            };
        });
        
        if (search) {
             childTags = childTags.filter(c => c.isVisible);
        }

        return {
            hasBase: baseTags.length > 0,
            baseFields: baseTags,
            baseCopyAll: baseCopyAll,
            
            hasParent: parentSections.length > 0,
            parentSections: parentSections,
             
            hasChildren: childTags.length > 0,
            children: childTags
        };
    }

    // --- Object Search Handling ---

    handleObjectSearch(event) {
        const searchKey = event.target.value.toLowerCase();
        this.selectedObjectLabel = event.target.value;
        this.showObjectDropdown = true;
        
        if (searchKey) {
            this.filteredObjectOptions = this.objectOptions.filter(opt => 
                opt.label.toLowerCase().includes(searchKey)
            );
        } else {
            this.filteredObjectOptions = this.objectOptions;
        }
    }

    handleObjectFocus() {
        this.showObjectDropdown = true;
        this.filteredObjectOptions = this.objectOptions.filter(opt => 
             opt.label.toLowerCase().includes((this.selectedObjectLabel || '').toLowerCase())
        );
    }

    handleObjectSelect(event) {
        const value = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;
        
        this.selectedObject = value;
        this.selectedObjectLabel = label;
        this.showObjectDropdown = false;
        
        // Reset downstream
        this.selectedFields = [];
        this.childConfigs = [];
        this.selectedChildRel = null;
        this.selectedChildLabel = '';
        this.selectedParentRel = null; 
        this.selectedParentLabel = '';
        
        this.notifyChange();
    }

    // --- Child Search Handling ---

    handleChildSearch(event) {
        const searchKey = event.target.value.toLowerCase();
        this.selectedChildLabel = event.target.value;
        this.showChildDropdown = true;
        
        if (searchKey) {
            this.filteredChildOptions = this.childOptions.filter(opt => 
                opt.label.toLowerCase().includes(searchKey)
            );
        } else {
            this.filteredChildOptions = this.childOptions;
        }
    }

    handleChildFocus() {
        this.showChildDropdown = true;
        this.filteredChildOptions = this.childOptions.filter(opt => 
             opt.label.toLowerCase().includes((this.selectedChildLabel || '').toLowerCase())
        );
    }

    handleChildSelect(event) {
        const value = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;
        
        this.selectedChildRel = value;
        this.selectedChildLabel = label;
        this.showChildDropdown = false;
    }

    // --- Child Clauses ---
    handleChildWhereChange(event) {
        const index = event.target.dataset.index;
        this.childConfigs[index].whereClause = event.target.value;
        this.notifyChange();
    }
    
    handleChildOrderChange(event) {
        const index = event.target.dataset.index;
        this.childConfigs[index].orderBy = event.target.value;
        this.notifyChange();
    }
    
    handleChildLimitChange(event) {
        const index = event.target.dataset.index;
        this.childConfigs[index].limitAmount = event.target.value;
        this.notifyChange();
    }
    
    // --- Parent Search Handling ---
    handleParentSearch(event) {
        const key = event.target.value.toLowerCase();
        this.selectedParentLabel = event.target.value;
        this.showParentDropdown = true;
        this.filteredParentOptions = key ? 
            this.parentOptions.filter(o => o.label.toLowerCase().includes(key)) : 
            this.parentOptions;
    }
    
    handleParentFocus() {
        this.showParentDropdown = true;
        this.filteredParentOptions = this.parentOptions.filter(opt => 
             opt.label.toLowerCase().includes((this.selectedParentLabel || '').toLowerCase())
        );
    }
    
    handleParentSelect(event) {
         const value = event.currentTarget.dataset.value;
         const label = event.currentTarget.dataset.label;
         const targetObj = event.currentTarget.dataset.target;
         
         this.selectedParentRel = value;
         this.selectedParentLabel = label;
         this.showParentDropdown = false;
         
         // Load fields for parent
         this.parentFieldOptions = [];
         this.filteredParentFieldOptions = [];
         this.selectedParentFields = []; // Reset multiselect state
         
         getObjectFields({ objectName: targetObj })
            .then(data => {
                this.parentFieldOptions = data;
                this.filteredParentFieldOptions = data.slice(0, 200); // Limit initially
            });
    }

    // --- Parent Field Search & Select (Multiselect) ---
    @track selectedParentFields = []; // Array of field values

    handleParentFieldSearch(event) {
        const key = event.target.value.toLowerCase();
        if (key) {
            this.filteredParentFieldOptions = this.parentFieldOptions.filter(o => 
                o.label.toLowerCase().includes(key) || o.value.toLowerCase().includes(key)
            );
        } else {
             this.filteredParentFieldOptions = this.parentFieldOptions.slice(0, 200);
        }
    }
    
    handleParentFieldChange(event) {
         this.selectedParentFields = event.detail.value;
    }

    get isParentFieldDisabled() {
        return !this.selectedParentRel;
    }

    get isAddParentDisabled() {
        // Disabled if nothing selected OR limit reached
        if (this.parentFieldSelection.length >= this.maxParentFields) return true;
        return !this.selectedParentFields || this.selectedParentFields.length === 0;
    }
    
    get isAddChildDisabled() {
         return this.childConfigs.length >= this.maxChildLists;
    }

    addParentField() {
        if (this.parentFieldSelection.length >= this.maxParentFields) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Limit Reached',
                    message: `You cannot add more than ${this.maxParentFields} parent fields.`,
                    variant: 'error',
                })
            );
            return;
        }

        if (this.selectedParentRel && this.selectedParentFields.length > 0) {
            const remaining = this.maxParentFields - this.parentFieldSelection.length;
            let newFields = [];
            
            // Slice if they tried to select more than allowed in one go
            const candidates = this.selectedParentFields.slice(0, remaining);
            if (this.selectedParentFields.length > remaining) {
                 this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Selection Truncated',
                        message: `Only added ${remaining} fields to stay within the limit of ${this.maxParentFields}.`,
                        variant: 'warning',
                    })
                );
            }

            candidates.forEach(field => {
                 const fieldPath = `${this.selectedParentRel}.${field}`;
                 if (!this.selectedFields.includes(fieldPath)) {
                     newFields.push(fieldPath);
                 }
            });
            
            if (newFields.length > 0) {
                this.parentFieldSelection = [...this.parentFieldSelection, ...newFields];
                this.updateCombinedSelection();
                
                 this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Fields Added',
                        message: `Added ${newFields.length} parent fields.`,
                        variant: 'success',
                    })
                );
            }
            this.selectedParentFields = [];
        }
    }

    get addedParentFieldItems() {
        // Heuristic: Parent fields contain a dot.
        return this.selectedFields
            .filter(f => f.includes('.') && !f.startsWith('('))
            .map(f => ({ label: f, name: f }));
    }

    get hasAddedParentFields() {
        return this.addedParentFieldItems.length > 0;
    }

    handleRemoveParentField(event) {
        const fieldToRemove = event.detail.item.name;
        this.parentFieldSelection = this.parentFieldSelection.filter(f => f !== fieldToRemove);
        this.updateCombinedSelection();
    }

    handleParentSelectAll() {
        if (!this.filteredParentFieldOptions || this.filteredParentFieldOptions.length === 0) return;
        
        // Select all filtered
        const allFilteredValues = this.filteredParentFieldOptions.map(f => f.value);
        // Multiselect works by binding value array.
        // Union approach for parent selector
        const set = new Set([...this.selectedParentFields, ...allFilteredValues]);
        this.selectedParentFields = Array.from(set);
        
        // Note: This only selects them in the listbox. User must still click "Add".
    }
    
    handleOutsideClick(_event) {
        // ... (Existing)
    }
    
    // --- Child Logic ---

    // Updated Logic for Child Checkboxes
    addChildConfig() {
        if (this.childConfigs.length >= this.maxChildLists) {
             this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Limit Reached',
                    message: `You cannot add more than ${this.maxChildLists} related lists.`,
                    variant: 'error',
                })
            );
            return;
        }

        if (!this.selectedChildRel) return;

        const selectedOption = this.childOptions.find(o => o.value === this.selectedChildRel);
        if (!selectedOption) return;
        
        const childObjName = selectedOption.childObjectApiName;

        if (this.childConfigs.find(c => c.relationshipName === this.selectedChildRel)) {
            return; 
        }

        const newChild = {
            relationshipName: this.selectedChildRel,
            childObjectApiName: childObjName,
            selectedFields: [],
            whereClause: '',
            orderBy: '',
            limitAmount: '',
            availableFields: [],
            filteredFields: [] // For search state
        };
        
        this.childConfigs = [...this.childConfigs, newChild];
        
        getObjectFields({ objectName: childObjName })
            .then(data => {
                this.childConfigs = this.childConfigs.map(c => {
                    if (c.relationshipName === newChild.relationshipName) {
                        return { 
                            ...c, 
                            availableFields: data,
                            filteredFields: data.slice(0, 200) // Initial limit
                        };
                    }
                    return c;
                });
            })
            .catch(_error => {
            });

        this.selectedChildRel = null;
        this.selectedChildLabel = '';
    }
    
    handleChildFieldSearch(event) {
        const index = event.target.dataset.index;
        const key = event.target.value.toLowerCase();
        window.clearTimeout(this[`childDelayTimeout_${index}`]);
        this[`childDelayTimeout_${index}`] = window.setTimeout(() => {
            this.filterChildFields(index, key);
        }, 300);
    }
    
    // Helper to filter specific child
    filterChildFields(index, searchKey) {
        const child = this.childConfigs[index];
        if (!child) return;
        
        let sourceOptions = child.availableFields;
        
        // 1. Filter by Selected
        if (this.showSelectedOnly) {
            sourceOptions = sourceOptions.filter(opt => child.selectedFields.includes(opt.value));
        }
        
        let optionsToShow = [];
        
        if (searchKey) {
            optionsToShow = sourceOptions.filter(o => 
                o.label.toLowerCase().includes(searchKey) || o.value.toLowerCase().includes(searchKey)
            );
        } else {
            optionsToShow = sourceOptions.slice(0, 200);
        }
        
        // Ensure selected are visible if NOT in showSelectedOnly mode
        if (!this.showSelectedOnly && child.selectedFields.length > 0) {
             const selectedSet = new Set(child.selectedFields);
             const visibleSet = new Set(optionsToShow.map(o => o.value));
             
             const missingOptions = child.availableFields.filter(o => 
                 selectedSet.has(o.value) && !visibleSet.has(o.value)
             );
             
             if (missingOptions.length > 0) {
                 optionsToShow = [...optionsToShow, ...missingOptions];
             }
        }
        
        child.filteredFields = optionsToShow;
        this.childConfigs = [...this.childConfigs];
    }
    
    handleChildSelectAll(event) {
        const index = event.target.dataset.index;
        const child = this.childConfigs[index];
        
        // Select all currently filtered fields
        const allFilteredValues = child.filteredFields.map(f => f.value);
        // Merge with existing logic? or Replace? 
        // Union approach:
        const set = new Set([...child.selectedFields, ...allFilteredValues]);
        child.selectedFields = Array.from(set);
        
        this.childConfigs = [...this.childConfigs];
        this.notifyChange();
    }

    handleChildFieldChange(event) {
        const index = event.target.dataset.index;
        const val = event.detail.value;
        const child = this.childConfigs[index];
        child.selectedFields = val;
        
        // Check if we need to re-filter (e.g. if showSelectedOnly is on, and we deselected something, it should disappear?)
        // Usually better UX not to make it disappear immediately under cursor.
        // But if showSelectedOnly is TRUE, and I deselect, it should eventually vanish.
        // Let's re-run filter if showSelectedOnly is true?
        // Actually, checkbox group handles changes. Filtering happens on search/toggle.
        
        this.childConfigs = [...this.childConfigs]; 
        this.notifyChange();
    }

    removeChildConfig(event) {
        const index = event.target.dataset.index;
        this.childConfigs.splice(index, 1);
        this.childConfigs = [...this.childConfigs];
        this.notifyChange();
    }

    get generatedQuery() {
        if (!this.selectedFields || (this.selectedFields.length === 0 && this.childConfigs.length === 0)) return '';
        // If NO fields selected but we have subqueries, technically valid SOQL? No, SELECT list cannot be empty.
        // Assuming user selects base/parent fields.
        let queryParts = [...this.selectedFields];
        
        this.childConfigs.forEach(child => {
            if (child.selectedFields.length > 0) {
                let childQuery = `(SELECT ${child.selectedFields.join(', ')} FROM ${child.relationshipName}`;
                
                if (child.whereClause) childQuery += ` WHERE ${child.whereClause}`;
                if (child.orderBy) childQuery += ` ORDER BY ${child.orderBy}`;
                if (child.limitAmount) childQuery += ` LIMIT ${child.limitAmount}`;
                
                childQuery += ')';
                queryParts.push(childQuery);
            }
        });
        return queryParts.join(', ');
    }
    


    notifyChange() {
        if (this._isParsing) return;
        const event = new CustomEvent('configchange', {
            detail: {
                objectName: this.selectedObject,
                queryConfig: this.generatedQuery,
                titleFormat: this.titleFormat
            }
        });
        this.dispatchEvent(event);
    }
    
    propagateConfig() {
        this.notifyChange();
    }

    @api titleFormat = '';

    handleTitleChange(event) {
        this.titleFormat = event.target.value;
        this.notifyChange();
    }

    handleInsertToTitle(event) {
        const tag = event.currentTarget.dataset.tag;
        if (tag) {
             this.titleFormat = (this.titleFormat || '') + tag;
             this.notifyChange();
        }
    }
}