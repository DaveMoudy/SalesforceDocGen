const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  ...jestConfig,
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"],
  setupFiles: ["<rootDir>/force-app/test/jest-setup.js"],
  moduleNameMapper: {
    ...jestConfig.moduleNameMapper,
    "^lightning/flowSupport$":
      "<rootDir>/force-app/test/jest-mocks/lightning/flowSupport.js"
  }
};
