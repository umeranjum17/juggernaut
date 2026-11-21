// The inert-rule control, lab only: the shipped preset with its resolver setting stripped in memory.
import base from "../../base.js";
export default base.map((c) => (c.settings && "import-x/resolver" in c.settings
  ? { ...c, settings: Object.fromEntries(Object.entries(c.settings).filter(([k]) => k !== "import-x/resolver")) } : c));
