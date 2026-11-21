import * as React from "react";
export function Tick(): null {
  React.useEffect(() => { document.title = "tick"; }, []);
  return null;
}
