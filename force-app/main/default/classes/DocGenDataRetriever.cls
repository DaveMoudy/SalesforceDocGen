public with sharing class DocGenDataRetriever {

    /**
     * Represents a parsed subquery with optional nested grandchild subqueries.
     * Used by the multi-level query stitcher to decompose configs like:
     * (SELECT Name, (SELECT Quantity FROM OpportunityLineItems) FROM Opportunities)
     */
    private class SubquerySpec {
        String relationshipName;     // e.g., 'Opportunities'
        String childObjectApiName;   // e.g., 'Opportunity'
        String parentIdField;        // e.g., 'AccountId'
        String fieldsOnly;           // e.g., 'Name, Amount' (no nested subqueries)
        String whereClause;
        String orderByClause;
        String limitClause;
        List<SubquerySpec> children = new List<SubquerySpec>();
    }

    /**
     * Executes a dynamic SOQL query based on the fields configuration and record ID.
     * Supports deep grandchild relationships via multi-level query stitching.
     *
     * Configs with nested subqueries like:
     *   Name, (SELECT Name, (SELECT Quantity FROM OpportunityLineItems) FROM Opportunities)
     * are decomposed into separate queries per level and stitched together.
     */
    /**
     * Represents a junction object configuration for two-hop queries.
     * E.g., Opportunity → OpportunityContactRoles → Contact
     */
    private class JunctionSpec {
        String junctionRel;        // 'OpportunityContactRoles'
        List<String> junctionFields; // ['Role'] — fields from junction record itself
        String targetObject;       // 'Contact'
        String targetIdField;      // 'ContactId' — lookup field on junction to target
        List<String> targetFields; // ['FirstName', 'LastName', 'Email']
        String targetWhere;
        String targetOrderBy;
    }

    /**
     * Returns the query config version (1, 2, or 3) for a given fieldsConfig string.
     * Used by DocGenBatch to decide whether bulk caching is available.
     */
    public static Integer getConfigVersion(String fieldsConfig) {
        if (String.isBlank(fieldsConfig) || !fieldsConfig.trim().startsWith('{')) {
            return 1;
        }
        try {
            Map<String, Object> jsonConfig = (Map<String, Object>) JSON.deserializeUntyped(fieldsConfig.trim());
            Object versionObj = jsonConfig.get('v');
            return (versionObj != null) ? Integer.valueOf(String.valueOf(versionObj)) : 2;
        } catch (Exception e) {
            // Malformed JSON — fall back to V1 (legacy flat string format)
            return 1;
        }
    }

    /**
     * Executes a dynamic SOQL query based on the fields configuration and record ID.
     * Auto-detects config version (V1 flat, V2 JSON, V3 tree) and routes accordingly.
     * @param recordId The ID of the record to query
     * @param baseObject The API name of the base SObject
     * @param fieldsConfig The query configuration string (V1/V2/V3 format)
     * @return Map of field names to values, with child relationships nested
     */
    public static Map<String, Object> getRecordData(Id recordId, String baseObject, String fieldsConfig) {
        if (String.isBlank(baseObject) || String.isBlank(fieldsConfig) || recordId == null) {
            throw DocGenService.ahe('Invalid parameters for data retrieval.');
        }

        // JSON config: route by version
        if (fieldsConfig.trim().startsWith('{')) {
            Map<String, Object> jsonConfig = (Map<String, Object>) JSON.deserializeUntyped(fieldsConfig.trim());
            Object versionObj = jsonConfig.get('v');
            Integer version = (versionObj != null) ? Integer.valueOf(String.valueOf(versionObj)) : 2;

            // V4: Custom Apex Data Provider
            if (version == 4) {
                return getRecordDataV4(recordId, jsonConfig);
            }
            if (version >= 3) {
                return getRecordDataV3(recordId, jsonConfig);
            }
            return getRecordDataV2(recordId, baseObject, fieldsConfig);
        }

        SObjectType objType = Schema.getGlobalDescribe().get(baseObject);
        if (objType == null) {
            throw DocGenService.ahe('Invalid or inaccessible object.');
        }
        Map<String, SObjectField> fieldMap = objType.getDescribe().fields.getMap();

        // Parse the config into flat fields, direct subqueries, and nested subquery specs
        List<String> flatParts = new List<String>();
        List<SubquerySpec> deepSpecs = new List<SubquerySpec>();
        parseConfigParts(fieldsConfig, baseObject, fieldMap, flatParts, deepSpecs);

        // Build Level 0 query: flat fields + direct child subqueries (no nesting)
        String level0Select = buildLevel0Select(flatParts, deepSpecs);
        if (String.isBlank(level0Select)) {
            level0Select = 'Id';
        }

        String query = 'SELECT ' + level0Select + ' FROM ' + String.escapeSingleQuotes(baseObject) + ' WHERE Id = :recordId LIMIT 1';

        Map<String, Object> data;
        try {
            List<SObject> results = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - field names from template config validated by Schema describe; base object escaped; runs with USER_MODE
            if (results.isEmpty()) {
                return null;
            }
            data = mapSObject(results[0]);
        } catch (Exception e) {
            throw DocGenService.ahe('Error executing query. Please verify your template configuration.');
        }

        // Stitch deeper levels (grandchildren, great-grandchildren)
        for (SubquerySpec spec : deepSpecs) {
            if (!spec.children.isEmpty()) {
                stitchGrandchildren(data, spec);
            }
        }

        return data;
    }

    /**
     * Parses the config string into flat fields/direct subqueries and deep subquery specs.
     * Nested subqueries are extracted so Level 0 only contains direct children.
     */
    /**
     * JSON v2 config parser. Builds SOQL from structured JSON, handles junctions.
     *
     * JSON format:
     * { "v":2, "baseObject":"Opportunity", "baseFields":["Name","Amount"],
     *   "parentFields":["Account.Name"], "children":[{"rel":"OpportunityLineItems","fields":["Name"]}],
     *   "junctions":[{"junctionRel":"OpportunityContactRoles","junctionFields":["Role"],
     *     "targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName","LastName"]}] }
     */
    private static Map<String, Object> getRecordDataV2(Id recordId, String baseObject, String jsonConfig) {
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(jsonConfig);

        // Build SELECT clause from baseFields + parentFields + child subqueries + junction subqueries
        List<String> selectParts = new List<String>();

        // Base fields
        List<Object> baseFields = (List<Object>) config.get('baseFields');
        if (baseFields != null) {
            for (Object f : baseFields) {
                selectParts.add(String.valueOf(f));
            }
        }

        // Parent fields (Account.Name, Owner.Email)
        List<Object> parentFields = (List<Object>) config.get('parentFields');
        if (parentFields != null) {
            for (Object f : parentFields) {
                selectParts.add(String.valueOf(f));
            }
        }

        // Direct child subqueries
        List<Object> children = (List<Object>) config.get('children');
        List<SubquerySpec> childSpecs = new List<SubquerySpec>();
        if (children != null) {
            for (Object childObj : children) {
                Map<String, Object> child = (Map<String, Object>) childObj;
                String rel = (String) child.get('rel');
                List<Object> fields = (List<Object>) child.get('fields');
                if (rel == null || fields == null || fields.isEmpty()) {
                    continue;
                }

                List<String> fieldNames = new List<String>();
                for (Object f : fields) { fieldNames.add(String.valueOf(f)); }

                String subquery = '(SELECT ' + String.join(fieldNames, ', ') + ' FROM ' + rel;
                try {
                    String w = sanitizeClause((String) child.get('where'), 'WHERE');
                    String o = sanitizeClause((String) child.get('orderBy'), 'ORDER BY');
                    String l = sanitizeClause((String) child.get('limit'), 'LIMIT');
                    if (String.isNotBlank(w)) {
                        subquery += ' WHERE ' + w;
                    }
                    if (String.isNotBlank(o)) {
                        subquery += ' ORDER BY ' + o;
                    }
                    if (String.isNotBlank(l)) {
                        subquery += ' LIMIT ' + l;
                    }
                    subquery += ')';
                    selectParts.add(subquery);

                    // Track for grandchild stitching (if nested children exist)
                    SubquerySpec spec = new SubquerySpec();
                    spec.relationshipName = rel;
                    resolveChildSchema(spec, baseObject);
                    spec.fieldsOnly = String.join(fieldNames, ', ');
                    childSpecs.add(spec);
                } catch (Exception e) {
                    // Invalid subquery config — skip this subquery
                    continue;
                }
            }
        }

        // Junction subqueries — query the junction relationship as a direct child
        List<JunctionSpec> junctionSpecs = new List<JunctionSpec>();
        List<Object> junctions = (List<Object>) config.get('junctions');
        if (junctions != null) {
            for (Object jObj : junctions) {
                Map<String, Object> j = (Map<String, Object>) jObj;
                JunctionSpec js = new JunctionSpec();
                js.junctionRel = (String) j.get('junctionRel');
                js.targetObject = (String) j.get('targetObject');
                js.targetIdField = (String) j.get('targetIdField');
                js.targetWhere = (String) j.get('targetWhere');
                js.targetOrderBy = (String) j.get('targetOrderBy');

                js.junctionFields = new List<String>();
                List<Object> jf = (List<Object>) j.get('junctionFields');
                if (jf != null) {
                    for (Object f : jf) {
                        js.junctionFields.add(String.valueOf(f));
                    }
                }

                js.targetFields = new List<String>();
                List<Object> tf = (List<Object>) j.get('targetFields');
                if (tf != null) {
                    for (Object f : tf) {
                        js.targetFields.add(String.valueOf(f));
                    }
                }

                junctionSpecs.add(js);

                // Build junction subquery: (SELECT ContactId, Role FROM OpportunityContactRoles)
                List<String> jqFields = new List<String>();
                jqFields.add(js.targetIdField); // Always need the lookup ID for stitching
                jqFields.addAll(js.junctionFields);
                selectParts.add('(SELECT ' + String.join(jqFields, ', ') + ' FROM ' + js.junctionRel + ')');
            }
        }

        if (selectParts.isEmpty()) {
            selectParts.add('Id');
        }

        // Execute Level 0 query
        String query = 'SELECT ' + String.join(selectParts, ', ') + ' FROM ' +
            String.escapeSingleQuotes(baseObject) + ' WHERE Id = :recordId LIMIT 1';

        Map<String, Object> data;
        try {
            List<SObject> results = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - field names from V2 query config; base object escaped; runs with USER_MODE
            if (results.isEmpty()) {
                return null;
            }
            data = mapSObject(results[0]);
        } catch (Exception e) {
            throw DocGenService.ahe('Error executing query. Please verify your template configuration.');
        }

        // Stitch junction targets (two-hop: junction record → target object)
        for (JunctionSpec js : junctionSpecs) {
            stitchJunctionTargets(data, js);
        }

        return data;
    }

    /**
     * Stitches target object data into junction records.
     * E.g., for OpportunityContactRoles, queries Contacts by ID and
     * injects Contact data into each OCR record under the 'Contact' key.
     */
    private static void stitchJunctionTargets(Map<String, Object> data, JunctionSpec js) {
        Object junctionData = data.get(js.junctionRel);
        if (junctionData == null || !(junctionData instanceof Map<String, Object>)) {
            return;
        }

        Map<String, Object> jMap = (Map<String, Object>) junctionData;
        Object recordsObj = jMap.get('records');
        if (recordsObj == null || !(recordsObj instanceof List<Object>)) {
            return;
        }

        List<Object> junctionRecords = (List<Object>) recordsObj;
        if (junctionRecords.isEmpty()) {
            return;
        }

        // Collect target IDs from junction records
        Set<Id> targetIds = new Set<Id>();
        for (Object rec : junctionRecords) {
            if (rec instanceof Map<String, Object>) {
                Object idVal = ((Map<String, Object>) rec).get(js.targetIdField);
                if (idVal != null) {
                    try {
                        targetIds.add(Id.valueOf(String.valueOf(idVal)));
                    } catch (Exception e) {
                        String ignored = e.getMessage(); // Non-ID value in junction lookup — skip
                    }
                }
            }
        }
        if (targetIds.isEmpty()) {
            return;
        }

        // Query target objects
        List<String> targetFieldList = new List<String>(js.targetFields);
        if (!targetFieldList.contains('Id')) {
            targetFieldList.add(0, 'Id');
        }

        String targetQuery = 'SELECT ' + String.join(targetFieldList, ', ') +
            ' FROM ' + String.escapeSingleQuotes(js.targetObject) +
            ' WHERE Id IN :targetIds';
        if (String.isNotBlank(js.targetWhere)) {
            targetQuery += ' AND ' + sanitizeClause(js.targetWhere, 'WHERE');
        }
        if (String.isNotBlank(js.targetOrderBy)) {
            targetQuery += ' ORDER BY ' + sanitizeClause(js.targetOrderBy, 'ORDER BY');
        }

        Map<Id, Map<String, Object>> targetMap = new Map<Id, Map<String, Object>>();
        try {
            for (SObject targetRec : Database.query(targetQuery, AccessLevel.USER_MODE)) { // NOPMD ApexSOQLInjection - junction target fields from V2 config; clauses sanitized by sanitizeClause(); runs with USER_MODE
                targetMap.put(targetRec.Id, mapSObject(targetRec));
            }
        } catch (Exception e) {
            // Junction target query failed — skip stitching for this junction
            return;
        }

        // Stitch target data into each junction record
        for (Object rec : junctionRecords) {
            if (!(rec instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> jRec = (Map<String, Object>) rec;
            Object targetIdVal = jRec.get(js.targetIdField);
            if (targetIdVal == null) {
                continue;
            }

            Id targetId;
            try {
                targetId = Id.valueOf(String.valueOf(targetIdVal));
            } catch (Exception e) {
                // Non-ID value in target lookup — skip this junction record
                continue;
            }

            Map<String, Object> targetData = targetMap.get(targetId);
            if (targetData != null) {
                jRec.put(js.targetObject, targetData);
            }
        }
    }

    // =========================================================================
    // V3: Query Tree Walker — multiple related objects, any depth
    // =========================================================================

    /**
     * Inner class representing a node in the query tree.
     */
    private class TreeNode {
        String id;
        String objectApiName;
        List<String> fields;
        List<String> parentFields;
        String parentNodeId;
        String lookupField;
        String relationshipName;
        String whereClause;
        String orderByClause;
        String limitClause;
        // Junction support
        Map<String, Object> junction;
    }

    /**
     * Processes a JSON v3 query tree config. Walks the tree top-down,
     * executing one SOQL query per node and stitching results into the
     * parent's data map.
     */
    private static Map<String, Object> getRecordDataV3(Id recordId, Map<String, Object> config) {
        // Parse all nodes
        List<TreeNode> allNodes = new List<TreeNode>();
        Map<String, TreeNode> nodeMap = new Map<String, TreeNode>();

        List<Object> nodesJson = (List<Object>) config.get('nodes');
        if (nodesJson == null || nodesJson.isEmpty()) {
            throw DocGenService.ahe('No query nodes defined.');
        }

        for (Object nodeObj : nodesJson) {
            Map<String, Object> n = (Map<String, Object>) nodeObj;
            TreeNode tn = new TreeNode();
            tn.id = (String) n.get('id');
            tn.objectApiName = (String) n.get('object');
            tn.parentNodeId = (String) n.get('parentNode');
            tn.lookupField = (String) n.get('lookupField');
            tn.relationshipName = (String) n.get('relationshipName');
            tn.whereClause = (String) n.get('where');
            tn.orderByClause = (String) n.get('orderBy');
            tn.limitClause = (String) n.get('limit');
            tn.junction = (Map<String, Object>) n.get('junction');

            tn.fields = new List<String>();
            List<Object> flds = (List<Object>) n.get('fields');
            if (flds != null) {
                for (Object f : flds) {
                    tn.fields.add(String.valueOf(f));
                }
            }

            tn.parentFields = new List<String>();
            List<Object> pFlds = (List<Object>) n.get('parentFields');
            if (pFlds != null) {
                for (Object f : pFlds) {
                    tn.parentFields.add(String.valueOf(f));
                }
            }

            allNodes.add(tn);
            nodeMap.put(tn.id, tn);
        }

        // Find root node (parentNode is null)
        TreeNode root = null;
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == null) {
                root = tn;
                break;
            }
        }
        if (root == null) {
            throw DocGenService.ahe('No root node found in query tree.');
        }

        // Query root: SELECT fields, parentFields FROM object WHERE Id = :recordId
        List<String> rootSelect = new List<String>();
        rootSelect.addAll(root.fields);
        rootSelect.addAll(root.parentFields);
        if (rootSelect.isEmpty()) {
            rootSelect.add('Id');
        }

        String rootQuery = 'SELECT ' + String.join(rootSelect, ', ') +
            ' FROM ' + String.escapeSingleQuotes(root.objectApiName) +
            ' WHERE Id = :recordId LIMIT 1';

        Map<String, Object> rootData;
        try {
            List<SObject> results = Database.query(rootQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - V3 tree node fields from query config; object name escaped; runs with USER_MODE
            if (results.isEmpty()) {
                return null;
            }
            rootData = mapSObject(results[0]);
        } catch (Exception e) {
            throw DocGenService.ahe('Error querying root record: ' + e.getMessage());
        }

        // Walk the tree: process children of each node
        processChildNodes(root.id, rootData, allNodes, nodeMap, true);

        return rootData;
    }

    /**
     * Bulk version of getRecordDataV3. Queries all records with a single IN clause
     * and processes all children in bulk. Returns a Map keyed by record Id.
     * Used by DocGenBatch to pre-cache data for all records in one transaction.
     */
    public static Map<Id, Map<String, Object>> getRecordDataV3Bulk(Set<Id> recordIds, Map<String, Object> config) {
        if (recordIds == null || recordIds.isEmpty()) {
            return new Map<Id, Map<String, Object>>();
        }

        // Parse all nodes (same as single-record version)
        List<TreeNode> allNodes = new List<TreeNode>();
        Map<String, TreeNode> nodeMap = new Map<String, TreeNode>();

        List<Object> nodesJson = (List<Object>) config.get('nodes');
        if (nodesJson == null || nodesJson.isEmpty()) {
            throw DocGenService.ahe('No query nodes defined.');
        }

        for (Object nodeObj : nodesJson) {
            Map<String, Object> n = (Map<String, Object>) nodeObj;
            TreeNode tn = new TreeNode();
            tn.id = (String) n.get('id');
            tn.objectApiName = (String) n.get('object');
            tn.parentNodeId = (String) n.get('parentNode');
            tn.lookupField = (String) n.get('lookupField');
            tn.relationshipName = (String) n.get('relationshipName');
            tn.whereClause = (String) n.get('where');
            tn.orderByClause = (String) n.get('orderBy');
            tn.limitClause = (String) n.get('limit');
            tn.junction = (Map<String, Object>) n.get('junction');

            tn.fields = new List<String>();
            List<Object> flds = (List<Object>) n.get('fields');
            if (flds != null) {
                for (Object f : flds) {
                    tn.fields.add(String.valueOf(f));
                }
            }

            tn.parentFields = new List<String>();
            List<Object> pFlds = (List<Object>) n.get('parentFields');
            if (pFlds != null) {
                for (Object f : pFlds) {
                    tn.parentFields.add(String.valueOf(f));
                }
            }

            allNodes.add(tn);
            nodeMap.put(tn.id, tn);
        }

        // Find root node
        TreeNode root = null;
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == null) {
                root = tn;
                break;
            }
        }
        if (root == null) {
            throw DocGenService.ahe('No root node found in query tree.');
        }

        // Bulk root query: SELECT fields FROM object WHERE Id IN :recordIds
        List<String> rootSelect = new List<String>();
        rootSelect.addAll(root.fields);
        rootSelect.addAll(root.parentFields);
        if (rootSelect.isEmpty()) {
            rootSelect.add('Id');
        }
        if (!rootSelect.contains('Id')) {
            rootSelect.add(0, 'Id');
        }

        String rootQuery = 'SELECT ' + String.join(rootSelect, ', ') +
            ' FROM ' + String.escapeSingleQuotes(root.objectApiName) +
            ' WHERE Id IN :recordIds';

        Map<Id, Map<String, Object>> allData = new Map<Id, Map<String, Object>>();
        try {
            List<SObject> results = Database.query(rootQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - V3 tree node fields from query config; object name escaped; runs with USER_MODE
            for (SObject rec : results) {
                allData.put(rec.Id, mapSObject(rec));
            }
        } catch (Exception e) {
            throw DocGenService.ahe('Error bulk-querying records: ' + e.getMessage());
        }

        // Walk the tree in bulk: process children for all root records at once
        processChildNodesBulk(root.id, allData, allNodes, nodeMap);

        return allData;
    }

    /**
     * Recursively processes child nodes, querying and stitching results.
     * @param parentId The tree node ID of the parent
     * @param parentDataMap The parent's data map (single record) or null for batch
     * @param allNodes All tree nodes
     * @param nodeMap Map of node ID → TreeNode
     * @param isSingleParent True if parent is a single record (root), false if batch
     */
    private static void processChildNodes(String parentId, Map<String, Object> parentDataMap,
            List<TreeNode> allNodes, Map<String, TreeNode> nodeMap, Boolean isSingleParent) {

        // Find children of this parent
        List<TreeNode> children = new List<TreeNode>();
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == parentId) {
                children.add(tn);
            }
        }

        for (TreeNode child : children) {
            if (String.isBlank(child.lookupField) || String.isBlank(child.relationshipName)) {
                continue;
            }

            // Collect parent record IDs
            Set<Id> parentIds = new Set<Id>();
            if (isSingleParent) {
                Object idVal = parentDataMap.get('Id');
                if (idVal != null) {
                    try {
                        parentIds.add(Id.valueOf(String.valueOf(idVal)));
                    } catch (Exception e) {
                        String ignored = e.getMessage(); // Non-ID value in parent record — skip
                    }
                }
            }
            if (parentIds.isEmpty()) {
                continue;
            }

            // Build child query
            List<String> selectFields = new List<String>();
            if (!child.fields.contains('Id')) {
                selectFields.add('Id');
            }
            selectFields.addAll(child.fields);
            selectFields.addAll(child.parentFields);
            selectFields.add(child.lookupField);

            // Junction fields
            if (child.junction != null) {
                String targetIdField = (String) child.junction.get('targetIdField');
                if (String.isNotBlank(targetIdField) && !selectFields.contains(targetIdField)) {
                    selectFields.add(targetIdField);
                }
                List<Object> jFields = (List<Object>) child.junction.get('junctionFields');
                if (jFields != null) {
                    for (Object jf : jFields) {
                        String jfs = String.valueOf(jf);
                        if (!selectFields.contains(jfs)) {
                            selectFields.add(jfs);
                        }
                    }
                }
            }

            String childQuery = 'SELECT ' + String.join(selectFields, ', ') +
                ' FROM ' + String.escapeSingleQuotes(child.objectApiName) +
                ' WHERE ' + String.escapeSingleQuotes(child.lookupField) + ' IN :parentIds';
            List<SObject> childResults;
            try {
                if (String.isNotBlank(child.whereClause)) { childQuery += ' AND ' + sanitizeClause(child.whereClause, 'WHERE'); }
                if (String.isNotBlank(child.orderByClause)) { childQuery += ' ORDER BY ' + sanitizeClause(child.orderByClause, 'ORDER BY'); }
                if (String.isNotBlank(child.limitClause)) { childQuery += ' LIMIT ' + sanitizeClause(child.limitClause, 'LIMIT'); }

                childResults = Database.query(childQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - V3 child node fields from query config; clauses sanitized by sanitizeClause(); runs with USER_MODE
            } catch (Exception e) {
                // Child query failed — skip this child relationship
                continue;
            }

            // Group by parent lookup field
            Map<Id, List<Map<String, Object>>> grouped = new Map<Id, List<Map<String, Object>>>();
            for (SObject rec : childResults) {
                Id parentRecId = (Id) rec.get(child.lookupField);
                if (!grouped.containsKey(parentRecId)) {
                    grouped.put(parentRecId, new List<Map<String, Object>>());
                }
                grouped.get(parentRecId).add(mapSObject(rec));
            }

            // Stitch into parent
            Object parentIdVal = parentDataMap.get('Id');
            if (parentIdVal != null) {
                Id parentRecId;
                try {
                    parentRecId = Id.valueOf(String.valueOf(parentIdVal));
                } catch (Exception e) {
                    // Non-ID value in parent Id field — skip stitching
                    continue;
                }

                List<Map<String, Object>> childRecords = grouped.containsKey(parentRecId)
                    ? grouped.get(parentRecId) : new List<Map<String, Object>>();

                parentDataMap.put(child.relationshipName, new Map<String, Object>{
                    'totalSize' => childRecords.size(),
                    'records' => childRecords
                });

                // Junction stitching: if this node has a junction config, stitch target data
                if (child.junction != null) {
                    stitchJunctionForTree(childRecords, child.junction);
                }

                // Recurse: process this child's children for each child record
                for (Map<String, Object> childRec : childRecords) {
                    processChildNodes(child.id, childRec, allNodes, nodeMap, true);
                }
            }
        }
    }

    /**
     * Bulk version of processChildNodes. Processes children for ALL parent records
     * in a single SOQL query per child node level, then stitches results back.
     * @param parentNodeId The tree node ID of the parent
     * @param parentDataMaps Map of parent record Id → data map (all parents at this level)
     * @param allNodes All tree nodes
     * @param nodeMap Map of node ID → TreeNode
     */
    private static void processChildNodesBulk(String parentNodeId, Map<Id, Map<String, Object>> parentDataMaps,
            List<TreeNode> allNodes, Map<String, TreeNode> nodeMap) {

        // Find children of this parent node
        List<TreeNode> children = new List<TreeNode>();
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == parentNodeId) { children.add(tn); }
        }

        for (TreeNode child : children) {
            if (String.isBlank(child.lookupField) || String.isBlank(child.relationshipName)) {
                continue;
            }

            // Collect ALL parent record IDs
            Set<Id> parentIds = parentDataMaps.keySet();
            if (parentIds.isEmpty()) {
                continue;
            }

            // Build child query
            List<String> selectFields = new List<String>();
            if (!child.fields.contains('Id')) {
                selectFields.add('Id');
            }
            selectFields.addAll(child.fields);
            selectFields.addAll(child.parentFields);
            selectFields.add(child.lookupField);

            // Junction fields
            if (child.junction != null) {
                String targetIdField = (String) child.junction.get('targetIdField');
                if (String.isNotBlank(targetIdField) && !selectFields.contains(targetIdField)) {
                    selectFields.add(targetIdField);
                }
                List<Object> jFields = (List<Object>) child.junction.get('junctionFields');
                if (jFields != null) {
                    for (Object jf : jFields) {
                        String jfs = String.valueOf(jf);
                        if (!selectFields.contains(jfs)) {
                            selectFields.add(jfs);
                        }
                    }
                }
            }

            // Single query for ALL parents
            String childQuery = 'SELECT ' + String.join(selectFields, ', ') +
                ' FROM ' + String.escapeSingleQuotes(child.objectApiName) +
                ' WHERE ' + String.escapeSingleQuotes(child.lookupField) + ' IN :parentIds';

            List<SObject> childResults;
            try {
                if (String.isNotBlank(child.whereClause)) { childQuery += ' AND ' + sanitizeClause(child.whereClause, 'WHERE'); }
                if (String.isNotBlank(child.orderByClause)) { childQuery += ' ORDER BY ' + sanitizeClause(child.orderByClause, 'ORDER BY'); }
                if (String.isNotBlank(child.limitClause)) { childQuery += ' LIMIT ' + sanitizeClause(child.limitClause, 'LIMIT'); }

                childResults = Database.query(childQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - V3 child node fields from query config; clauses sanitized; runs with USER_MODE
            } catch (Exception e) {
                // Bulk child query failed — skip this child relationship
                continue;
            }

            // Group by parent lookup field
            Map<Id, List<Map<String, Object>>> grouped = new Map<Id, List<Map<String, Object>>>();
            for (SObject rec : childResults) {
                Id parentRecId = (Id) rec.get(child.lookupField);
                if (!grouped.containsKey(parentRecId)) {
                    grouped.put(parentRecId, new List<Map<String, Object>>());
                }
                grouped.get(parentRecId).add(mapSObject(rec));
            }

            // Stitch into each parent's data map
            Map<Id, Map<String, Object>> allChildDataMaps = new Map<Id, Map<String, Object>>();
            for (Id parentRecId : parentDataMaps.keySet()) {
                Map<String, Object> parentData = parentDataMaps.get(parentRecId);
                List<Map<String, Object>> childRecords = grouped.containsKey(parentRecId)
                    ? grouped.get(parentRecId) : new List<Map<String, Object>>();

                parentData.put(child.relationshipName, new Map<String, Object>{
                    'totalSize' => childRecords.size(),
                    'records' => childRecords
                });

                // Junction stitching
                if (child.junction != null) {
                    stitchJunctionForTree(childRecords, child.junction);
                }

                // Collect child records for next-level recursion
                for (Map<String, Object> childRec : childRecords) {
                    Object childIdVal = childRec.get('Id');
                    if (childIdVal != null) {
                        try {
                            allChildDataMaps.put(Id.valueOf(String.valueOf(childIdVal)), childRec);
                        } catch (Exception e) {
                            String ignored = e.getMessage(); // Non-ID value in child record — skip
                        }
                    }
                }
            }

            // Recurse: process this child node's children for all child records
            if (!allChildDataMaps.isEmpty()) {
                processChildNodesBulk(child.id, allChildDataMaps, allNodes, nodeMap);
            }
        }
    }

    /**
     * Stitches junction target data into child records (tree version).
     * Same concept as stitchJunctionTargets but works with the tree node junction config.
     */
    private static void stitchJunctionForTree(List<Map<String, Object>> junctionRecords,
            Map<String, Object> junctionConfig) {
        String targetObject = (String) junctionConfig.get('targetObject');
        String targetIdField = (String) junctionConfig.get('targetIdField');
        if (String.isBlank(targetObject) || String.isBlank(targetIdField)) { return; }

        List<String> targetFields = new List<String>();
        List<Object> tfl = (List<Object>) junctionConfig.get('targetFields');
        if (tfl != null) {
            for (Object f : tfl) {
                targetFields.add(String.valueOf(f));
            }
        }
        if (targetFields.isEmpty()) {
            return;
        }
        if (!targetFields.contains('Id')) {
            targetFields.add(0, 'Id');
        }

        // Collect target IDs
        Set<Id> targetIds = new Set<Id>();
        for (Map<String, Object> rec : junctionRecords) {
            Object idVal = rec.get(targetIdField);
            if (idVal != null) {
                try {
                    targetIds.add(Id.valueOf(String.valueOf(idVal)));
                } catch (Exception e) {
                    String ignored = e.getMessage(); // Non-ID value in junction target — skip
                }
            }
        }
        if (targetIds.isEmpty()) {
            return;
        }

        // Query targets
        String tQuery = 'SELECT ' + String.join(targetFields, ', ') +
            ' FROM ' + String.escapeSingleQuotes(targetObject) +
            ' WHERE Id IN :targetIds';

        Map<Id, Map<String, Object>> targetMap = new Map<Id, Map<String, Object>>();
        try {
            for (SObject rec : Database.query(tQuery, AccessLevel.USER_MODE)) { // NOPMD ApexSOQLInjection - V3 junction target fields from query config; object name escaped; runs with USER_MODE
                targetMap.put(rec.Id, mapSObject(rec));
            }
        } catch (Exception e) {
            // Junction target query failed — skip stitching
            return;
        }

        // Stitch
        for (Map<String, Object> jRec : junctionRecords) {
            Object idVal = jRec.get(targetIdField);
            if (idVal == null) {
                continue;
            }
            try {
                Id tId = Id.valueOf(String.valueOf(idVal));
                Map<String, Object> tData = targetMap.get(tId);
                if (tData != null) {
                    jRec.put(targetObject, tData);
                }
            } catch (Exception e) {
                String ignored = e.getMessage(); // Non-ID value in target field — skip
            }
        }
    }

    private static void parseConfigParts(String fieldsConfig, String baseObject,
            Map<String, SObjectField> fieldMap, List<String> flatParts, List<SubquerySpec> deepSpecs) {

        // Split by comma at paren level 0
        List<String> rawParts = splitTopLevel(fieldsConfig);

        for (String part : rawParts) {
            String trimmed = part.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }

            String upper = trimmed.toUpperCase();
            if (trimmed.startsWith('(') && upper.contains('SELECT') && upper.contains('FROM')) {
                // This is a subquery — check if it has nested subqueries
                SubquerySpec spec = parseSubquerySpec(trimmed, baseObject);
                if (spec != null) {
                    deepSpecs.add(spec);
                    // Build a flattened version for Level 0 (strip nested subqueries)
                    String flatSubquery = buildFlatSubquery(spec);
                    flatParts.add(flatSubquery);
                } else {
                    flatParts.add(trimmed); // Can't parse, pass through as-is
                }
            } else {
                // Regular field — validate
                String validated = validateField(trimmed, fieldMap);
                if (validated != null) {
                    flatParts.add(validated);
                }
            }
        }
    }

    /**
     * Splits a config string by commas, respecting parenthesis nesting.
     */
    private static List<String> splitTopLevel(String input) {
        List<String> parts = new List<String>();
        String current = '';
        Integer parenLevel = 0;

        for (Integer i = 0; i < input.length(); i++) {
            String ch = input.substring(i, i + 1);

            // Auto-split field from adjacent subquery: "Account.Name (SELECT..."
            if (ch == '(' && parenLevel == 0 && String.isNotBlank(current.trim())) {
                parts.add(current.trim());
                current = '';
            }

            if (ch == '(') { parenLevel++; }
            if (ch == ')') { parenLevel--; }

            if (ch == ',' && parenLevel == 0) {
                parts.add(current.trim());
                current = '';
            } else {
                current += ch;
            }
        }
        if (String.isNotBlank(current.trim())) { parts.add(current.trim()); }
        return parts;
    }

    /**
     * Parses a subquery string into a SubquerySpec, extracting any nested subqueries.
     * Input: (SELECT Name, Amount, (SELECT Quantity FROM OpportunityLineItems) FROM Opportunities WHERE ...)
     */
    private static SubquerySpec parseSubquerySpec(String subqueryStr, String parentObject) {
        // Strip outer parens
        String innerStr = subqueryStr.trim();
        if (innerStr.startsWith('(')) { innerStr = innerStr.substring(1); }
        if (innerStr.endsWith(')')) { innerStr = innerStr.substring(0, innerStr.length() - 1); }
        innerStr = innerStr.trim();

        // Extract: SELECT <fields> FROM <relationship> [WHERE ...] [ORDER BY ...] [LIMIT ...]
        String upperInner = innerStr.toUpperCase();
        Integer selectIdx = upperInner.indexOf('SELECT ');
        Integer fromIdx = findKeywordAtLevel0(innerStr, 'FROM');
        if (selectIdx == -1 || fromIdx == -1) { return null; }

        String fieldsPart = innerStr.substring(selectIdx + 7, fromIdx).trim();
        String afterFrom = innerStr.substring(fromIdx + 5).trim();

        // Extract relationship name and optional WHERE/ORDER BY/LIMIT
        String relationshipName;
        String whereClause;
        String orderByClause;
        String limitClause;

        String upperAfterFrom = afterFrom.toUpperCase();
        Integer whereIdx = findKeywordAtLevel0(afterFrom, 'WHERE');
        Integer orderIdx = findKeywordAtLevel0(afterFrom, 'ORDER');
        Integer limitIdx = findKeywordAtLevel0(afterFrom, 'LIMIT');

        Integer firstClauseIdx = afterFrom.length();
        if (whereIdx != -1 && whereIdx < firstClauseIdx) { firstClauseIdx = whereIdx; }
        if (orderIdx != -1 && orderIdx < firstClauseIdx) { firstClauseIdx = orderIdx; }
        if (limitIdx != -1 && limitIdx < firstClauseIdx) { firstClauseIdx = limitIdx; }

        relationshipName = afterFrom.substring(0, firstClauseIdx).trim();

        whereClause = (whereIdx != -1) ? extractClause(afterFrom, whereIdx + 6, orderIdx, limitIdx) : null;
        orderByClause = (orderIdx != -1) ? extractClause(afterFrom, orderIdx + 9, limitIdx, -1) : null;
        limitClause = (limitIdx != -1) ? afterFrom.substring(limitIdx + 6).trim() : null;

        SubquerySpec spec = new SubquerySpec();
        spec.relationshipName = relationshipName;
        spec.whereClause = whereClause;
        spec.orderByClause = orderByClause;
        spec.limitClause = limitClause;

        // Resolve child object and parent ID field from Schema
        resolveChildSchema(spec, parentObject);

        // Check if fieldsPart contains nested subqueries
        List<String> fieldTokens = splitTopLevel(fieldsPart);
        List<String> plainFields = new List<String>();

        for (String token : fieldTokens) {
            String trimToken = token.trim();
            String upperToken = trimToken.toUpperCase();
            if (trimToken.startsWith('(') && upperToken.contains('SELECT') && upperToken.contains('FROM')) {
                // Nested subquery — parse as grandchild
                if (String.isNotBlank(spec.childObjectApiName)) {
                    SubquerySpec grandchild = parseSubquerySpec(trimToken, spec.childObjectApiName);
                    if (grandchild != null) {
                        spec.children.add(grandchild);
                    }
                }
            } else if (String.isNotBlank(trimToken)) {
                plainFields.add(trimToken);
            }
        }

        // Always include Id for stitching
        Boolean hasId = false;
        for (String f : plainFields) {
            if (f.equalsIgnoreCase('Id')) { hasId = true; break; }
        }
        if (!hasId) { plainFields.add(0, 'Id'); }

        spec.fieldsOnly = String.join(plainFields, ', ');
        return spec;
    }

    /**
     * Finds a SOQL keyword at parenthesis level 0 (not inside a subquery).
     */
    private static Integer findKeywordAtLevel0(String input, String keyword) {
        String upper = input.toUpperCase();
        String target = ' ' + keyword.toUpperCase() + ' ';
        Integer parenLvl = 0;
        // Also check at start of string
        if (upper.startsWith(keyword.toUpperCase() + ' ') && parenLvl == 0) { return 0; }

        for (Integer i = 0; i < input.length(); i++) {
            String ch = input.substring(i, i + 1);
            if (ch == '(') { parenLvl++; }
            if (ch == ')') { parenLvl--; }
            if (parenLvl == 0 && i + target.length() <= upper.length()) {
                if (upper.substring(i, i + target.length()) == target) {
                    return i + 1; // position of keyword (after the space)
                }
            }
        }
        return -1;
    }

    /**
     * Extracts a clause value between the current keyword and the next keyword.
     */
    private static String extractClause(String source, Integer startIdx, Integer nextIdx1, Integer nextIdx2) {
        Integer endIdx = source.length();
        if (nextIdx1 != -1 && nextIdx1 < endIdx) { endIdx = nextIdx1; }
        if (nextIdx2 != -1 && nextIdx2 < endIdx) { endIdx = nextIdx2; }
        return source.substring(startIdx, endIdx).trim();
    }

    /**
     * Resolves the child object API name and parent lookup field from Schema.
     */
    private static void resolveChildSchema(SubquerySpec spec, String parentObjectName) {
        SObjectType parentType = Schema.getGlobalDescribe().get(parentObjectName);
        if (parentType == null) { return; }

        for (Schema.ChildRelationship cr : parentType.getDescribe().getChildRelationships()) {
            if (cr.getRelationshipName() == spec.relationshipName) {
                spec.childObjectApiName = String.valueOf(cr.getChildSObject());
                spec.parentIdField = String.valueOf(cr.getField());
                return;
            }
        }
    }

    /**
     * Builds a flat subquery for Level 0 (strips nested grandchild subqueries).
     */
    private static String buildFlatSubquery(SubquerySpec spec) {
        String sq = '(SELECT ' + spec.fieldsOnly + ' FROM ' + spec.relationshipName;
        if (String.isNotBlank(spec.whereClause)) { sq += ' WHERE ' + spec.whereClause; }
        if (String.isNotBlank(spec.orderByClause)) { sq += ' ORDER BY ' + spec.orderByClause; }
        if (String.isNotBlank(spec.limitClause)) { sq += ' LIMIT ' + spec.limitClause; }
        sq += ')';
        return sq;
    }

    /**
     * Builds the Level 0 SELECT clause from validated flat parts.
     */
    private static String buildLevel0Select(List<String> parts, List<SubquerySpec> specs) {
        String result = '';
        for (String part : parts) {
            if (String.isNotBlank(result)) { result += ', '; }
            result += part;
        }
        return result;
    }

    /**
     * Stitches grandchild data into the data map via follow-up queries.
     * For each child record in the parent's child list, queries grandchildren
     * using IN :parentIds and injects them into the child record's map.
     */
    private static void stitchGrandchildren(Map<String, Object> data, SubquerySpec parentSpec) {
        // Get the child records list from the data map
        Object childData = data.get(parentSpec.relationshipName);
        if (childData == null || !(childData instanceof Map<String, Object>)) { return; }

        Map<String, Object> childMap = (Map<String, Object>) childData;
        Object recordsObj = childMap.get('records');
        if (recordsObj == null || !(recordsObj instanceof List<Object>)) { return; }

        List<Object> childRecords = (List<Object>) recordsObj;
        if (childRecords.isEmpty()) { return; }

        // For each grandchild spec, query and stitch
        for (SubquerySpec grandchildSpec : parentSpec.children) {
            if (String.isBlank(grandchildSpec.childObjectApiName) || String.isBlank(grandchildSpec.parentIdField)) {
                continue;
            }

            // Collect parent IDs
            Set<Id> parentIds = new Set<Id>();
            for (Object rec : childRecords) {
                if (rec instanceof Map<String, Object>) {
                    Object idVal = ((Map<String, Object>) rec).get('Id');
                    if (idVal != null) {
                        try {
                            parentIds.add(Id.valueOf(String.valueOf(idVal)));
                        } catch (Exception e) {
                            String ignored = e.getMessage(); // Non-ID value — skip this child record
                        }
                    }
                }
            }
            if (parentIds.isEmpty()) {
                continue;
            }

            // Query grandchildren
            String gcQuery = 'SELECT ' + grandchildSpec.fieldsOnly +
                ', ' + grandchildSpec.parentIdField +
                ' FROM ' + String.escapeSingleQuotes(grandchildSpec.childObjectApiName) +
                ' WHERE ' + String.escapeSingleQuotes(grandchildSpec.parentIdField) + ' IN :parentIds';
            if (String.isNotBlank(grandchildSpec.whereClause)) { gcQuery += ' AND ' + grandchildSpec.whereClause; }
            if (String.isNotBlank(grandchildSpec.orderByClause)) { gcQuery += ' ORDER BY ' + grandchildSpec.orderByClause; }
            if (String.isNotBlank(grandchildSpec.limitClause)) { gcQuery += ' LIMIT ' + grandchildSpec.limitClause; }

            List<SObject> gcResults;
            try {
                gcResults = Database.query(gcQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - grandchild fields from query config; runs with USER_MODE
            } catch (Exception e) {
                // Grandchild query failed — skip this relationship
                continue;
            }

            // Group grandchild records by parent ID
            Map<Id, List<Map<String, Object>>> gcByParent = new Map<Id, List<Map<String, Object>>>();
            for (SObject gc : gcResults) {
                Id parentId = (Id) gc.get(grandchildSpec.parentIdField);
                if (!gcByParent.containsKey(parentId)) {
                    gcByParent.put(parentId, new List<Map<String, Object>>());
                }
                gcByParent.get(parentId).add(mapSObject(gc));
            }

            // Stitch into child records
            for (Object rec : childRecords) {
                if (!(rec instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> childRec = (Map<String, Object>) rec;
                Object childIdVal = childRec.get('Id');
                if (childIdVal == null) {
                    continue;
                }

                Id childId;
                try {
                    childId = Id.valueOf(String.valueOf(childIdVal));
                } catch (Exception e) {
                    // Non-ID value — skip stitching for this child record
                    continue;
                }

                List<Map<String, Object>> gcList = gcByParent.containsKey(childId)
                    ? gcByParent.get(childId)
                    : new List<Map<String, Object>>();

                childRec.put(grandchildSpec.relationshipName, new Map<String, Object>{
                    'totalSize' => gcList.size(),
                    'records' => gcList
                });

                // Recurse deeper if this grandchild has its own children
                if (!grandchildSpec.children.isEmpty()) {
                    for (Map<String, Object> gcRec : gcList) {
                        // Not yet implemented — would need another level of stitching
                    }
                }
            }
        }
    }

    /**
     * Validates a field name against the object's field map.
     * Returns the validated field name, or null if invalid.
     */
    private static String validateField(String fieldName, Map<String, SObjectField> fieldMap) {
        if (String.isBlank(fieldName)) { return null; }

        if (fieldMap.containsKey(fieldName)) { return fieldName; }

        // Try appending __c
        if (!fieldName.endsWithIgnoreCase('__c') && fieldMap.containsKey(fieldName + '__c')) {
            return fieldName + '__c';
        }

        // Relationship field: Account.Name, Owner.Email, etc.
        if (fieldName.contains('.')) {
            List<String> relParts = fieldName.split('\\.');
            if (relParts.size() >= 2) {
                String relName = relParts[0];
                for (Schema.SObjectField sof : fieldMap.values()) {
                    if (sof.getDescribe().getRelationshipName() == relName) {
                        return fieldName;
                    }
                }
            }
            return null;
        }

        return null;
    }

    /**
     * Recursively maps an SObject to a Map<String, Object>.
     * Child lists become { 'totalSize': N, 'records': [...] }.
     * Parent lookups become nested maps.
     */
    private static Map<String, Object> mapSObject(SObject record) {
        Map<String, Object> data = new Map<String, Object>();
        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

        for (String key : populatedFields.keySet()) {
            try {
                Object value = populatedFields.get(key);

                if (value instanceof List<SObject>) {
                    List<Map<String, Object>> childList = new List<Map<String, Object>>();
                    for (SObject child : (List<SObject>) value) {
                        childList.add(mapSObject(child));
                    }
                    data.put(key, new Map<String, Object>{ 'totalSize' => childList.size(), 'records' => childList });
                } else if (value instanceof SObject) {
                    Map<String, Object> parentMap = mapSObject((SObject) value);
                    if (!parentMap.containsKey('Id')) {
                        try {
                            parentMap.put('Id', ((SObject) value).Id);
                        } catch (Exception ignored) {
                            // Parent record may not have Id populated — safe to skip
                        }
                    }
                    data.put(key, parentMap);
                } else if (value instanceof Address) {
                    Address addr = (Address) value;
                    data.put(key, new Map<String, Object>{
                        'street' => addr.getStreet(), 'city' => addr.getCity(),
                        'state' => addr.getState(), 'postalCode' => addr.getPostalCode(),
                        'country' => addr.getCountry()
                    });
                } else if (value instanceof Location) {
                    Location loc = (Location) value;
                    data.put(key, new Map<String, Object>{
                        'latitude' => loc.getLatitude(), 'longitude' => loc.getLongitude()
                    });
                } else {
                    data.put(key, value);
                }
            } catch (Exception e) {
                String ignored = e.getMessage(); // Field mapping failed (e.g., blob field) — skip
            }
        }
        return data;
    }

    // ---------------------------------------------------------------------------
    // SOQL Clause Sanitization
    // ---------------------------------------------------------------------------

    /**
     * Validates a dynamic SOQL clause (WHERE, ORDER BY, or LIMIT fragment)
     * to prevent injection. Rejects clauses containing dangerous keywords.
     * Returns the clause if safe, throws DocGenException if not.
     */
    private static String sanitizeClause(String clause, String clauseType) {
        if (String.isBlank(clause)) { return clause; }
        // Reject statement terminators and comments
        if (clause.contains(';') || clause.contains('--') || clause.contains('/*')) {
            throw new DocGenException('Invalid ' + clauseType + ' clause in query config.');
        }
        // Normalize whitespace for keyword matching
        String normalized = clause.replaceAll('\\s+', ' ').toUpperCase().trim();
        // LIMIT should be numeric only
        if (clauseType == 'LIMIT') {
            if (!clause.trim().isNumeric()) {
                throw new DocGenException('LIMIT clause must be a number.');
            }
            return clause;
        }
        // Reject DML and structural SOQL keywords that don't belong in clauses
        List<String> disallowed = new List<String>{
            'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'UNDELETE ',
            'DROP ', 'ALTER ', 'CREATE ', 'GRANT ', 'REVOKE '
        };
        // WHERE clauses should not contain subqueries
        if (clauseType == 'WHERE') {
            disallowed.add('SELECT ');
        }
        for (String keyword : disallowed) {
            if (normalized.contains(keyword)) {
                throw new DocGenException('Invalid ' + clauseType + ' clause: disallowed keyword detected.');
            }
        }
        return clause;
    }

    /**
     * V4: Custom Apex Data Provider.
     * Config format: {"v":4,"provider":"MyClassName"}
     * Instantiates the named class (must implement DocGenDataProvider),
     * calls getData(recordId), and returns the result.
     */
    private static Map<String, Object> getRecordDataV4(Id recordId, Map<String, Object> config) {
        String providerClassName = (String) config.get('provider');
        if (String.isBlank(providerClassName)) {
            throw new DocGenException('V4 config requires a "provider" class name.');
        }

        // Resolve class — try plain name first, then with package namespace
        Type providerType = Type.forName(providerClassName);
        if (providerType == null) {
            providerType = Type.forName('portwoodglobal', providerClassName);
        }
        if (providerType == null) {
            throw new DocGenException('Apex class "' + providerClassName + '" not found. Ensure it exists and implements DocGenDataProvider.');
        }

        Object instance = providerType.newInstance();
        if (!(instance instanceof DocGenDataProvider)) {
            throw new DocGenException('Class "' + providerClassName + '" must implement the DocGenDataProvider interface.');
        }

        DocGenDataProvider provider = (DocGenDataProvider) instance;
        Map<String, Object> data = provider.getData(recordId);

        if (data == null) {
            throw new DocGenException('Data provider "' + providerClassName + '" returned null.');
        }

        return data;
    }
}
