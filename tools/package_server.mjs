import { chmodSync, copyFileSync, existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const executable = process.platform === "win32" ? "zig-analyzer.exe" : "zig-analyzer";
const source = join(root, "zig-out", "bin", executable);
const destination = join(root, "server", executable);

if (!existsSync(source)) {
  throw new Error(`Expected a built language server at ${source}. Run \"zig build\" first.`);
}

mkdirSync(dirname(destination), { recursive: true });
copyFileSync(source, destination);
chmodSync(destination, statSync(source).mode);
