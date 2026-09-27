import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import vm from "vm";

const root = dirname(fileURLToPath(import.meta.url));
const code = readFileSync(join(root, "src/editor.js"), "utf8");
if (code.includes("require(") || code.includes("module.exports")) {
  throw new Error("bundle must not use Node require/module");
}
const window = {};
const sandbox = { window, globalThis: { window } };
vm.createContext(sandbox);
vm.runInContext(code, sandbox);
const api = sandbox.window.TokenLibraryEditor;
if (!api) throw new Error("TokenLibraryEditor missing");
const src = "# 三方\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n$n+1$\n\n$$a+b$$\n";
const back = api.roundTrip(src);
if (!back.includes("```mermaid") || !back.includes("$n+1$") || !back.includes("$$a+b$$")) {
  throw new Error("source not preserved: " + back);
}
const html = api.render(src);
if (!html.includes("mermaid-svg") || !html.includes("math-block")) {
  throw new Error("render missing mermaid/math: " + html);
}
const withImg = api.render("![x](data:image/png;base64,xx)");
if (!withImg.includes("<img")) throw new Error("image not rendered");
console.log("editor fixture ok");
