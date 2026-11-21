import { useEffect } from "react";
export function Ping(): null {
  useEffect(() => { document.title = "demo"; }, []);
  return null;
}
