import { createElement } from "@lwc/engine-dom";
import DocGenRunner from "c/docGenRunner";
import getTemplatesForObject from "@salesforce/apex/DocGenController.getTemplatesForObject";
import { registerApexTestWireAdapter } from "@salesforce/wire-service-jest-util";

// Mock Apex methods
jest.mock(
  "@salesforce/apex/DocGenController.getTemplatesForObject",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.generateDocumentDataForClient",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.processAndReturnDocument",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.generatePdfAsync",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.checkPdfResult",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DocGenController.saveGeneratedDocument",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

// Register the @wire adapter so we can emit data directly
const getTemplatesAdapter = registerApexTestWireAdapter(getTemplatesForObject);

const MOCK_TEMPLATES = [
  {
    Id: "001",
    Name: "Test Template",
    Type__c: "Word",
    Output_Format__c: "Document",
    Is_Default__c: true
  }
];

describe("c-doc-gen-runner", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  describe("client-side generation disabled (default)", () => {
    it("does not show client-side badge when enableClientSideGeneration is false", async () => {
      const el = createElement("c-doc-gen-runner", { is: DocGenRunner });
      el.objectApiName = "Account";
      el.recordId = "acc001";
      el.enableClientSideGeneration = false;
      document.body.appendChild(el);
      getTemplatesAdapter.emit(MOCK_TEMPLATES);
      await Promise.resolve();

      const badge = el.shadowRoot.querySelector(
        '[data-id="client-side-badge"]'
      );
      expect(badge).toBeNull();
    });
  });

  describe("client-side generation enabled", () => {
    it("shows client-side badge when enableClientSideGeneration is true", async () => {
      const el = createElement("c-doc-gen-runner", { is: DocGenRunner });
      el.objectApiName = "Account";
      el.recordId = "acc001";
      el.enableClientSideGeneration = true;
      document.body.appendChild(el);
      getTemplatesAdapter.emit(MOCK_TEMPLATES);
      await Promise.resolve();

      const badge = el.shadowRoot.querySelector(
        '[data-id="client-side-badge"]'
      );
      expect(badge).not.toBeNull();
    });

    it("shows PDF not supported message for PDF output in client-side mode", async () => {
      const pdfTemplates = [
        {
          Id: "002",
          Name: "PDF Template",
          Type__c: "Word",
          Output_Format__c: "PDF",
          Is_Default__c: true
        }
      ];
      const el = createElement("c-doc-gen-runner", { is: DocGenRunner });
      el.objectApiName = "Account";
      el.recordId = "acc001";
      el.enableClientSideGeneration = true;
      document.body.appendChild(el);
      getTemplatesAdapter.emit(pdfTemplates);
      await Promise.resolve();

      const warning = el.shadowRoot.querySelector(
        '[data-id="client-side-pdf-warning"]'
      );
      expect(warning).not.toBeNull();
    });

    it("shows PPTX not supported message for PowerPoint in client-side mode", async () => {
      const pptTemplates = [
        {
          Id: "003",
          Name: "PPT Template",
          Type__c: "PowerPoint",
          Output_Format__c: "Document",
          Is_Default__c: true
        }
      ];
      const el = createElement("c-doc-gen-runner", { is: DocGenRunner });
      el.objectApiName = "Account";
      el.recordId = "acc001";
      el.enableClientSideGeneration = true;
      document.body.appendChild(el);
      getTemplatesAdapter.emit(pptTemplates);
      await Promise.resolve();

      const warning = el.shadowRoot.querySelector(
        '[data-id="client-side-pptx-warning"]'
      );
      expect(warning).not.toBeNull();
    });
  });
});
