import { context } from "esbuild";
import { readFileSync } from "node:fs";

const production = process.argv.includes("--production");
const watch = process.argv.includes("--watch");

async function main() {
    const ctx = await context({
        entryPoints: ["internal/zig_analyzer_vscode/extension.ts"],
        bundle: true,
        format: "cjs",
        platform: "node",
        outfile: "dist/extension.js",
        external: ["vscode"],
        sourcemap: !production,
        minify: production,
    });

    if (watch) {
        await ctx.watch();
    } else {
        await ctx.rebuild();
        await ctx.dispose();
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
