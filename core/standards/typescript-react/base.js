// core/standards/typescript-react/base.js: the reusable preset. No lab filename, no per-file exception except the
// api client folder of the bulletproof-react layout. Rules R1 and R3-R7; R2 (no useEffect) is an opt-in ban.
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";
import noEffect from "eslint-plugin-react-you-might-not-need-an-effect";
import importX from "eslint-plugin-import-x";
const RESOLVER = { "import-x/resolver": { node: { extensions: [".ts", ".tsx", ".js"] } } };
const FETCH = "Use the api client (src/shared/api), never raw fetch.";
export default [
  ...tseslint.configs.strictTypeChecked,
  ...tseslint.configs.stylisticTypeChecked,
  reactHooks.configs.flat["recommended-latest"] ?? reactHooks.configs["recommended-latest"],
  noEffect.configs.strict,
  { languageOptions: { parserOptions: { projectService: true, tsconfigRootDir: process.cwd() } } },
  { plugins: { "import-x": importX }, settings: RESOLVER,
    rules: {
      "no-restricted-globals": ["error", { name: "fetch", message: FETCH }],
      "no-restricted-properties": ["error", { object: "window", property: "fetch", message: FETCH }, { object: "globalThis", property: "fetch", message: FETCH }],
      "import-x/no-restricted-paths": ["error", { zones: [
        { target: "./src/features", from: "./src/app", message: "features never import app" },
        { target: "./src/shared", from: ["./src/features", "./src/app"], message: "shared imports nothing above it" } ] }]
  } },
  { files: ["src/shared/api/**"], rules: { "no-restricted-globals": "off", "no-restricted-properties": "off" } }
];
