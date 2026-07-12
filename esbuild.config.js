// Bundles the extension to a single CommonJS file so `vsce package --no-dependencies` doesn't need to understand pnpm's node_modules layout — see project plan §5.

const esbuild = require("esbuild");

const production = process.argv.includes("--production");
const watch = process.argv.includes("--watch");

async function main() {
  const ctx = await esbuild.context({
    entryPoints: ["src/vscode/extension.ts"],
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
