export function Greeting({ first, last }: { first: string; last: string }) {
  const full = `${first} ${last}`;
  return <p>{full}</p>;
}
