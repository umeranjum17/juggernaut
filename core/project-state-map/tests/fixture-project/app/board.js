export const visible = tickets => tickets.filter(t => t.stage === 'working' && !t.closed_at)
const stuck = t => t.stuck && t.stage !== 'done'
export function poll(load) { return setInterval(load, 30000) }
