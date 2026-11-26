import { useEffect, useState } from "react";
export function ClockNow() {
  const [t, setT] = useState(0);
  useEffect(() => { setT(Date.now()); }, []);
  return <p>{t}</p>;
}
