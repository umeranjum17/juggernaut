// core/standards/typescript-react/bans/no-use-effect.js: added by a project whose owner banned useEffect.
const MSG = "No useEffect: derive during render or use the data layer.";
export default { rules: { "no-restricted-imports": ["error", { paths: [{ name: "react", importNames: ["useEffect"], message: MSG }] }],
  "no-restricted-syntax": ["error", { selector: "MemberExpression[object.name='React'][property.name='useEffect']", message: MSG }] } };
