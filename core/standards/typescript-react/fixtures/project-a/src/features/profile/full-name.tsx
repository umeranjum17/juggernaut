import { useEffect, useState } from "react";
export function FullName({ first, last }: { first: string; last: string }) {
  const [full, setFull] = useState("");
  useEffect(() => { setFull(`${first} ${last}`); }, [first, last]);
  return <p>{full}</p>;
}
