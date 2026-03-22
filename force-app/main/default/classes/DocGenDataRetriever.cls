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

    public static Map<String, Object> getRecordData(Id recordId, String baseObject, String fieldsConfig) {
        if (String.isBlank(baseObject) || String.isBlank(fieldsConfig) || recordId == null) {
            throw new AuraHandledException('Invalid parameters for data retrieval.');
        }

        // JSON v2 config: starts with '{', contains version field
        if (fieldsConfig.trim().startsWith('{')) {
            return getRecordDataV2(recordId, baseObject, fieldsConfig);
        }

        SObjectType objType = Schema.getGlobalDescribe().get(baseObject);
        if (objType == null) {
            throw new AuraHandledException('Invalid or inaccessible object.');
        }
        Map<String, SObjectField> fieldMap = objType.getDescribe().fields.getMap();

        // Parse the config into flat fields, direct subqueries, and nested subquery specs
        List<String> flatParts = new List<String>();
        List<SubquerySpec> deepSpecs = new List<SubquerySpec>();
        parseConfigParts(fieldsConfig, baseObject, fieldMap, flatParts, deepSpecs);

        // Build Level 0 query: flat fields + direct child subqueries (no nesting)
        String level0Select = buildLevel0Select(flatParts, deepSpecs);
        if (String.isBlank(level0Select)) level0Select = 'Id';

        String query = 'SELECT ' + level0Select + ' FROM ' + String.escapeSingleQuotes(baseObject) + ' WHERE Id = :recordId LIMIT 1';

        Map<String, Object> data;
        try {
            List<SObject> results = Database.query(query, AccessLevel.USER_MODE);
            if (results.isEmpty()) return null;
            data = mapSObject(results[0]);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Query execution error: ' + e.getMessage());
            throw new AuraHandledException('Error executing query. Please verify your template configuration.');
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
    private static void parseConfigParts(String fieldsConfig, String baseObject,
            Map<String, SObjectField> fieldMap, List<String> flatParts, List<SubquerySpec> deepSpecs) {

        // Split by comma at paren level 0
        List<String> rawParts = splitTopLevel(fieldsConfig);

        for (String part : rawParts) {
            String trimmed = part.trim();
            if (String.isBlank(trimmed)) continue;

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

            if (ch == '(') parenLevel++;
            if (ch == ')') parenLevel--;

            if (ch == ',' && parenLevel == 0) {
                parts.add(current.trim());
                current = '';
            } else {
                current += ch;
            }
        }
        if (String.isNotBlank(current.trim())) parts.add(current.trim());
        return parts;
    }

    /**
     * Parses a subquery string into a SubquerySpec, extracting any nested subqueries.
     * Input: (SELECT Name, Amount, (SELECT Quantity FROM OpportunityLineItems) FROM Opportunities WHERE ...)
     */
    private static SubquerySpec parseSubquerySpec(String subqueryStr, String parentObject) {
        // Strip outer parens
        String innerStr = subqueryStr.trim();
        if (innerStr.startsWith('(')) innerStr = innerStr.substring(1);
        if (innerStr.endsWith(')')) innerStr = innerStr.substring(0, innerStr.length() - 1);
        innerStr = innerStr.trim();

        // Extract: SELECT <fields> FROM <relationship> [WHERE ...] [ORDER BY ...] [LIMIT ...]
        String upperInner = innerStr.toUpperCase();
        Integer selectIdx = upperInner.indexOf('SELECT ');
        Integer fromIdx = findKeywordAtLevel0(innerStr, 'FROM');
        if (selectIdx == -1 || fromIdx == -1) return null;

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
        if (whereIdx != -1 && whereIdx < firstClauseIdx) firstClauseIdx = whereIdx;
        if (orderIdx != -1 && orderIdx < firstClauseIdx) firstClauseIdx = orderIdx;
        if (limitIdx != -1 && limitIdx < firstClauseIdx) firstClauseIdx = limitIdx;

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
        if (!hasId) plainFields.add(0, 'Id');

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
        if (upper.startsWith(keyword.toUpperCase() + ' ') && parenLvl == 0) return 0;

        for (Integer i = 0; i < input.length(); i++) {
            String ch = input.substring(i, i + 1);
            if (ch == '(') parenLvl++;
            if (ch == ')') parenLvl--;
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
        if (nextIdx1 != -1 && nextIdx1 < endIdx) endIdx = nextIdx1;
        if (nextIdx2 != -1 && nextIdx2 < endIdx) endIdx = nextIdx2;
        return source.substring(startIdx, endIdx).trim();
    }

    /**
     * Resolves the child object API name and parent lookup field from Schema.
     */
    private static void resolveChildSchema(SubquerySpec spec, String parentObjectName) {
        SObjectType parentType = Schema.getGlobalDescribe().get(parentObjectName);
        if (parentType == null) return;

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
        if (String.isNotBlank(spec.whereClause)) sq += ' WHERE ' + spec.whereClause;
        if (String.isNotBlank(spec.orderByClause)) sq += ' ORDER BY ' + spec.orderByClause;
        if (String.isNotBlank(spec.limitClause)) sq += ' LIMIT ' + spec.limitClause;
        sq += ')';
        return sq;
    }

    /**
     * Builds the Level 0 SELECT clause from validated flat parts.
     */
    private static String buildLevel0Select(List<String> parts, List<SubquerySpec> specs) {
        String result = '';
        for (String part : parts) {
            if (String.isNotBlank(result)) result += ', ';
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
        if (childData == null || !(childData instanceof Map<String, Object>)) return;

        Map<String, Object> childMap = (Map<String, Object>) childData;
        Object recordsObj = childMap.get('records');
        if (recordsObj == null || !(recordsObj instanceof List<Object>)) return;

        List<Object> childRecords = (List<Object>) recordsObj;
        if (childRecords.isEmpty()) return;

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
                        try { parentIds.add(Id.valueOf(String.valueOf(idVal))); } catch (Exception e) { /* skip */ }
                    }
                }
            }
            if (parentIds.isEmpty()) continue;

            // Query grandchildren
            String gcQuery = 'SELECT ' + grandchildSpec.fieldsOnly +
                ', ' + grandchildSpec.parentIdField +
                ' FROM ' + String.escapeSingleQuotes(grandchildSpec.childObjectApiName) +
                ' WHERE ' + String.escapeSingleQuotes(grandchildSpec.parentIdField) + ' IN :parentIds';
            if (String.isNotBlank(grandchildSpec.whereClause)) gcQuery += ' AND ' + grandchildSpec.whereClause;
            if (String.isNotBlank(grandchildSpec.orderByClause)) gcQuery += ' ORDER BY ' + grandchildSpec.orderByClause;
            if (String.isNotBlank(grandchildSpec.limitClause)) gcQuery += ' LIMIT ' + grandchildSpec.limitClause;

            List<SObject> gcResults;
            try {
                gcResults = Database.query(gcQuery, AccessLevel.USER_MODE);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'DocGen: Grandchild query failed: ' + e.getMessage());
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
                if (!(rec instanceof Map<String, Object>)) continue;
                Map<String, Object> childRec = (Map<String, Object>) rec;
                Object childIdVal = childRec.get('Id');
                if (childIdVal == null) continue;

                Id childId;
                try { childId = Id.valueOf(String.valueOf(childIdVal)); } catch (Exception e) { continue; }

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
        if (String.isBlank(fieldName)) return null;

        if (fieldMap.containsKey(fieldName)) return fieldName;

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
            System.debug(LoggingLevel.WARN, 'DocGen: Relationship not found, skipping: ' + fieldName);
            return null;
        }

        System.debug(LoggingLevel.WARN, 'DocGen: Field not found, skipping: ' + fieldName);
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
                        } catch (Exception ignored) { }
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
                System.debug(LoggingLevel.FINE, 'DocGen: Error mapping field: ' + e.getMessage());
            }
        }
        return data;
    }
}
