#!/usr/bin/env node
/**
 * Merges schemas/vscode-configuration.json into package.json
 * contributes.configuration.properties. Keys under zigAnalyzer.* are replaced
 * wholesale from the generated file; other package.json fields are preserved.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const packagePath = join(root, "package.json");
const vscodeConfigPath = join(root, "schemas/vscode-configuration.json");

const pkg = JSON.parse(readFileSync(packagePath, "utf8"));
const generated = JSON.parse(readFileSync(vscodeConfigPath, "utf8"));

const props = pkg.contributes?.configuration?.properties;
if (!props || typeof props !== "object") {
  console.error("package.json missing contributes.configuration.properties");
  process.exit(1);
}

for (const key of Object.keys(props)) {
  if (key.startsWith("zigAnalyzer.")) {
    delete props[key];
  }
}

Object.assign(props, generated);

const restricted = [
  "zigAnalyzer.serverPath",
  "zigAnalyzer.zigPath",
  "zigAnalyzer.formatter.command",
];
if (pkg.capabilities?.untrustedWorkspaces) {
  pkg.capabilities.untrustedWorkspaces.restrictedConfigurations = restricted;
  pkg.capabilities.untrustedWorkspaces.description =
    "Executable paths (zigAnalyzer.serverPath, zigAnalyzer.zigPath, zigAnalyzer.formatter.command) are ignored in untrusted workspaces to prevent a workspace from silently configuring code execution.";
}

writeFileSync(packagePath, `${JSON.stringify(pkg, null, 2)}\n`);
console.error("Updated package.json contributes.configuration.properties from schemas/vscode-configuration.json");
