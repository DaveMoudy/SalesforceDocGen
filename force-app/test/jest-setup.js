// Polyfill TextEncoder, TextDecoder, and atob for Jest (Node.js) environment
const { TextEncoder, TextDecoder } = require("util");

if (typeof global.TextEncoder === "undefined") {
  global.TextEncoder = TextEncoder;
}
if (typeof global.TextDecoder === "undefined") {
  global.TextDecoder = TextDecoder;
}
if (typeof global.atob === "undefined") {
  global.atob = (b64) => Buffer.from(b64, "base64").toString("binary");
}
if (typeof global.btoa === "undefined") {
  global.btoa = (str) => Buffer.from(str, "binary").toString("base64");
}
