# Salesforce Document Generation Platform (Open Source)

Welcome to the **Salesforce Document Generation Platform**, a powerful, native, and completely free solution for generating documents directly within your Salesforce org. 

> [!IMPORTANT]
> This is the **first iteration (v0.1.0)** of the platform. It is fully open-source and ready for production use, but we welcome contributions and feedback to make it even better.

## Why this exists?
Normally, document generation in Salesforce is expensive. We believe that basic document needs should be accessible to everyone. This project gives you a professional-grade document engine—which others charge heavily for—entirely for free.

---

## 🚀 Quick Install (2GP Unlocked Package)

You can install the latest stable version of the platform using the following command:

```bash
sf package install --package 04tdL000000Ny3VQAS --wait 10 --installation-key-bypass
```

**Subscriber Package Version ID**: `04tdL000000Ny3VQAS`  
**Installation Links**:
- [Install in Production/Developer Org](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000Ny3VQAS)
- [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tdL000000Ny3VQAS)

---

What does this stuff do? Quick Overview Youtube: https://www.youtube.com/watch?v=TAdNItmu2jw

## 🧩 Core Components

### 1. Template Manager
The **Template Manager** is your central hub for creating and managing document templates. 
- **Access**: Navigate to the **DocGen Template Manager** tab.
- **Features**: 
    - Upload `.docx` or `.pptx` files.
    - Build SOQL queries using the built-in Query Builder.
    - Manage template versions and metadata.
    - Test generation with a sample record directly from the manager.

### 2. Record Page Generator (LWC)
Add the document generation capability to any standard or custom object record page.
- **Access**: Edit any Lightning Record Page and add the **docGenRunner** component.
- **Functionality**: Users can select a template available for that specific object and generate a PDF or PowerPoint document in one click.

### 3. Bulk Document Generation
Need to generate documents for hundreds of records at once?
- **Access**: Navigate to the **DocGen Bulk Gen** tab.
- **Features**: 
    - Filter records using an intuitive UI.
    - Track progress in real-time with a dynamic progress bar.
    - Documents are processed in the background and attached to the records automatically.

### 4. Invocable Flow Action (Single Record)
- **Developer Name**: `Generate Document (Native)`
- **Class**: `DocGenFlowAction`
- **Usage**: Use this in any Salesforce Flow (Screen or Autolaunched) to generate a document when a specific event occurs (e.g., when an Opportunity is Closed Won).

### 5. Invocable Flow Action (Bulk/Batch)
- **Developer Name**: `Generate Bulk Documents`
- **Class**: `DocGenBulkFlowAction`
- **Usage**: Ideal for **Scheduled Flows**. Pass a Template ID and an optional SOQL condition to trigger a batch job that generates documents for all matching records in the background.

### 6. Secure Background PDF Engine
- **Architecture**: The package features a self-contained, async PDF rendering engine.
- **Secure Loopback**: Uses native Salesforce Connect APIs via an automated **Named Credential** setup. No external services or third-party APIs required!
- **Wizard Driven**: The **DocGen Setup** wizard automatically generates the necessary Connected App, Auth Provider, and Named Credentials for you.
- **Resilience**: Built-in 3x retry mechanism gracefully handles `202 Accepted` latency from Salesforce servers.

### 7. Native Electronic Signatures (Experience Cloud)
- **Architecture**: A zero-cost, 100% native electronic signature engine.
- **Experience Cloud Integration**: Leverages Screen Flows running in **System Context** to ensure guest users can sign and process documents without permission blocks.
- **OpenXML Stamping**: Signatures are injected directly into the DOCX source file before being flattened to PDF.
- **Tamper Evidence**: Every signed document is mathematically hashed (SHA-256), creating an immutable audit trail for non-repudiation.

---

## 🛠 Prerequisites & Setup

### 1. Basic Setup
1. **Assign Permissions**: Assign the `DocGen Admin` or `DocGen User` permission set to yourself and your users.
2. **Assign the App**: Ensure users have access to the **DocGen** Lightning App.
3. **Files Access**: The platform uses standard Salesforce Files. Ensure users have the proper permissions to create ContentDocuments.

### 2. E-Signature Setup (Required for Public Signing)
1. **Enable Digital Experiences**: Go to **Setup > Digital Experiences** and enable the feature if not already done.
2. **Create a Site**: Create a new Experience Cloud site (Help Center or Build Your Own is recommended).
3. **Configure Settings**: Navigate to the **DocGen Setup** tab in the DocGen app and complete the 4-step wizard. This configures the secure loopback and saves your Site URL.
4. **Embed Flow**: In **Experience Builder**, create a new public page and drag the **Flow** component onto it. Select the **DocGen Signature Submission** flow.
5. **Pass Parameters**: In the Flow component properties, look for the **secureToken** input variable. Enter `{!token}` into the value field to pull the token from the URL. Ensure the "Pass URL parameter values into flow variables" checkbox is checked.
6. **Guest Permissions**: Go to **Site Settings > Guest User Profile**. Under **Enabled Flow Access**, add the **DocGen Signature Submission** flow.
7. **Guest Access**: Ensure the site has "Public can access the site" enabled in the General settings of the Experience Builder.
8. **Publish**: Publish your site. Signature links generated from record pages will now point to this secure portal.

---

## 🤝 Contributing
This is an open-source project. We encourage you to fork this repository, submit pull requests, and report issues. Let's build the best free document engine for Salesforce together!

---

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
