// @ts-check
const eslint = require("@eslint/js");
const tseslint = require("typescript-eslint");

module.exports = tseslint.config(
  {
    ignores: ["dist/**", "node_modules/**", "*.vsix", "eslint.config.js", "esbuild.config.js"],
  },
  eslint.configs.recommended,
  tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        project: "./tsconfig.json",
        tsconfigRootDir: __dirname,
      },
    },
    rules: {
      // Matches tsconfig's own noUnusedLocals/noUnusedParameters — this
      // just gives faster in-editor feedback than waiting for tsc.
      "@typescript-eslint/no-unused-vars": "warn",
      // `void somePromise()` is this codebase's established idiom for
      // deliberately not awaiting a promise (see extension.ts) — don't
      // flag it as a mistake.
      "@typescript-eslint/no-floating-promises": [
        "error",
        { ignoreVoid: true },
      ],
    },
  },
);
