// Fleet kill guard for OpenCode (installed by juggernaut-addons kill-guard/wiring.sh); throwing stops the bash call.
import { guard } from "__GUARD__";

export const FmKillGuard = async () => ({
  "tool.execute.before": async (input, output) => {
    if (input?.tool !== "bash") return;
    const reason = guard(output?.args?.command);
    if (reason !== null) throw new Error(reason);
  },
});
