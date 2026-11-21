import { useState } from "react";
export function Count() {
  const [n, setN] = useState(0);
  return <button type="button" onClick={() => { setN(n + 1); }}>{n}</button>;
}
