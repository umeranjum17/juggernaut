// Fleet pipeline rule: literal-path recursive deletes (installed by juggernaut-addons pipeline-literal-delete/wiring.sh).
// Pipeline gate agents run pi with project context files disabled, but user-level extensions still load,
// so this reaches every pi session - review, test, document, lint steps - in every juggernaut home.
import { readFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const RULE = readFileSync("__RULE_PATH__", "utf8").trim();

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", async (event) => ({
		systemPrompt: `${event.systemPrompt}\n\n## Fleet delete rule\n\n${RULE}\n`,
	}));
}
