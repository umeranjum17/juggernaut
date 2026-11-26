import { useEffect, useState } from "react";
export function Clock() {
  const [t, setT] = useState(0);
  useEffect(() => {
    const id = setInterval(() => { setT(Date.now()); }, 1000);
    return () => { clearInterval(id); };
  }, []);
  return <p>{t}</p>;
}
